// =====================================================================
// Des: A pretend Render for tests. Runs on this machine on a spare port, checks requests strictly like the public API reference says, and never touches a live account.
// Flo: listen on a free port > accept one request > check auth, content type and fields > change in-memory state > answer JSON > count the call
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests on 127.0.0.1:<port>; knobs set by the test
// Out: JSON answers; state the test can read back
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .keyz = "rnd_FAKEKEY", .owne = "tea-mock1", .ownName = "Mock Team", .wakePath = "/svc/", .idPref = "srv-mock" };

pub const keyz = CF.keyz;
pub const owne = CF.owne;

const Pair = struct { key: []const u8, value: []const u8 };
const Svc = struct { id: []const u8, name: []const u8, plan: []const u8, heal: []const u8, imag: []const u8, regi: []const u8, susp: bool = false };
const Answ = struct { code: u16 = 200, body: []const u8 = "{}", retr: bool = false };

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,

    // state
    svcs: std.ArrayList(Svc) = .empty,
    envs: std.ArrayList(Pair) = .empty,
    deploys: u32 = 0,
    paidMade: u32 = 0,
    nextIden: u32 = 0,

    // knobs
    rateLimi: u32 = 0,
    coldNeed: u32 = 0,
    ownMany: bool = false,

    // counters
    seen: u32 = 0,
    bads: u32 = 0,
    wakes: u32 = 0,
    logz: std.ArrayList([]const u8) = .empty,

    // listen on a system-chosen port (or `want`) and serve from a thread
    pub fn star(io: std.Io, want: u16) !*Mock {
        const self = try std.heap.smp_allocator.create(Mock);
        errdefer std.heap.smp_allocator.destroy(self);
        var addr = try std.Io.net.IpAddress.parse(CF.host, want);
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

    // url under the mock, caller frees
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
        self.lock();
        defer self.unlo();
        var coun: u32 = 0;
        for (self.logz.items) |item| if (std.mem.startsWith(u8, item, need)) {
            coun += 1;
        };
        return coun;
    }

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
        const answ = self.rout(gpa, meth, targ[0..ques], if (ques < targ.len) targ[ques + 1 ..] else "", auth, ctyp, body) catch Answ{ .code = 500, .body = "{\"message\":\"mock crashed\"}" };
        if (answ.code >= 400 and answ.code != 404 and answ.code != 429 and answ.code != 503) self.bads += 1;
        const retr = [_]std.http.Header{ .{ .name = "Retry-After", .value = "1" }, .{ .name = "Content-Type", .value = "application/json" } };
        const norm = [_]std.http.Header{ .{ .name = "RateLimit-Remaining", .value = "99" }, .{ .name = "Content-Type", .value = "application/json" } };
        try requ.respond(if (answ.code == 204) "" else answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &retr else &norm });
    }

    fn miss() Answ {
        return .{ .code = 404, .body = "{\"message\":\"not found\"}" };
    }

    fn badr(why: []const u8) Answ {
        _ = why;
        return .{ .code = 400, .body = "{\"message\":\"bad request\"}" };
    }

    // the public wake path: 503 until `coldNeed` pings passed, then 200
    fn wake(self: *Mock, path: []const u8) Answ {
        const rest = path[CF.wakePath.len..];
        const slas = std.mem.indexOfScalar(u8, rest, '/') orelse return miss();
        for (self.svcs.items) |item| if (std.mem.eql(u8, item.name, rest[0..slas]) and std.mem.eql(u8, rest[slas..], item.heal)) {
            self.wakes += 1;
            if (self.wakes <= self.coldNeed) return .{ .code = 503, .body = "{\"message\":\"waking up\"}" };
            return .{ .body = "{\"ok\":true}" };
        };
        return miss();
    }

    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, auth: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        if (std.mem.startsWith(u8, path, CF.wakePath) and meth == .GET) return self.wake(path);
        if (self.rateLimi > 0) {
            self.rateLimi -= 1;
            return .{ .code = 429, .body = "{\"message\":\"rate limited\"}", .retr = true };
        }
        if (!std.mem.startsWith(u8, path, "/v1/")) return miss();
        const want = try std.fmt.allocPrint(gpa, "Bearer {s}", .{CF.keyz});
        if (!std.mem.eql(u8, auth, want)) return .{ .code = 401, .body = "{\"message\":\"Unauthorized\"}" };
        if (meth.requestHasBody() and !std.mem.startsWith(u8, ctyp, "application/json")) return .{ .code = 415, .body = "{\"message\":\"unsupported media type\"}" };
        const json: std.json.Value = if (body.len > 0) std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr("json") else .null;
        const rest = path["/v1".len..];

        if (std.mem.eql(u8, rest, "/owners") and meth == .GET) {
            if (self.ownMany) return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"cursor\":\"c0\",\"owner\":{{\"id\":\"tea-other\",\"name\":\"Other\",\"email\":\"o@example.com\",\"type\":\"team\"}}}},{{\"cursor\":\"c1\",\"owner\":{{\"id\":\"{s}\",\"name\":\"{s}\",\"email\":\"m@example.com\",\"type\":\"team\"}}}}]", .{ CF.owne, CF.ownName }) };
            return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"cursor\":\"c1\",\"owner\":{{\"id\":\"{s}\",\"name\":\"{s}\",\"email\":\"m@example.com\",\"type\":\"team\"}}}}]", .{ CF.owne, CF.ownName }) };
        }
        if (std.mem.eql(u8, rest, "/services")) {
            if (meth == .GET) return self.list(gpa, quer);
            if (meth == .POST) return self.create(gpa, json);
        }
        if (std.mem.startsWith(u8, rest, "/services/")) {
            const tail = rest["/services/".len..];
            const slas = std.mem.indexOfScalar(u8, tail, '/');
            const iden = if (slas) |s| tail[0..s] else tail;
            const sub = if (slas) |s| tail[s..] else "";
            const svc = self.svcFind(iden) orelse return miss();
            if (sub.len == 0 and meth == .GET) return .{ .body = try self.svcJson(gpa, svc.*) };
            if (sub.len == 0 and meth == .PATCH) return self.patch(gpa, svc, json);
            if (std.mem.eql(u8, sub, "/env-vars") and meth == .PUT) return self.putEnvs(gpa, json);
            if (std.mem.eql(u8, sub, "/deploys") and meth == .POST) {
                self.deploys += 1;
                return .{ .code = 201, .body = "{\"id\":\"dep-mock\",\"status\":\"created\"}" };
            }
            if (std.mem.eql(u8, sub, "/suspend") and meth == .POST) {
                svc.susp = true;
                return .{ .code = 202, .body = "{}" };
            }
        }
        return miss();
    }

    fn svcFind(self: *Mock, iden: []const u8) ?*Svc {
        for (self.svcs.items) |*item| if (std.mem.eql(u8, item.id, iden)) return item;
        return null;
    }

    // a service as the API returns it; the url points back at this mock's wake path
    fn svcJson(self: *Mock, gpa: std.mem.Allocator, svc: Svc) ![]u8 {
        return std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"type\":\"web_service\",\"ownerId\":\"{s}\",\"suspended\":\"{s}\",\"dashboardUrl\":\"http://{s}:{d}/dash/{s}\",\"serviceDetails\":{{\"url\":\"http://{s}:{d}{s}{s}\",\"plan\":\"{s}\",\"region\":\"{s}\",\"healthCheckPath\":\"{s}\"}}}}", .{ svc.id, svc.name, CF.owne, if (svc.susp) "suspended" else "not_suspended", CF.host, self.port, svc.id, CF.host, self.port, CF.wakePath, svc.name, svc.plan, svc.regi, svc.heal });
    }

    fn list(self: *Mock, gpa: std.mem.Allocator, quer: []const u8) !Answ {
        var name: []const u8 = "";
        var iter = std.mem.splitScalar(u8, quer, '&');
        while (iter.next()) |part| if (std.mem.startsWith(u8, part, "name=")) {
            name = part["name=".len..];
        };
        var outp: std.ArrayList(u8) = .empty;
        try outp.append(gpa, '[');
        for (self.svcs.items) |item| if (name.len == 0 or std.mem.eql(u8, item.name, name)) {
            if (outp.items.len > 1) try outp.append(gpa, ',');
            try outp.print(gpa, "{{\"cursor\":\"c\",\"service\":{s}}}", .{try self.svcJson(gpa, item)});
        };
        try outp.append(gpa, ']');
        return .{ .body = outp.items };
    }

    fn strGetz(obj: std.json.Value, name: []const u8) ?[]const u8 {
        if (obj != .object) return null;
        const item = obj.object.get(name) orelse return null;
        return if (item == .string) item.string else null;
    }

    // POST /services, strict like the reference
    fn create(self: *Mock, gpa: std.mem.Allocator, json: std.json.Value) !Answ {
        if (json != .object) return badr("body");
        const kind = strGetz(json, "type") orelse return badr("type");
        const name = strGetz(json, "name") orelse return badr("name");
        const ownr = strGetz(json, "ownerId") orelse return badr("ownerId");
        if (!std.mem.eql(u8, kind, "web_service") or !std.mem.eql(u8, ownr, CF.owne)) return badr("kind/owner");
        const imag = json.object.get("image") orelse return badr("image");
        const path = strGetz(imag, "imagePath") orelse return badr("imagePath");
        if (path.len == 0 or !std.mem.eql(u8, strGetz(imag, "ownerId") orelse "", CF.owne)) return badr("image");
        const detz = json.object.get("serviceDetails") orelse return badr("details");
        if (!std.mem.eql(u8, strGetz(detz, "runtime") orelse "", "image")) return badr("runtime");
        const plan = strGetz(detz, "plan") orelse return badr("plan");
        const regi = strGetz(detz, "region") orelse return badr("region");
        const heal = strGetz(detz, "healthCheckPath") orelse return badr("heal");
        for (self.svcs.items) |item| if (std.mem.eql(u8, item.name, name)) return .{ .code = 409, .body = "{\"message\":\"service name already in use\"}" };
        if (!std.mem.eql(u8, plan, "free")) self.paidMade += 1;
        self.nextIden += 1;
        const svc = Svc{ .id = try std.fmt.allocPrint(gpa, "{s}{d}", .{ CF.idPref, self.nextIden }), .name = try gpa.dupe(u8, name), .plan = try gpa.dupe(u8, plan), .heal = try gpa.dupe(u8, heal), .imag = try gpa.dupe(u8, path), .regi = try gpa.dupe(u8, regi) };
        try self.svcs.append(gpa, svc);
        self.deploys += 1;
        return .{ .code = 201, .body = try std.fmt.allocPrint(gpa, "{{\"service\":{s},\"deployId\":\"dep-mock\"}}", .{try self.svcJson(gpa, svc)}) };
    }

    // PATCH: only the health path may change; a plan in the body is refused
    fn patch(self: *Mock, gpa: std.mem.Allocator, svc: *Svc, json: std.json.Value) !Answ {
        _ = self;
        if (json != .object) return badr("body");
        const detz = json.object.get("serviceDetails") orelse return badr("details");
        if (strGetz(detz, "plan") != null) return .{ .code = 400, .body = "{\"message\":\"plan change refused by the mock\"}" };
        if (strGetz(detz, "healthCheckPath")) |heal| svc.heal = try gpa.dupe(u8, heal);
        return .{ .body = "{}" };
    }

    // PUT env-vars replaces the whole list
    fn putEnvs(self: *Mock, gpa: std.mem.Allocator, json: std.json.Value) !Answ {
        if (json != .array) return badr("array");
        var next: std.ArrayList(Pair) = .empty;
        for (json.array.items) |item| {
            const key = strGetz(item, "key") orelse return badr("key");
            const valu = strGetz(item, "value") orelse return badr("value");
            try next.append(gpa, .{ .key = try gpa.dupe(u8, key), .value = try gpa.dupe(u8, valu) });
        }
        self.envs = next;
        return .{ .body = "[]" };
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
