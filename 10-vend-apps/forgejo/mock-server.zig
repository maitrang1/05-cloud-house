// =====================================================================
// Des: A pretend Forgejo release server + Forgejo API for tests. Runs on this machine on a spare port, checks requests strictly like the real service, and never touches a live account. Its "binary" is a small shell script that fakes the forgejo admin CLI.
// Flo: listen on a free port > accept one request > check auth and fields > change in-memory state > answer > count the call
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests on 127.0.0.1:<port>; knobs set by the test
// Out: binary + checksum, JSON answers; state the test can read back
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");

const Sha = std.crypto.hash.sha2.Sha256;

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .tokePref = "mocktoken-", .repoIden = 77, .userIden = 1, .vers = "15.0.5", .arch = "linux-amd64", .bearPref = "Bearer ", .basiPref = "Basic " };

// the fake forgejo binary: just enough of the admin CLI, state kept next to the script
pub const fakeBina =
    \\#!/bin/sh
    \\D=$(dirname "$0")
    \\C="$1 $2 $3"
    \\U=; E=; N=; P=
    \\while [ $# -gt 0 ]; do
    \\  case "$1" in
    \\    --username) U=$2;;
    \\    --email) E=$2;;
    \\    --token-name) N=$2;;
    \\    --password) P=$2;;
    \\  esac
    \\  shift
    \\done
    \\case "$C" in
    \\  "admin user list") [ -f "$D/users.txt" ] && cat "$D/users.txt"; exit 0;;
    \\  "admin user create") echo "1 $U $E true true" >> "$D/users.txt"; echo "New user '$U' has been successfully created!"; exit 0;;
    \\  "admin user generate-access-token")
    \\    if [ -f "$D/tok-$N" ]; then echo "access token name has been used already" >&2; exit 1; fi
    \\    touch "$D/tok-$N"; echo "mocktoken-$N"; exit 0;;
    \\  "admin user change-password") echo "$P" > "$D/pass"; exit 0;;
    \\esac
    \\exit 1
    \\
;

const Keyz = struct { iden: u64, titl: []const u8, keyz: []const u8 };
const Answ = struct { code: u16 = 200, body: []const u8 = "{}", retr: bool = false, ctyp: []const u8 = "application/json" };

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,

    // state
    admin: []const u8 = "ann",
    keys: std.ArrayList(Keyz) = .empty,
    nextIden: u64 = 100,
    repoHave: bool = false,
    repoName: []const u8 = "",
    repoPriv: bool = false,
    repoBran: []const u8 = "",
    hasWiki: bool = true,
    hasIssues: bool = true,
    hasPrs: bool = true,
    hasProjects: bool = true,
    hasActions: bool = true,
    protHave: bool = false,
    protPush: bool = false,
    protForc: bool = true,
    headId: []const u8 = "",
    tokeGone: bool = false,
    basiPass: []const u8 = "",

    // knobs
    downN: u32 = 0,
    rateLimi: u32 = 0,
    badSum: bool = false,

    // counters
    seen: u32 = 0,
    bads: u32 = 0,
    logz: std.ArrayList([]const u8) = .empty,

    // listen on a system-chosen port and serve from a thread
    pub fn star(io: std.Io) !*Mock {
        const self = try std.heap.smp_allocator.create(Mock);
        errdefer std.heap.smp_allocator.destroy(self);
        var addr = try std.Io.net.IpAddress.parse(CF.host, 0);
        var serv = try addr.listen(io, .{ .reuse_address = true });
        errdefer serv.deinit(io);
        self.* = .{ .io = io, .aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator), .serv = serv, .port = serv.socket.address.getPort() };
        self.thre = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    // stop the thread, free everything
    pub fn halt(self: *Mock) void {
        self.stop.store(true, .release);
        var addr = std.Io.net.IpAddress.parse(CF.host, self.port) catch unreachable; // literal ip always parses
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| conn.close(self.io) else |_| {}
        if (self.thre) |thre| thre.join();
        self.serv.deinit(self.io);
        self.aren.deinit();
        std.heap.smp_allocator.destroy(self);
    }

    // base url of the mock, caller frees
    pub fn base(self: *Mock, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://{s}:{d}{s}", .{ CF.host, self.port, path });
    }

    pub fn lock(self: *Mock) void {
        self.mute.lockUncancelable(self.io);
    }

    pub fn unlo(self: *Mock) void {
        self.mute.unlock(self.io);
    }

    // how many requests matched "METHOD path-prefix"
    pub fn seenCoun(self: *Mock, need: []const u8) u32 {
        var coun: u32 = 0;
        for (self.logz.items) |item| if (std.mem.startsWith(u8, item, need)) {
            coun += 1;
        };
        return coun;
    }

    // sha256 of the fake binary, hex
    pub fn binaSha(buff: *[Sha.digest_length * 2]u8) []const u8 {
        var dige: [Sha.digest_length]u8 = undefined;
        Sha.hash(fakeBina, &dige, .{});
        return std.fmt.bufPrint(buff, "{x}", .{dige[0..]}) catch unreachable; // buffer is sized for the hex digest
    }

    // accept loop: one request per connection
    fn loop(self: *Mock) void {
        while (true) {
            const conn = self.serv.accept(self.io) catch break;
            if (self.stop.load(.acquire)) {
                conn.close(self.io);
                break;
            }
            self.serv1(conn) catch {};
            conn.close(self.io);
        }
    }

    // read one request, route it, answer
    fn serv1(self: *Mock, conn: std.Io.net.Stream) !void {
        var rbuf: [16384]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var read = conn.reader(self.io, &rbuf);
        var writ = conn.writer(self.io, &wbuf);
        var http = std.http.Server.init(&read.interface, &writ.interface);
        var requ = try http.receiveHead();
        self.lock();
        defer self.unlo();
        const gpa = self.aren.allocator();

        // copy what we need before the body read invalidates the head
        const meth = requ.head.method;
        const targ = try gpa.dupe(u8, requ.head.target);
        var auth: []const u8 = "";
        var ctyp: []const u8 = "";
        var iter = requ.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, "authorization")) auth = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "content-type")) ctyp = try gpa.dupe(u8, head.value);
        }
        var bbuf: [4096]u8 = undefined;
        const body = if (meth.requestHasBody()) try (try requ.readerExpectContinue(&bbuf)).allocRemaining(gpa, .limited(CF.bodyMaxz)) else "";

        self.seen += 1;
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse targ.len;
        try self.logz.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ @tagName(meth), targ[0..ques] }));
        const answ = self.rout(gpa, meth, targ[0..ques], auth, ctyp, body) catch Answ{ .code = 500, .body = "{\"message\":\"mock crashed\"}" };
        if (answ.code >= 400 and answ.code != 404 and answ.code != 429 and answ.code != 503) self.bads += 1;
        const retr = [_]std.http.Header{ .{ .name = "Retry-After", .value = "1" }, .{ .name = "Content-Type", .value = answ.ctyp } };
        const norm = [_]std.http.Header{ .{ .name = "Content-Type", .value = answ.ctyp } };
        try requ.respond(if (answ.code == 204) "" else answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &retr else &norm });
    }

    // pick the handler by path prefix
    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, auth: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        if (self.rateLimi > 0) {
            self.rateLimi -= 1;
            return .{ .code = 429, .body = "{\"message\":\"too many requests\"}", .retr = true };
        }
        if (std.mem.startsWith(u8, path, "/rel/")) return self.routRele(gpa, path);
        if (std.mem.startsWith(u8, path, "/api/v1/")) return self.routApiz(gpa, meth, path["/api/v1".len..], auth, ctyp, body);
        return .{ .code = 404, .body = "{\"message\":\"not found\"}" };
    }

    // release downloads: /rel/v<vers>/forgejo-<vers>-<arch>[.sha256]
    fn routRele(self: *Mock, gpa: std.mem.Allocator, path: []const u8) !Answ {
        const file = try std.fmt.allocPrint(gpa, "forgejo-{s}-{s}", .{ CF.vers, CF.arch });
        const bina = try std.fmt.allocPrint(gpa, "/rel/v{s}/{s}", .{ CF.vers, file });
        if (std.mem.eql(u8, path, bina)) return .{ .body = fakeBina, .ctyp = "application/octet-stream" };
        if (std.mem.eql(u8, path, try std.mem.concat(gpa, u8, &.{ bina, ".sha256" }))) {
            var buff: [Sha.digest_length * 2]u8 = undefined;
            var hexz = try gpa.dupe(u8, binaSha(&buff));
            if (self.badSum) hexz[0] = if (hexz[0] == '0') '1' else '0';
            return .{ .body = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ hexz, file }), .ctyp = "text/plain" };
        }
        return .{ .code = 404, .body = "not found", .ctyp = "text/plain" };
    }

    // repo JSON as Forgejo returns it
    fn repoJson(self: *Mock, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{{\"id\":{d},\"name\":\"{s}\",\"full_name\":\"{s}/{s}\",\"private\":{},\"default_branch\":\"{s}\",\"has_wiki\":{},\"has_issues\":{},\"has_pull_requests\":{},\"has_projects\":{},\"has_actions\":{}}}", .{ CF.repoIden, self.repoName, self.admin, self.repoName, self.repoPriv, self.repoBran, self.hasWiki, self.hasIssues, self.hasPrs, self.hasProjects, self.hasActions });
    }

    // true when "owner/name" is the one repo this mock holds
    fn repoIs(self: *Mock, owne: []const u8, name: []const u8) bool {
        return self.repoHave and std.mem.eql(u8, owne, self.admin) and std.mem.eql(u8, name, self.repoName);
    }

    // Forgejo REST v1
    fn routApiz(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, auth: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        const miss = Answ{ .code = 404, .body = "{\"message\":\"not found\"}" };
        const badr = Answ{ .code = 400, .body = "{\"message\":\"bad request\"}" };
        const unau = Answ{ .code = 401, .body = "{\"message\":\"token is required\"}" };

        // the up probe: no token
        if (std.mem.eql(u8, path, "/version") and meth == .GET) {
            if (self.downN > 0) {
                self.downN -= 1;
                return .{ .code = 503, .body = "{\"message\":\"starting\"}" };
            }
            return .{ .body = "{\"version\":\"15.0.5+gitea-1.22.0\"}" };
        }

        // the token endpoint takes basic auth only
        const tokp = try std.fmt.allocPrint(gpa, "/users/{s}/tokens/", .{self.admin});
        if (std.mem.startsWith(u8, path, tokp) and meth == .DELETE) {
            if (!std.mem.startsWith(u8, auth, CF.basiPref)) return unau;
            const dec = std.base64.standard.Decoder;
            const rawz = auth[CF.basiPref.len..];
            const size = dec.calcSizeForSlice(rawz) catch return unau;
            const pair = try gpa.alloc(u8, size);
            dec.decode(pair, rawz) catch return unau;
            const colo = std.mem.indexOfScalar(u8, pair, ':') orelse return unau;
            if (!std.mem.eql(u8, pair[0..colo], self.admin) or pair.len == colo + 1) return unau;
            self.basiPass = pair[colo + 1 ..];
            if (self.tokeGone) return miss;
            self.tokeGone = true;
            return .{ .code = 204 };
        }

        // everything else needs the token the CLI minted
        if (!std.mem.startsWith(u8, auth, CF.bearPref) or !std.mem.startsWith(u8, auth[CF.bearPref.len..], CF.tokePref) or self.tokeGone) return unau;
        if (meth.requestHasBody() and !std.mem.startsWith(u8, ctyp, "application/json")) return .{ .code = 415, .body = "{\"message\":\"unsupported media type\"}" };
        const json: std.json.Value = if (body.len > 0) std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr else .null;

        if (std.mem.eql(u8, path, "/user") and meth == .GET) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"login\":\"{s}\",\"email\":\"{s}@example.com\"}}", .{ CF.userIden, self.admin, self.admin }) };

        // ssh keys
        if (std.mem.eql(u8, path, "/user/keys")) {
            if (meth == .GET) {
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.keys.items) |item| {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":{d},\"title\":\"{s}\",\"key\":\"{s}\"}}", .{ item.iden, item.titl, item.keyz });
                }
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                if (json != .object) return badr;
                const titl = json.object.get("title") orelse return badr;
                const keyz = json.object.get("key") orelse return badr;
                if (titl != .string or keyz != .string or !std.mem.startsWith(u8, keyz.string, "ssh-ed25519 ")) return .{ .code = 422, .body = "{\"message\":\"invalid key\"}" };
                for (self.keys.items) |item| if (std.mem.eql(u8, item.keyz, keyz.string)) return .{ .code = 422, .body = "{\"message\":\"key already exists\"}" };
                self.nextIden += 1;
                try self.keys.append(gpa, .{ .iden = self.nextIden, .titl = titl.string, .keyz = keyz.string });
                return .{ .code = 201, .body = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"title\":\"{s}\",\"key\":\"{s}\"}}", .{ self.nextIden, titl.string, keyz.string }) };
            }
        }

        // create repo
        if (std.mem.eql(u8, path, "/user/repos") and meth == .POST) {
            if (json != .object) return badr;
            const name = json.object.get("name") orelse return badr;
            const priv = json.object.get("private") orelse return badr;
            const bran = json.object.get("default_branch") orelse return badr;
            if (name != .string or priv != .bool or bran != .string) return badr;
            if (self.repoHave) return .{ .code = 409, .body = "{\"message\":\"repo already exists\"}" };
            self.repoHave = true;
            self.repoName = name.string;
            self.repoPriv = priv.bool;
            self.repoBran = bran.string;
            return .{ .code = 201, .body = try self.repoJson(gpa) };
        }

        // /repos/{owner}/{name}[/...]
        if (std.mem.startsWith(u8, path, "/repos/")) {
            var part = std.mem.splitScalar(u8, path["/repos/".len..], '/');
            const owne = part.next() orelse return miss;
            const name = part.next() orelse return miss;
            const rest = part.rest();
            if (!self.repoIs(owne, name)) return miss;
            if (rest.len == 0 and meth == .GET) return .{ .body = try self.repoJson(gpa) };
            if (rest.len == 0 and meth == .PATCH) {
                if (json != .object) return badr;
                if (json.object.get("has_wiki")) |v| if (v == .bool) {
                    self.hasWiki = v.bool;
                };
                if (json.object.get("has_issues")) |v| if (v == .bool) {
                    self.hasIssues = v.bool;
                };
                if (json.object.get("has_pull_requests")) |v| if (v == .bool) {
                    self.hasPrs = v.bool;
                };
                if (json.object.get("has_projects")) |v| if (v == .bool) {
                    self.hasProjects = v.bool;
                };
                if (json.object.get("has_actions")) |v| if (v == .bool) {
                    self.hasActions = v.bool;
                };
                if (json.object.get("private")) |v| if (v == .bool and !v.bool) return .{ .code = 422, .body = "{\"message\":\"never public\"}" };
                return .{ .body = try self.repoJson(gpa) };
            }
            if (std.mem.eql(u8, rest, "branch_protections") and meth == .POST) {
                if (json != .object) return badr;
                const bran = json.object.get("branch_name") orelse return badr;
                if (bran != .string) return badr;
                if (self.protHave) return .{ .code = 403, .body = "{\"message\":\"rule exists\"}" };
                self.protHave = true;
                self.protPush = if (json.object.get("enable_push")) |v| v == .bool and v.bool else false;
                self.protForc = if (json.object.get("enable_force_push")) |v| v == .bool and v.bool else false;
                return .{ .code = 201, .body = try std.fmt.allocPrint(gpa, "{{\"branch_name\":\"{s}\",\"enable_push\":{},\"enable_force_push\":{}}}", .{ bran.string, self.protPush, self.protForc }) };
            }
            if (std.mem.startsWith(u8, rest, "branch_protections/") and meth == .GET) {
                if (!self.protHave) return miss;
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"branch_name\":\"{s}\",\"enable_push\":{},\"enable_force_push\":{}}}", .{ rest["branch_protections/".len..], self.protPush, self.protForc }) };
            }
            if (std.mem.startsWith(u8, rest, "branches/") and meth == .GET) {
                if (self.headId.len == 0) return miss;
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"commit\":{{\"id\":\"{s}\"}}}}", .{ rest["branches/".len..], self.headId }) };
            }
        }
        return miss;
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
