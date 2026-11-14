// =====================================================================
// Des: A pretend GitLab and GitHub for tests. Runs on this machine on a spare port, checks requests strictly like the real services, and never touches a live account.
// Flo: listen on a free port > accept one request > check auth and fields > change in-memory state > answer JSON > count the call
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests on 127.0.0.1:<port>; knobs set by the test
// Out: JSON answers; state the test can read back
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");

const Seal = std.crypto.nacl.SealedBox;
const b64s = std.base64.standard;

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .usid = 4242, .prid = 77, .deviCode = "mock-device-code", .userCode = "ABCD-1234", .clid = "mock-client", .ghToke = "gho_mockgithubtoken", .keyzIden = "mock-key-1", .ghVers = "2022-11-28", .shaz = "0123456789abcdef0123456789abcdef01234567" };

pub const clid = CF.clid;
pub const ghToke = CF.ghToke;
pub const prid: u64 = CF.prid;

const Keyz = struct { iden: u64, titl: []const u8, keyz: []const u8, gone: bool = false };
const Atok = struct { iden: u64, name: []const u8, toke: []const u8, expi: []const u8, role: u64, scop: []const u8, gone: bool = false };
const Pair = struct { keyz: []const u8, valu: []const u8 };
const Answ = struct { code: u16 = 200, body: []const u8 = "{}", retr: bool = false };

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,
    kpai: Seal.KeyPair,
    root: []const u8 = "",
    gitz: []const u8 = "git",

    // state
    user: ?[]const u8 = null,
    conf: bool = true,
    poll: u32 = 0,
    toke: ?[]const u8 = null,
    refr: ?[]const u8 = null,
    tokeNumb: u32 = 0,
    keys: std.ArrayList(Keyz) = .empty,
    projPath: ?[]const u8 = null,
    projName: []const u8 = "",
    projVisi: []const u8 = "",
    projSett: std.ArrayList(Pair) = .empty,
    protHave: bool = false,
    protPush: u64 = 0,
    protMerg: u64 = 0,
    protForc: bool = false,
    atok: std.ArrayList(Atok) = .empty,
    secr: std.ArrayList(Pair) = .empty,
    varz: std.ArrayList(Pair) = .empty,
    ghOwne: []const u8 = "ghowner",
    ghRepo: []const u8 = "cloud-house",
    nextIden: u64 = 100,
    revoOaut: u32 = 0,

    // knobs
    pollNeed: u32 = 2,
    slowOnce: bool = false,
    denyAtok: bool = false,
    rateLimi: u32 = 0,
    runzDone: bool = true,
    storSize: u64 = 1024,

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
        self.* = .{ .io = io, .aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator), .serv = serv, .port = serv.socket.address.getPort(), .kpai = Seal.KeyPair.generate(io) };
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

    // the human signs up (test plays the human)
    pub fn sign(self: *Mock, name: []const u8) void {
        self.lock();
        defer self.unlo();
        self.user = self.aren.allocator().dupe(u8, name) catch null;
    }

    // plain value of a GitHub secret the app uploaded (decrypted by the mock)
    pub fn secrGetz(self: *Mock, name: []const u8) ?[]const u8 {
        for (self.secr.items) |item| if (std.mem.eql(u8, item.keyz, name)) return item.valu;
        return null;
    }

    // how many requests matched "METHOD path-prefix"
    pub fn seenCoun(self: *Mock, need: []const u8) u32 {
        var coun: u32 = 0;
        for (self.logz.items) |item| if (std.mem.startsWith(u8, item, need)) {
            coun += 1;
        };
        return coun;
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
        var ghve: []const u8 = "";
        var iter = requ.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, "authorization")) auth = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "content-type")) ctyp = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "x-github-api-version")) ghve = try gpa.dupe(u8, head.value);
        }
        var bbuf: [4096]u8 = undefined;
        const body = if (meth.requestHasBody()) try (try requ.readerExpectContinue(&bbuf)).allocRemaining(gpa, .limited(CF.bodyMaxz)) else "";

        self.seen += 1;
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse targ.len;
        try self.logz.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ @tagName(meth), targ[0..ques] }));
        const answ = self.rout(gpa, meth, targ[0..ques], if (ques < targ.len) targ[ques + 1 ..] else "", auth, ctyp, ghve, body) catch Answ{ .code = 500, .body = "{\"message\":\"mock crashed\"}" };
        if (answ.code >= 400 and answ.code != 404 and answ.code != 429) self.bads += 1;
        const retr = [_]std.http.Header{ .{ .name = "Retry-After", .value = "1" }, .{ .name = "Content-Type", .value = "application/json" } };
        const norm = [_]std.http.Header{ .{ .name = "RateLimit-Remaining", .value = "4321" }, .{ .name = "Content-Type", .value = "application/json" } };
        try requ.respond(if (answ.code == 204) "" else answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &retr else &norm });
    }

    // pick the handler by path prefix
    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, auth: []const u8, ctyp: []const u8, ghve: []const u8, body: []const u8) !Answ {
        if (self.rateLimi > 0) {
            self.rateLimi -= 1;
            return .{ .code = 429, .body = "{\"message\":\"429 Too Many Requests\"}", .retr = true };
        }
        if (std.mem.startsWith(u8, path, "/oauth/")) return self.routOaut(gpa, meth, path, ctyp, body);
        if (std.mem.startsWith(u8, path, "/api/v4/")) return self.routGitl(gpa, meth, path["/api/v4".len..], quer, auth, ctyp, body);
        if (std.mem.startsWith(u8, path, "/gh/")) return self.routGith(gpa, meth, path["/gh".len..], auth, ghve, body);
        return .{ .code = 404, .body = "{\"message\":\"404 Not Found\"}" };
    }

    // one field of a form body
    fn formGetz(body: []const u8, name: []const u8) ?[]const u8 {
        var iter = std.mem.splitScalar(u8, body, '&');
        while (iter.next()) |part| {
            const eqzz = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            if (std.mem.eql(u8, part[0..eqzz], name)) return part[eqzz + 1 ..];
        }
        return null;
    }

    // mint the next OAuth token pair
    fn tokeMint(self: *Mock, gpa: std.mem.Allocator) !Answ {
        self.tokeNumb += 1;
        self.toke = try std.fmt.allocPrint(gpa, "gloas-mock-access-{d}", .{self.tokeNumb});
        self.refr = try std.fmt.allocPrint(gpa, "glrt-mock-refresh-{d}", .{self.tokeNumb});
        return .{ .body = try std.fmt.allocPrint(gpa, "{{\"access_token\":\"{s}\",\"token_type\":\"Bearer\",\"expires_in\":7200,\"refresh_token\":\"{s}\",\"scope\":\"api\",\"created_at\":1794441600}}", .{ self.toke.?, self.refr.? }) };
    }

    // OAuth device grant, refresh, revoke
    fn routOaut(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        const bad = Answ{ .code = 400, .body = "{\"error\":\"invalid_request\"}" };
        if (meth != .POST or !std.mem.startsWith(u8, ctyp, "application/x-www-form-urlencoded")) return bad;
        if (!std.mem.eql(u8, formGetz(body, "client_id") orelse "", CF.clid)) return .{ .code = 401, .body = "{\"error\":\"invalid_client\"}" };
        if (std.mem.eql(u8, path, "/oauth/authorize_device")) {
            if (!std.mem.eql(u8, formGetz(body, "scope") orelse "", "api")) return .{ .code = 400, .body = "{\"error\":\"invalid_scope\"}" };
            self.poll = 0;
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"device_code\":\"{s}\",\"user_code\":\"{s}\",\"verification_uri\":\"http://{s}:{d}/oauth/device\",\"verification_uri_complete\":\"http://{s}:{d}/oauth/device?user_code={s}\",\"expires_in\":300,\"interval\":1}}", .{ CF.deviCode, CF.userCode, CF.host, self.port, CF.host, self.port, CF.userCode }) };
        }
        if (std.mem.eql(u8, path, "/oauth/token")) {
            const gran = formGetz(body, "grant_type") orelse return bad;
            if (std.mem.eql(u8, gran, "refresh_token")) {
                if (self.refr == null or !std.mem.eql(u8, formGetz(body, "refresh_token") orelse "", self.refr.?)) return .{ .code = 400, .body = "{\"error\":\"invalid_grant\"}" };
                return self.tokeMint(gpa);
            }
            if (!std.mem.eql(u8, gran, "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code")) return .{ .code = 400, .body = "{\"error\":\"unsupported_grant_type\"}" };
            if (!std.mem.eql(u8, formGetz(body, "device_code") orelse "", CF.deviCode)) return .{ .code = 400, .body = "{\"error\":\"invalid_grant\"}" };
            if (self.user == null) return .{ .code = 400, .body = "{\"error\":\"access_denied\"}" };
            self.poll += 1;
            if (self.slowOnce) {
                self.slowOnce = false;
                return .{ .code = 400, .body = "{\"error\":\"slow_down\"}" };
            }
            if (self.poll <= self.pollNeed) return .{ .code = 400, .body = "{\"error\":\"authorization_pending\"}" };
            return self.tokeMint(gpa);
        }
        if (std.mem.eql(u8, path, "/oauth/revoke")) {
            if (self.toke != null and std.mem.eql(u8, formGetz(body, "token") orelse "", self.toke.?)) self.toke = null;
            self.revoOaut += 1;
            return .{};
        }
        return .{ .code = 404, .body = "{\"error\":\"not_found\"}" };
    }

    // project JSON as GitLab returns it
    fn projJson(self: *Mock, gpa: std.mem.Allocator) ![]u8 {
        var outp: std.ArrayList(u8) = .empty;
        try outp.print(gpa, "{{\"id\":{d},\"name\":\"{s}\",\"path\":\"{s}\",\"path_with_namespace\":\"{s}\",\"visibility\":\"{s}\",\"default_branch\":\"main\",\"statistics\":{{\"storage_size\":{d},\"repository_size\":{d}}}", .{ CF.prid, self.projName, self.projName, self.projPath.?, self.projVisi, self.storSize, self.storSize });
        for (self.projSett.items) |item| try outp.print(gpa, ",\"{s}\":{s}", .{ item.keyz, item.valu });
        try outp.append(gpa, '}');
        return outp.toOwnedSlice(gpa);
    }

    // head commit of the bare repo behind the mock project
    fn headRead(self: *Mock, gpa: std.mem.Allocator, bran: []const u8) !?[]const u8 {
        if (self.root.len == 0 or self.projPath == null) return null;
        const gdir = try std.fmt.allocPrint(gpa, "{s}/{s}.git", .{ self.root, self.projPath.? });
        const refz = try std.fmt.allocPrint(gpa, "refs/heads/{s}", .{bran});
        const resu = std.process.run(gpa, self.io, .{ .argv = &.{ self.gitz, "--git-dir", gdir, "rev-parse", "--verify", "--quiet", refz } }) catch return null;
        const text = std.mem.trim(u8, resu.stdout, " \r\n");
        return if (resu.term == .exited and resu.term.exited == 0 and text.len >= 40) text else null;
    }

    // set or replace one project setting (raw JSON value text)
    fn settPutz(self: *Mock, gpa: std.mem.Allocator, keyz: []const u8, valu: []const u8) !void {
        for (self.projSett.items) |*item| if (std.mem.eql(u8, item.keyz, keyz)) {
            item.valu = valu;
            return;
        };
        try self.projSett.append(gpa, .{ .keyz = try gpa.dupe(u8, keyz), .valu = valu });
    }

    // GitLab REST v4
    fn routGitl(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, auth: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        const miss = Answ{ .code = 404, .body = "{\"message\":\"404 Not Found\"}" };
        const badr = Answ{ .code = 400, .body = "{\"message\":\"400 Bad request\"}" };

        // public lookup, no token
        if (std.mem.eql(u8, path, "/users") and meth == .GET) {
            const name = formGetz(quer, "username") orelse return badr;
            if (self.user == null or !std.ascii.eqlIgnoreCase(self.user.?, name)) return .{ .body = "[]" };
            return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"id\":{d},\"username\":\"{s}\",\"state\":\"active\"}}]", .{ CF.usid, self.user.? }) };
        }

        // everything else needs the OAuth token
        const want = try std.fmt.allocPrint(gpa, "Bearer {s}", .{self.toke orelse "-none-"});
        if (!std.mem.eql(u8, auth, want)) return .{ .code = 401, .body = "{\"message\":\"401 Unauthorized\"}" };
        if (meth.requestHasBody() and !std.mem.startsWith(u8, ctyp, "application/json")) return .{ .code = 415, .body = "{\"message\":\"415 Unsupported Media Type\"}" };
        const json: std.json.Value = if (body.len > 0) std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr else .null;

        if (std.mem.eql(u8, path, "/user") and meth == .GET) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"username\":\"{s}\",\"email\":\"real@example.com\",\"commit_email\":\"{d}-{s}@users.noreply.gitlab.com\",\"confirmed_at\":{s}}}", .{ CF.usid, self.user.?, CF.usid, self.user.?, if (self.conf) "\"2026-11-12T00:00:00Z\"" else "null" }) };

        // ssh keys
        if (std.mem.eql(u8, path, "/user/keys")) {
            if (meth == .GET) {
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.keys.items) |item| if (!item.gone) {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":{d},\"title\":\"{s}\",\"key\":\"{s}\"}}", .{ item.iden, item.titl, item.keyz });
                };
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                if (json != .object) return badr;
                const titl = json.object.get("title") orelse return badr;
                const keyz = json.object.get("key") orelse return badr;
                if (titl != .string or keyz != .string or !std.mem.startsWith(u8, keyz.string, "ssh-ed25519 ")) return badr;
                for (self.keys.items) |item| if (!item.gone and std.mem.eql(u8, item.keyz, keyz.string)) return .{ .code = 400, .body = "{\"message\":{\"key\":[\"has already been taken\"]}}" };
                self.nextIden += 1;
                try self.keys.append(gpa, .{ .iden = self.nextIden, .titl = titl.string, .keyz = keyz.string });
                return .{ .code = 201, .body = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"title\":\"{s}\",\"key\":\"{s}\"}}", .{ self.nextIden, titl.string, keyz.string }) };
            }
        }
        if (std.mem.startsWith(u8, path, "/user/keys/") and meth == .DELETE) {
            const iden = std.fmt.parseInt(u64, path["/user/keys/".len..], 10) catch return badr;
            for (self.keys.items) |*item| if (item.iden == iden and !item.gone) {
                item.gone = true;
                return .{ .code = 204 };
            };
            return miss;
        }

        // create project
        if (std.mem.eql(u8, path, "/projects") and meth == .POST) {
            if (json != .object) return badr;
            const name = json.object.get("path") orelse return badr;
            const visi = json.object.get("visibility") orelse return badr;
            if (name != .string or visi != .string or !(std.mem.eql(u8, visi.string, "private") or std.mem.eql(u8, visi.string, "internal") or std.mem.eql(u8, visi.string, "public"))) return badr;
            if (self.projPath != null) return .{ .code = 400, .body = "{\"message\":{\"path\":[\"has already been taken\"]}}" };
            self.projPath = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.user.?, name.string });
            self.projName = name.string;
            self.projVisi = visi.string;
            try self.settPutz(gpa, "shared_runners_enabled", "true");
            try self.settPutz(gpa, "builds_access_level", "\"enabled\"");
            try self.settPutz(gpa, "container_registry_access_level", "\"enabled\"");
            try self.settPutz(gpa, "wiki_access_level", "\"enabled\"");
            if (self.root.len > 0) {
                const gdir = try std.fmt.allocPrint(gpa, "{s}/{s}.git", .{ self.root, self.projPath.? });
                _ = std.process.run(gpa, self.io, .{ .argv = &.{ self.gitz, "init", "--quiet", "--bare", "--initial-branch=main", gdir } }) catch return Answ{ .code = 500, .body = "{\"message\":\"git init failed\"}" };
            }
            return .{ .code = 201, .body = try self.projJson(gpa) };
        }

        // /projects/:id...
        if (!std.mem.startsWith(u8, path, "/projects/")) return miss;
        const rest = path["/projects/".len..];
        const slas = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const pkey = rest[0..slas];
        const tail = rest[slas..];
        const proj = self.projPath orelse return miss;
        const enco = try std.mem.replaceOwned(u8, gpa, proj, "/", "%2F");
        const idtx = try std.fmt.allocPrint(gpa, "{d}", .{CF.prid});
        if (!std.mem.eql(u8, pkey, idtx) and !std.ascii.eqlIgnoreCase(pkey, enco)) return miss;

        if (tail.len == 0 and meth == .GET) return .{ .body = try self.projJson(gpa) };
        if (tail.len == 0 and meth == .PUT) {
            if (json != .object) return badr;
            var iter = json.object.iterator();
            while (iter.next()) |entr| {
                if (std.mem.eql(u8, entr.key_ptr.*, "visibility")) return .{ .code = 400, .body = "{\"message\":\"mock: visibility change refused\"}" };
                try self.settPutz(gpa, entr.key_ptr.*, try std.json.Stringify.valueAlloc(gpa, entr.value_ptr.*, .{}));
            }
            return .{ .body = try self.projJson(gpa) };
        }

        // protected branches
        if (std.mem.eql(u8, tail, "/protected_branches") and meth == .POST) {
            if (json != .object) return badr;
            const name = json.object.get("name") orelse return badr;
            const push = json.object.get("push_access_level") orelse return badr;
            const merg = json.object.get("merge_access_level") orelse return badr;
            const forc = json.object.get("allow_force_push") orelse return badr;
            if (name != .string or push != .integer or merg != .integer or forc != .bool or !std.mem.eql(u8, name.string, "main")) return badr;
            if (self.protHave) return .{ .code = 409, .body = "{\"message\":\"Protected branch 'main' already exists\"}" };
            self.protHave = true;
            self.protPush = @intCast(push.integer);
            self.protMerg = @intCast(merg.integer);
            self.protForc = forc.bool;
        }
        if ((std.mem.eql(u8, tail, "/protected_branches/main") and meth == .GET) or (std.mem.eql(u8, tail, "/protected_branches") and meth == .POST)) {
            if (!self.protHave) return miss;
            return .{ .code = if (meth == .POST) 201 else 200, .body = try std.fmt.allocPrint(gpa, "{{\"id\":1,\"name\":\"main\",\"push_access_levels\":[{{\"id\":1,\"access_level\":{d}}}],\"merge_access_levels\":[{{\"id\":1,\"access_level\":{d}}}],\"allow_force_push\":{}}}", .{ self.protPush, self.protMerg, self.protForc }) };
        }

        // branch head
        if (std.mem.eql(u8, tail, "/repository/branches/main") and meth == .GET) {
            const head = (try self.headRead(gpa, "main")) orelse return miss;
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"main\",\"commit\":{{\"id\":\"{s}\"}}}}", .{head}) };
        }

        // project access tokens
        if (std.mem.eql(u8, tail, "/access_tokens") and meth == .POST) {
            if (self.denyAtok) return .{ .code = 403, .body = "{\"message\":\"403 Forbidden\"}" };
            if (json != .object) return badr;
            const name = json.object.get("name") orelse return badr;
            const scop = json.object.get("scopes") orelse return badr;
            const role = json.object.get("access_level") orelse return badr;
            const expi = json.object.get("expires_at") orelse return badr;
            if (name != .string or scop != .array or scop.array.items.len == 0 or role != .integer or expi != .string or expi.string.len != 10 or expi.string[4] != '-') return badr;
            self.nextIden += 1;
            const item = Atok{ .iden = self.nextIden, .name = name.string, .toke = try std.fmt.allocPrint(gpa, "glpat-mock-{d}", .{self.nextIden}), .expi = expi.string, .role = @intCast(role.integer), .scop = try std.json.Stringify.valueAlloc(gpa, scop, .{}) };
            try self.atok.append(gpa, item);
            return .{ .code = 201, .body = try atokJson(gpa, item, true) };
        }
        if (std.mem.eql(u8, tail, "/access_tokens") and meth == .GET) {
            var outp: std.ArrayList(u8) = .empty;
            try outp.append(gpa, '[');
            for (self.atok.items) |item| {
                if (outp.items.len > 1) try outp.append(gpa, ',');
                try outp.appendSlice(gpa, try atokJson(gpa, item, false));
            }
            try outp.append(gpa, ']');
            return .{ .body = outp.items };
        }
        if (std.mem.startsWith(u8, tail, "/access_tokens/")) {
            const iden = std.fmt.parseInt(u64, tail["/access_tokens/".len..], 10) catch return badr;
            for (self.atok.items) |*item| if (item.iden == iden) {
                if (meth == .GET) return .{ .body = try atokJson(gpa, item.*, false) };
                if (meth == .DELETE and !item.gone) {
                    item.gone = true;
                    return .{ .code = 204 };
                }
            };
            return miss;
        }
        return miss;
    }

    // access token JSON; the secret only on create
    fn atokJson(gpa: std.mem.Allocator, item: Atok, show: bool) ![]u8 {
        const toke = if (show) try std.fmt.allocPrint(gpa, ",\"token\":\"{s}\"", .{item.toke}) else "";
        return std.fmt.allocPrint(gpa, "{{\"id\":{d},\"name\":\"{s}\",\"expires_at\":\"{s}\",\"access_level\":{d},\"scopes\":{s},\"active\":{},\"revoked\":{}{s}}}", .{ item.iden, item.name, item.expi, item.role, item.scop, !item.gone, item.gone, toke });
    }

    // set or replace a name/value pair
    fn pairPutz(list: *std.ArrayList(Pair), gpa: std.mem.Allocator, keyz: []const u8, valu: []const u8) !bool {
        for (list.items) |*item| if (std.mem.eql(u8, item.keyz, keyz)) {
            item.valu = valu;
            return false;
        };
        try list.append(gpa, .{ .keyz = try gpa.dupe(u8, keyz), .valu = valu });
        return true;
    }

    // GitHub REST: Actions secrets, variables, workflow runs
    fn routGith(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, auth: []const u8, ghve: []const u8, body: []const u8) !Answ {
        const miss = Answ{ .code = 404, .body = "{\"message\":\"Not Found\"}" };
        const badr = Answ{ .code = 422, .body = "{\"message\":\"Validation Failed\"}" };
        if (!std.mem.eql(u8, auth, "Bearer " ++ CF.ghToke)) return .{ .code = 401, .body = "{\"message\":\"Bad credentials\"}" };
        if (!std.mem.eql(u8, ghve, CF.ghVers)) return .{ .code = 400, .body = "{\"message\":\"mock: X-GitHub-Api-Version missing\"}" };
        const pref = try std.fmt.allocPrint(gpa, "/repos/{s}/{s}/actions/", .{ self.ghOwne, self.ghRepo });
        if (!std.mem.startsWith(u8, path, pref)) return miss;
        const tail = path[pref.len..];
        const json: std.json.Value = if (body.len > 0) std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr else .null;

        if (std.mem.eql(u8, tail, "secrets/public-key") and meth == .GET) {
            var text: [b64s.Encoder.calcSize(Seal.public_length)]u8 = undefined;
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"key_id\":\"{s}\",\"key\":\"{s}\"}}", .{ CF.keyzIden, b64s.Encoder.encode(&text, &self.kpai.public_key) }) };
        }
        if (std.mem.startsWith(u8, tail, "secrets/")) {
            const name = tail["secrets/".len..];
            if (meth == .GET) return if (self.secrGetz(name) != null) .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name}) } else miss;
            if (meth == .PUT) {
                if (json != .object) return badr;
                const encr = json.object.get("encrypted_value") orelse return badr;
                const kidz = json.object.get("key_id") orelse return badr;
                if (encr != .string or kidz != .string or !std.mem.eql(u8, kidz.string, CF.keyzIden)) return badr;
                // a real sealed box, opened with the mock's private key
                const size = b64s.Decoder.calcSizeForSlice(encr.string) catch return badr;
                if (size <= Seal.seal_length) return badr;
                const ciph = try gpa.alloc(u8, size);
                b64s.Decoder.decode(ciph, encr.string) catch return badr;
                const plai = try gpa.alloc(u8, size - Seal.seal_length);
                Seal.open(plai, ciph, self.kpai) catch return badr;
                return .{ .code = if (try pairPutz(&self.secr, gpa, name, plai)) 201 else 204 };
            }
        }
        if (std.mem.eql(u8, tail, "variables") and meth == .POST) {
            if (json != .object) return badr;
            const name = json.object.get("name") orelse return badr;
            const valu = json.object.get("value") orelse return badr;
            if (name != .string or valu != .string) return badr;
            for (self.varz.items) |item| if (std.mem.eql(u8, item.keyz, name.string)) return .{ .code = 409, .body = "{\"message\":\"Already exists\"}" };
            _ = try pairPutz(&self.varz, gpa, name.string, valu.string);
            return .{ .code = 201 };
        }
        if (std.mem.startsWith(u8, tail, "variables/") and meth == .GET) {
            for (self.varz.items) |item| if (std.mem.eql(u8, item.keyz, tail["variables/".len..])) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"value\":\"{s}\"}}", .{ item.keyz, item.valu }) };
            return miss;
        }
        if (std.mem.startsWith(u8, tail, "workflows/") and std.mem.endsWith(u8, tail, "/runs") and meth == .GET) {
            if (!self.runzDone) return .{ .body = "{\"total_count\":0,\"workflow_runs\":[]}" };
            return .{ .body = "{\"total_count\":1,\"workflow_runs\":[{\"id\":1,\"status\":\"completed\",\"conclusion\":\"success\",\"head_sha\":\"" ++ CF.shaz ++ "\"}]}" };
        }
        return miss;
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
