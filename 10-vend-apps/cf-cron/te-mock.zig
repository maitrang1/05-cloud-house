// =====================================================================
// Des: A fake Cloudflare for tests. Serves the accounts, workers.dev name, Worker upload, route, cron schedule and the public Worker address on a loopback port, strict like the reference. Never a live account.
// Flo: listen on a free port > accept one request > check auth, content type and fields > change in-memory state > answer JSON > count the call
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests on 127.0.0.1:<port>; knobs set by the test
// Out: JSON answers; state the test can read back
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .toke = "cfut_FAKETOKEN_0123456789abcdefghij", .acco = "acc-mock1", .accName = "Mock Account", .rootPath = "/client/v4", .workPath = "/w/", .tickPath = "/tick" };

pub const toke = CF.toke;
pub const acco = CF.acco;

const Answ = struct { code: u16 = 200, body: []const u8 = "", retr: bool = false };
const Bnd = struct { name: []const u8, kind: []const u8, text: []const u8 };
const Wrk = struct { name: []const u8, binds: []const Bnd, route: bool = false, crons: []const []const u8 = &.{}, srcLen: usize = 0 };
pub const Tick = struct { secret: []const u8, time: []const u8, meth: []const u8 };

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,

    // state
    subd: []const u8 = "",
    wrks: std.ArrayList(Wrk) = .empty,
    ticks: std.ArrayList(Tick) = .empty,
    pushes: u32 = 0,
    schedPuts: u32 = 0,
    subPuts: u32 = 0,

    // knobs
    rateLimi: u32 = 0,
    routeNeed: u32 = 0,
    accMany: bool = false,

    // counters
    seen: u32 = 0,
    bads: u32 = 0,
    pings: u32 = 0,
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
        var tsec: []const u8 = "";
        var ttim: []const u8 = "";
        var iter = requ.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, "authorization")) auth = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "content-type")) ctyp = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "x-tick-secret")) tsec = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "x-tick-time")) ttim = try gpa.dupe(u8, head.value);
        }
        var bbuf: [4096]u8 = undefined;
        const body = if (meth.requestHasBody()) try (try requ.readerExpectContinue(&bbuf)).allocRemaining(gpa, .limited(CF.bodyMaxz)) else "";

        self.seen += 1;
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse targ.len;
        try self.logz.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ @tagName(meth), targ[0..ques] }));
        const path = targ[0..ques];
        const answ = blk: {
            // the Trigger endpoint the tick Worker calls
            if (std.mem.eql(u8, path, CF.tickPath)) {
                try self.ticks.append(gpa, .{ .secret = tsec, .time = ttim, .meth = try gpa.dupe(u8, @tagName(meth)) });
                break :blk Answ{ .code = 202, .body = "{\"ok\":true}" };
            }
            break :blk self.rout(gpa, meth, path, auth, ctyp, body) catch Answ{ .code = 500, .body = fail("mock crashed") };
        };
        if (answ.code >= 400 and answ.code != 404 and answ.code != 429 and answ.code != 503) self.bads += 1;
        const retr = [_]std.http.Header{ .{ .name = "Retry-After", .value = "1" }, .{ .name = "Content-Type", .value = "application/json" } };
        const norm = [_]std.http.Header{ .{ .name = "Content-Type", .value = "application/json" } };
        try requ.respond(answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &retr else &norm });
    }

    // the error envelope Cloudflare sends
    fn fail(comptime mess: []const u8) []const u8 {
        return std.fmt.comptimePrint("{{\"success\":false,\"errors\":[{{\"code\":10000,\"message\":\"{s}\"}}],\"messages\":[],\"result\":null}}", .{mess});
    }

    fn miss() Answ {
        return .{ .code = 404, .body = fail("not found") };
    }

    fn badr(comptime why: []const u8) Answ {
        return .{ .code = 400, .body = fail("bad request " ++ why) };
    }

    fn okay(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Answ {
        return .{ .body = try std.fmt.allocPrint(gpa, "{{\"success\":true,\"errors\":[],\"messages\":[],\"result\":" ++ fmt ++ "}}", args) };
    }

    fn wrkFind(self: *Mock, name: []const u8) ?*Wrk {
        for (self.wrks.items) |*item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }

    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, auth: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        // the public Worker address: 200 once the route is on (503 for `routeNeed` pings first)
        if (std.mem.startsWith(u8, path, CF.workPath) and meth == .GET) {
            const wrk = self.wrkFind(path[CF.workPath.len..]) orelse return miss();
            if (!wrk.route) return miss();
            self.pings += 1;
            if (self.pings <= self.routeNeed) return .{ .code = 503, .body = fail("not yet") };
            return .{ .body = "cf-cron ok" };
        }
        if (self.rateLimi > 0) {
            self.rateLimi -= 1;
            return .{ .code = 429, .body = fail("rate limited"), .retr = true };
        }
        if (!std.mem.startsWith(u8, path, CF.rootPath ++ "/")) return miss();
        const want = try std.fmt.allocPrint(gpa, "Bearer {s}", .{CF.toke});
        if (!std.mem.eql(u8, auth, want)) return .{ .code = 401, .body = fail("Authentication error") };
        const rest = path[CF.rootPath.len..];

        if (std.mem.eql(u8, rest, "/accounts") and meth == .GET) {
            if (self.accMany) return okay(gpa, "[{{\"id\":\"acc-other\",\"name\":\"Other\"}},{{\"id\":\"{s}\",\"name\":\"{s}\"}}]", .{ CF.acco, CF.accName });
            return okay(gpa, "[{{\"id\":\"{s}\",\"name\":\"{s}\"}}]", .{ CF.acco, CF.accName });
        }
        const pref = "/accounts/" ++ CF.acco ++ "/workers/";
        if (!std.mem.startsWith(u8, rest, pref)) return miss();
        const tail = rest[pref.len..];

        if (std.mem.eql(u8, tail, "subdomain")) {
            if (meth == .GET) {
                if (self.subd.len == 0) return miss();
                return okay(gpa, "{{\"subdomain\":\"{s}\"}}", .{self.subd});
            }
            if (meth == .PUT) {
                if (!std.mem.startsWith(u8, ctyp, "application/json")) return .{ .code = 415, .body = fail("unsupported media type") };
                const json = std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr("json");
                const name = strGetz(json, "subdomain") orelse return badr("subdomain");
                if (name.len < 3) return badr("subdomain short");
                for (name) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return badr("subdomain chars");
                self.subd = try gpa.dupe(u8, name);
                self.subPuts += 1;
                return okay(gpa, "{{\"subdomain\":\"{s}\"}}", .{name});
            }
            return miss();
        }
        if (!std.mem.startsWith(u8, tail, "scripts/")) return miss();
        const rem = tail["scripts/".len..];
        const slas = std.mem.indexOfScalar(u8, rem, '/');
        const name = if (slas) |s| rem[0..s] else rem;
        const sub = if (slas) |s| rem[s..] else "";

        if (sub.len == 0 and meth == .PUT) return self.upload(gpa, name, ctyp, body);
        const wrk = self.wrkFind(name) orelse return miss();
        if (std.mem.eql(u8, sub, "/settings") and meth == .GET) return okay(gpa, "{{\"bindings\":[]}}", .{});
        if (std.mem.eql(u8, sub, "/subdomain") and meth == .POST) {
            if (self.subd.len == 0) return .{ .code = 400, .body = fail("account has no workers.dev subdomain") };
            if (!std.mem.startsWith(u8, ctyp, "application/json")) return .{ .code = 415, .body = fail("unsupported media type") };
            const json = std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr("json");
            if (json != .object) return badr("body");
            const enab = json.object.get("enabled") orelse return badr("enabled");
            if (enab != .bool) return badr("enabled");
            wrk.route = enab.bool;
            return okay(gpa, "{{\"enabled\":{s},\"previews_enabled\":false}}", .{if (wrk.route) "true" else "false"});
        }
        if (std.mem.eql(u8, sub, "/schedules")) {
            if (meth == .GET) return self.schedJson(gpa, wrk.*);
            if (meth == .PUT) {
                if (!std.mem.startsWith(u8, ctyp, "application/json")) return .{ .code = 415, .body = fail("unsupported media type") };
                const json = std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return badr("json");
                if (json != .array) return badr("array");
                var next: std.ArrayList([]const u8) = .empty;
                for (json.array.items) |item| {
                    const cron = strGetz(item, "cron") orelse return badr("cron");
                    if (!cronOkay(cron)) return badr("cron syntax");
                    try next.append(gpa, try gpa.dupe(u8, cron));
                }
                if (next.items.len > 3) return .{ .code = 400, .body = fail("too many cron triggers") };
                wrk.crons = next.items;
                self.schedPuts += 1;
                return self.schedJson(gpa, wrk.*);
            }
        }
        return miss();
    }

    // "*/N * * * *" with N in 1..59: the only shape this app sends
    fn cronOkay(cron: []const u8) bool {
        if (!std.mem.startsWith(u8, cron, "*/") or !std.mem.endsWith(u8, cron, " * * * *")) return false;
        const num = std.fmt.parseInt(u32, cron[2 .. cron.len - " * * * *".len], 10) catch return false;
        return num >= 1 and num <= 59;
    }

    fn schedJson(self: *Mock, gpa: std.mem.Allocator, wrk: Wrk) !Answ {
        _ = self;
        var outp: std.ArrayList(u8) = .empty;
        for (wrk.crons, 0..) |item, indx| {
            if (indx > 0) try outp.append(gpa, ',');
            try outp.print(gpa, "{{\"cron\":\"{s}\",\"created_on\":\"x\",\"modified_on\":\"x\"}}", .{item});
        }
        return okay(gpa, "{{\"schedules\":[{s}]}}", .{outp.items});
    }

    fn strGetz(obj: std.json.Value, name: []const u8) ?[]const u8 {
        if (obj != .object) return null;
        const item = obj.object.get(name) orelse return null;
        return if (item == .string) item.string else null;
    }

    // PUT script: strict multipart check like the reference
    fn upload(self: *Mock, gpa: std.mem.Allocator, name: []const u8, ctyp: []const u8, body: []const u8) !Answ {
        const key = "boundary=";
        if (!std.mem.startsWith(u8, ctyp, "multipart/form-data")) return .{ .code = 415, .body = fail("unsupported media type") };
        const bpos = std.mem.indexOf(u8, ctyp, key) orelse return badr("boundary");
        const delim = try std.fmt.allocPrint(gpa, "--{s}", .{ctyp[bpos + key.len ..]});
        var meta: ?std.json.Value = null;
        var modl: ?[]const u8 = null;
        var parts = std.mem.splitSequence(u8, body, delim);
        while (parts.next()) |raw| {
            const part = std.mem.trimStart(u8, raw, "\r\n");
            if (part.len == 0 or std.mem.startsWith(u8, part, "--")) continue;
            const sepa = std.mem.indexOf(u8, part, "\r\n\r\n") orelse return badr("part");
            const heads = part[0..sepa];
            const cont = std.mem.trimEnd(u8, part[sepa + 4 ..], "\r\n");
            if (std.mem.indexOf(u8, heads, "name=\"metadata\"") != null) {
                meta = std.json.parseFromSliceLeaky(std.json.Value, gpa, cont, .{}) catch return badr("metadata json");
            } else if (std.mem.indexOf(u8, heads, "name=\"worker.js\"") != null) {
                if (std.mem.indexOf(u8, heads, "application/javascript+module") == null) return badr("module type");
                modl = cont;
            }
        }
        const mval = meta orelse return badr("metadata");
        const code = modl orelse return badr("module");
        if (!std.mem.eql(u8, strGetz(mval, "main_module") orelse "", "worker.js")) return badr("main_module");
        if (strGetz(mval, "compatibility_date") == null) return badr("compat date");
        if (std.mem.indexOf(u8, code, "scheduled") == null) return badr("no scheduled handler");
        const bval = mval.object.get("bindings") orelse return badr("bindings");
        if (bval != .array) return badr("bindings");
        var binds: std.ArrayList(Bnd) = .empty;
        for (bval.array.items) |item| {
            const kind = strGetz(item, "type") orelse return badr("binding type");
            if (!std.mem.eql(u8, kind, "plain_text") and !std.mem.eql(u8, kind, "secret_text")) return badr("binding kind");
            try binds.append(gpa, .{ .name = try gpa.dupe(u8, strGetz(item, "name") orelse return badr("binding name")), .kind = try gpa.dupe(u8, kind), .text = try gpa.dupe(u8, strGetz(item, "text") orelse return badr("binding text")) });
        }
        self.pushes += 1;
        if (self.wrkFind(name)) |old| {
            old.binds = binds.items;
            old.srcLen = code.len;
        } else try self.wrks.append(gpa, .{ .name = try gpa.dupe(u8, name), .binds = binds.items, .srcLen = code.len });
        return okay(gpa, "{{\"id\":\"{s}\"}}", .{name});
    }

    // what real Cloudflare does on a cron minute: call the Worker's TRIGGER_URL with its bindings
    pub fn fire(self: *Mock, gpa: std.mem.Allocator, name: []const u8) !bool {
        var urlz: []const u8 = "";
        var meth: []const u8 = "POST";
        var head: []const u8 = "";
        var secr: []const u8 = "";
        {
            self.lock();
            defer self.unlo();
            const wrk = self.wrkFind(name) orelse return false;
            if (wrk.crons.len == 0) return false;
            for (wrk.binds) |item| {
                if (std.mem.eql(u8, item.name, "TRIGGER_URL")) urlz = try gpa.dupe(u8, item.text);
                if (std.mem.eql(u8, item.name, "TRIGGER_METHOD")) meth = try gpa.dupe(u8, item.text);
                if (std.mem.eql(u8, item.name, "SECRET_HEADER")) head = try gpa.dupe(u8, item.text);
                if (std.mem.eql(u8, item.name, "TICK_SECRET")) secr = try gpa.dupe(u8, item.text);
            }
        }
        var clie = std.http.Client{ .allocator = gpa, .io = self.io };
        defer clie.deinit();
        const xtra = [_]std.http.Header{ .{ .name = head, .value = secr }, .{ .name = "x-tick-time", .value = "1" } };
        const used: []const std.http.Header = if (secr.len > 0) &xtra else xtra[1..];
        var outp: std.Io.Writer.Allocating = .init(gpa);
        defer outp.deinit();
        const resu = try clie.fetch(.{ .location = .{ .url = urlz }, .method = std.meta.stringToEnum(std.http.Method, meth) orelse .POST, .extra_headers = used, .payload = "", .response_writer = &outp.writer });
        return resu.status == .accepted;
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
