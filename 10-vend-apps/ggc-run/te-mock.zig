// =====================================================================
// Des: A pretend Google Cloud for tests. Serves the 8 APIs the app uses on one spare loopback port, checks requests strictly like the real services (token, quota header, etag, billing order, field limits), and never touches a real account.
// Flo: listen on a free port > accept a request > check token + header > route by path prefix > change in-memory state > answer JSON > log the call
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests on 127.0.0.1:<port>; knobs set by the test
// Out: JSON answers; state and a request log the test can read back
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .toke = "ya29.mock-token", .bill = "AAAA-BBBB-CCCC", .numBase = 700000, .etag0 = "BwAAA0", .userMem = "user:owner@example.com", .keyEnabled = "serviceusage.googleapis.com" };

pub const toke = CF.toke;
pub const bill = CF.bill;

const Answ = struct { code: u16 = 200, body: []const u8 = "{}", retr: bool = false };
const Proj = struct { iden: []const u8, numb: u64, bill: bool = false, apis: std.ArrayList([]const u8) = .empty };
const Op = struct { name: []const u8, left: u32 };
const Budg = struct { name: []const u8, numb: []const u8, units: []const u8, rules: usize };
const Repo = struct { path: []const u8, uri: []const u8 };
const Svc = struct { name: []const u8, image: []const u8, sacc: []const u8, mini: i64, maxi: i64, idle: bool, cpu: []const u8, mem: []const u8, conc: i64, time: []const u8, ingr: []const u8, uri: []const u8, ready: bool, gens: u32 };

// an IAM policy kept as JSON text plus a counter for its etag
const Pol = struct { text: []const u8, tagn: u32 = 0 };

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,

    // knobs
    lroPend: u32 = 1,
    billAfter: u32 = 0,
    rateLimi: u32 = 0,
    denyPubl: bool = false,
    saDelay: u32 = 0,
    svcFail: bool = false,
    useReqs: i64 = 0,
    useCpuz: f64 = 0,
    useMemo: f64 = 0,
    billTwo: bool = false,
    tickCode: u16 = 202,

    // state
    projs: std.ArrayList(Proj) = .empty,
    ops: std.ArrayList(Op) = .empty,
    budgs: std.ArrayList(Budg) = .empty,
    sas: std.ArrayList([]const u8) = .empty,
    repos: std.ArrayList(Repo) = .empty,
    svc: ?Svc = null,
    projPol: Pol = .{ .text = "" },
    svcPol: Pol = .{ .text = "" },
    billPoll: u32 = 0,
    nextNumb: u64 = CF.numBase,
    nextOp: u32 = 0,
    tickRuns: u32 = 0,
    tickIds: std.ArrayList([]const u8) = .empty,

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
        const gpa = self.aren.allocator();
        self.projPol = .{ .text = try std.fmt.allocPrint(gpa, "{{\"version\":1,\"etag\":\"{s}\",\"bindings\":[{{\"role\":\"roles/owner\",\"members\":[\"{s}\"]}}],\"auditConfigs\":[{{\"service\":\"allServices\",\"auditLogConfigs\":[{{\"logType\":\"ADMIN_READ\"}}]}}]}}", .{ CF.etag0, CF.userMem }) };
        self.svcPol = .{ .text = try std.fmt.allocPrint(gpa, "{{\"version\":1,\"etag\":\"{s}\"}}", .{CF.etag0}) };
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

    // base url of one API, caller frees
    pub fn base(self: *Mock, gpa: std.mem.Allocator, api: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://{s}:{d}/{s}", .{ CF.host, self.port, api });
    }

    pub fn lock(self: *Mock) void {
        self.mute.lockUncancelable(self.io);
    }

    pub fn unlo(self: *Mock) void {
        self.mute.unlock(self.io);
    }

    // how many requests started with "METHOD path-prefix"
    pub fn seenCoun(self: *Mock, need: []const u8) u32 {
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
        const meth = requ.head.method;
        const targ = try gpa.dupe(u8, requ.head.target);
        var auth: []const u8 = "";
        var quot: []const u8 = "";
        var runid: []const u8 = "";
        var iter = requ.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, "authorization")) auth = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "x-goog-user-project")) quot = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "x-run-id")) runid = try gpa.dupe(u8, head.value);
        }
        var bbuf: [4096]u8 = undefined;
        const body = if (meth.requestHasBody()) try (try requ.readerExpectContinue(&bbuf)).allocRemaining(gpa, .limited(CF.bodyMaxz)) else "";
        self.seen += 1;
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse targ.len;
        try self.logz.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s} q={s}", .{ @tagName(meth), targ[0..ques], quot }));
        const answ = self.rout(gpa, meth, targ[0..ques], if (ques < targ.len) targ[ques + 1 ..] else "", auth, quot, runid, body) catch Answ{ .code = 500, .body = "{\"error\":{\"message\":\"mock crashed\"}}" };
        if (answ.code >= 400 and answ.code != 404 and answ.code != 429 and answ.code != 403 and answ.code != 409) self.bads += 1;
        const hdrs = [_]std.http.Header{ .{ .name = "Retry-After", .value = "1" }, .{ .name = "Content-Type", .value = "application/json" } };
        try requ.respond(answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &hdrs else hdrs[1..] });
    }

    // a Google-shaped error body
    fn errj(gpa: std.mem.Allocator, code: u16, mess: []const u8) !Answ {
        return .{ .code = code, .body = try std.fmt.allocPrint(gpa, "{{\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, mess }) };
    }

    // text after a prefix, or null
    fn after(path: []const u8, pref: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, path, pref)) path[pref.len..] else null;
    }

    // pick the API by the first path part
    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, auth: []const u8, quot: []const u8, runid: []const u8, body: []const u8) !Answ {
        if (after(path, "/svc/")) |rest| {
            if (std.mem.endsWith(u8, rest, "/tick") and meth == .POST) {
                for (self.tickIds.items) |item| if (std.mem.eql(u8, item, runid)) return .{ .code = self.tickCode };
                self.tickRuns += 1;
                try self.tickIds.append(gpa, try gpa.dupe(u8, runid));
                return .{ .code = self.tickCode };
            }
            return .{ .code = 404 };
        }
        if (self.rateLimi > 0) {
            self.rateLimi -= 1;
            return .{ .code = 429, .body = "{\"error\":{\"code\":429,\"message\":\"rate limited\"}}", .retr = true };
        }
        const want = try std.fmt.allocPrint(gpa, "Bearer {s}", .{CF.toke});
        if (!std.mem.eql(u8, auth, want)) return errj(gpa, 401, "bad or missing bearer token");
        if (meth.requestHasBody() and body.len == 0) return errj(gpa, 400, "empty body");
        const json: std.json.Value = if (body.len > 0) std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return errj(gpa, 400, "bad json") else .null;
        if (after(path, "/crm/")) |rest| return self.routCrm(gpa, meth, rest, json);
        if (after(path, "/bill/")) |rest| return self.routBill(gpa, meth, rest, json);
        if (after(path, "/budg/")) |rest| return self.routBudg(gpa, meth, rest, quot, json);
        if (after(path, "/usag/")) |rest| return self.routUsag(gpa, meth, rest, json);
        if (after(path, "/iam/")) |rest| return self.routIam(gpa, meth, rest, quot, json);
        if (after(path, "/arti/")) |rest| return self.routArti(gpa, meth, rest, quer, quot, json);
        if (after(path, "/run/")) |rest| return self.routRun(gpa, meth, rest, quer, quot, json);
        if (after(path, "/moni/")) |rest| return self.routMoni(gpa, meth, rest, quer, quot);
        return errj(gpa, 404, "no such api");
    }

    // the project with this id
    fn projOf(self: *Mock, iden: []const u8) ?*Proj {
        for (self.projs.items) |*item| if (std.mem.eql(u8, item.iden, iden)) return item;
        return null;
    }

    // true when the API is enabled on the project
    pub fn apiOn(self: *Mock, iden: []const u8, api: []const u8) bool {
        const pro = self.projOf(iden) orelse return false;
        for (pro.apis.items) |item| if (std.mem.eql(u8, item, api)) return true;
        return false;
    }

    // start an operation: done at once when lroPend is 0
    fn opNew(self: *Mock, gpa: std.mem.Allocator, name: []const u8) !Answ {
        try self.ops.append(gpa, .{ .name = name, .left = self.lroPend });
        return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"done\":{s}}}", .{ name, if (self.lroPend == 0) "true" else "false" }) };
    }

    // poll an operation by name
    fn opGet(self: *Mock, gpa: std.mem.Allocator, name: []const u8) !Answ {
        for (self.ops.items) |*item| if (std.mem.eql(u8, item.name, name)) {
            if (item.left > 0) {
                item.left -= 1;
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"done\":false}}", .{name}) };
            }
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"done\":true,\"response\":{{}}}}", .{name}) };
        };
        return errj(gpa, 404, "no such operation");
    }

    // read a policy: the text with the current etag
    fn polGet(pol: *Pol) Answ {
        return .{ .body = pol.text };
    }

    // write a policy: the etag must match; keep every field the client sent
    fn polSet(self: *Mock, gpa: std.mem.Allocator, pol: *Pol, json: std.json.Value, publCheck: bool) !Answ {
        if (json != .object) return errj(gpa, 400, "no policy");
        const newp = json.object.get("policy") orelse return errj(gpa, 400, "no policy");
        if (newp != .object) return errj(gpa, 400, "no policy");
        const cur = try std.json.parseFromSliceLeaky(std.json.Value, gpa, pol.text, .{});
        const have = (cur.object.get("etag") orelse .null);
        const sent = (newp.object.get("etag") orelse .null);
        if (have != .string or sent != .string or !std.mem.eql(u8, have.string, sent.string)) return errj(gpa, 409, "etag mismatch");
        const text = try std.json.Stringify.valueAlloc(gpa, newp, .{});
        if (publCheck and self.denyPubl and std.mem.indexOf(u8, text, "allUsers") != null) return errj(gpa, 403, "Policy update blocked by org policy: allUsers");
        pol.tagn += 1;
        const fresh = try std.fmt.allocPrint(gpa, "BwBBB{d}", .{pol.tagn});
        var obj = newp.object;
        try obj.put(gpa, "etag", .{ .string = fresh });
        pol.text = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = obj }, .{});
        return .{ .body = pol.text };
    }

    // Cloud Resource Manager v3 and v1
    fn routCrm(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, json: std.json.Value) !Answ {
        if (std.mem.eql(u8, path, "v3/projects:search") and meth == .GET) return .{ .body = "{\"projects\":[]}" };
        if (std.mem.eql(u8, path, "v3/projects") and meth == .POST) {
            if (json != .object) return errj(gpa, 400, "no body");
            const iden = json.object.get("projectId") orelse return errj(gpa, 400, "projectId missing");
            const disp = json.object.get("displayName") orelse return errj(gpa, 400, "displayName missing");
            if (iden != .string or disp != .string or disp.string.len == 0) return errj(gpa, 400, "bad fields");
            if (iden.string.len < 6 or iden.string.len > 30 or !std.ascii.isLower(iden.string[0])) return errj(gpa, 400, "illegal project id");
            if (self.projOf(iden.string) != null) return errj(gpa, 409, "project id already exists");
            self.nextNumb += 1;
            var pro = Proj{ .iden = try gpa.dupe(u8, iden.string), .numb = self.nextNumb };
            try pro.apis.append(gpa, CF.keyEnabled);
            try self.projs.append(gpa, pro);
            self.nextOp += 1;
            return self.opNew(gpa, try std.fmt.allocPrint(gpa, "operations/cp.{d}", .{self.nextOp}));
        }
        if (after(path, "v3/operations/")) |name| return self.opGet(gpa, try std.fmt.allocPrint(gpa, "operations/{s}", .{name}));
        if (after(path, "v3/projects/")) |iden| {
            const pro = self.projOf(iden) orelse return errj(gpa, 403, "The caller does not have permission");
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"projects/{d}\",\"projectId\":\"{s}\",\"state\":\"ACTIVE\",\"displayName\":\"x\"}}", .{ pro.numb, pro.iden }) };
        }
        if (after(path, "v1/projects/")) |rest| {
            if (std.mem.endsWith(u8, rest, ":getIamPolicy") and meth == .POST) return polGet(&self.projPol);
            if (std.mem.endsWith(u8, rest, ":setIamPolicy") and meth == .POST) {
                if (self.saDelay > 0) {
                    self.saDelay -= 1;
                    return errj(gpa, 400, "Service account does not exist");
                }
                return self.polSet(gpa, &self.projPol, json, false);
            }
        }
        return errj(gpa, 404, "no such crm route");
    }

    // Cloud Billing v1
    fn routBill(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, json: std.json.Value) !Answ {
        if (std.mem.eql(u8, path, "v1/billingAccounts") and meth == .GET) {
            self.billPoll += 1;
            if (self.billPoll <= self.billAfter) return .{ .body = "{}" };
            const one = try std.fmt.allocPrint(gpa, "{{\"name\":\"billingAccounts/{s}\",\"open\":true,\"displayName\":\"My billing\"}}", .{CF.bill});
            if (self.billTwo) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"billingAccounts\":[{s},{{\"name\":\"billingAccounts/ZZZZ-0000-1111\",\"open\":true,\"displayName\":\"Other\"}}]}}", .{one}) };
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"billingAccounts\":[{s}]}}", .{one}) };
        }
        if (after(path, "v1/projects/")) |rest| if (std.mem.endsWith(u8, rest, "/billingInfo")) {
            const pro = self.projOf(rest[0 .. rest.len - "/billingInfo".len]) orelse return errj(gpa, 403, "no permission");
            if (meth == .GET) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"projects/{s}/billingInfo\",\"projectId\":\"{s}\",\"billingAccountName\":\"{s}\",\"billingEnabled\":{s}}}", .{ pro.iden, pro.iden, if (pro.bill) "billingAccounts/" ++ CF.bill else "", if (pro.bill) "true" else "false" }) };
            if (meth == .PUT) {
                const nm = if (json == .object) (json.object.get("billingAccountName") orelse .null) else .null;
                if (nm != .string or !std.mem.eql(u8, nm.string, "billingAccounts/" ++ CF.bill)) return errj(gpa, 400, "unknown billing account");
                pro.bill = true;
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"projectId\":\"{s}\",\"billingAccountName\":\"{s}\",\"billingEnabled\":true}}", .{ pro.iden, nm.string }) };
            }
        };
        return errj(gpa, 404, "no such bill route");
    }

    // the quota header must name a real project
    fn quotChec(self: *Mock, gpa: std.mem.Allocator, quot: []const u8) !?Answ {
        if (self.projOf(quot) == null) return try errj(gpa, 400, "missing or wrong x-goog-user-project");
        return null;
    }

    // Billing Budgets v1
    fn routBudg(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quot: []const u8, json: std.json.Value) !Answ {
        if (try self.quotChec(gpa, quot)) |bad| return bad;
        if (!self.apiOn(quot, "billingbudgets.googleapis.com")) return errj(gpa, 403, "Billing Budgets API has not been used in this project");
        const pref = "v1/billingAccounts/" ++ CF.bill ++ "/budgets";
        if (!std.mem.eql(u8, path, pref)) return errj(gpa, 404, "no such budget route");
        if (meth == .GET) {
            var outp: std.ArrayList(u8) = .empty;
            try outp.appendSlice(gpa, "{\"budgets\":[");
            for (self.budgs.items, 0..) |item, indx| {
                if (indx > 0) try outp.append(gpa, ',');
                try outp.print(gpa, "{{\"displayName\":\"{s}\"}}", .{item.name});
            }
            try outp.appendSlice(gpa, "]}");
            return .{ .body = outp.items };
        }
        if (meth != .POST or json != .object) return errj(gpa, 400, "bad budget request");
        const name = json.object.get("displayName") orelse return errj(gpa, 400, "displayName missing");
        const filt = json.object.get("budgetFilter") orelse return errj(gpa, 400, "budgetFilter missing");
        const amnt = json.object.get("amount") orelse return errj(gpa, 400, "amount missing");
        const rule = json.object.get("thresholdRules") orelse return errj(gpa, 400, "thresholdRules missing");
        if (name != .string or filt != .object or amnt != .object or rule != .array or rule.array.items.len == 0) return errj(gpa, 400, "bad budget fields");
        const projs = filt.object.get("projects") orelse return errj(gpa, 400, "budgetFilter.projects missing");
        const spec = amnt.object.get("specifiedAmount") orelse return errj(gpa, 400, "specifiedAmount missing");
        if (projs != .array or projs.array.items.len != 1 or projs.array.items[0] != .string or spec != .object) return errj(gpa, 400, "bad filter or amount");
        const units = spec.object.get("units") orelse return errj(gpa, 400, "units missing");
        if (units != .string) return errj(gpa, 400, "units must be a string");
        for (rule.array.items) |item| {
            const pct = if (item == .object) (item.object.get("thresholdPercent") orelse .null) else .null;
            const val: f64 = switch (pct) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => return errj(gpa, 400, "thresholdPercent missing"),
            };
            if (!(val > 0 and val <= 10)) return errj(gpa, 400, "thresholdPercent out of range");
        }
        const pro = self.projOf(quot).?;
        if (!std.mem.eql(u8, projs.array.items[0].string, try std.fmt.allocPrint(gpa, "projects/{d}", .{pro.numb}))) return errj(gpa, 400, "budget filter names another project");
        try self.budgs.append(gpa, .{ .name = try gpa.dupe(u8, name.string), .numb = try gpa.dupe(u8, projs.array.items[0].string), .units = try gpa.dupe(u8, units.string), .rules = rule.array.items.len });
        return .{ .body = "{\"name\":\"billingAccounts/x/budgets/1\"}" };
    }

    // Service Usage v1
    fn routUsag(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, json: std.json.Value) !Answ {
        if (after(path, "v1/operations/")) |name| return self.opGet(gpa, try std.fmt.allocPrint(gpa, "operations/{s}", .{name}));
        const rest = after(path, "v1/projects/") orelse return errj(gpa, 404, "no such usage route");
        if (std.mem.endsWith(u8, rest, "/services") and meth == .GET) {
            const pro = self.projOf(rest[0 .. rest.len - "/services".len]) orelse return errj(gpa, 403, "no permission");
            var outp: std.ArrayList(u8) = .empty;
            try outp.appendSlice(gpa, "{\"services\":[");
            for (pro.apis.items, 0..) |item, indx| {
                if (indx > 0) try outp.append(gpa, ',');
                try outp.print(gpa, "{{\"name\":\"projects/{d}/services/{s}\",\"state\":\"ENABLED\"}}", .{ pro.numb, item });
            }
            try outp.appendSlice(gpa, "]}");
            return .{ .body = outp.items };
        }
        if (std.mem.endsWith(u8, rest, "/services:batchEnable") and meth == .POST) {
            const pro = self.projOf(rest[0 .. rest.len - "/services:batchEnable".len]) orelse return errj(gpa, 403, "no permission");
            if (!pro.bill) return errj(gpa, 403, "Billing must be enabled for this project");
            const ids = if (json == .object) (json.object.get("serviceIds") orelse .null) else .null;
            if (ids != .array or ids.array.items.len == 0 or ids.array.items.len > 20) return errj(gpa, 400, "serviceIds must hold 1..20 names");
            for (ids.array.items) |item| {
                if (item != .string) return errj(gpa, 400, "bad service id");
                if (!self.apiOn(pro.iden, item.string)) try pro.apis.append(gpa, try gpa.dupe(u8, item.string));
            }
            self.nextOp += 1;
            return self.opNew(gpa, try std.fmt.allocPrint(gpa, "operations/acf.{d}", .{self.nextOp}));
        }
        return errj(gpa, 404, "no such usage route");
    }

    // IAM v1: service accounts
    fn routIam(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quot: []const u8, json: std.json.Value) !Answ {
        if (try self.quotChec(gpa, quot)) |bad| return bad;
        if (!self.apiOn(quot, "iam.googleapis.com")) return errj(gpa, 403, "IAM API has not been used in this project");
        const pref = try std.fmt.allocPrint(gpa, "v1/projects/{s}/serviceAccounts", .{quot});
        if (std.mem.eql(u8, path, pref) and meth == .POST) {
            const aid = if (json == .object) (json.object.get("accountId") orelse .null) else .null;
            if (aid != .string or aid.string.len < 6 or aid.string.len > 30) return errj(gpa, 400, "accountId must be 6..30 chars");
            const mail = try std.fmt.allocPrint(gpa, "{s}@{s}.iam.gserviceaccount.com", .{ aid.string, quot });
            for (self.sas.items) |item| if (std.mem.eql(u8, item, mail)) return errj(gpa, 409, "already exists");
            try self.sas.append(gpa, mail);
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"email\":\"{s}\"}}", .{mail}) };
        }
        if (after(path, pref)) |tail| if (tail.len > 1 and tail[0] == '/' and meth == .GET) {
            for (self.sas.items) |item| if (std.mem.eql(u8, item, tail[1..])) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"email\":\"{s}\"}}", .{item}) };
            return errj(gpa, 404, "service account not found");
        };
        return errj(gpa, 404, "no such iam route");
    }

    // Artifact Registry v1
    fn routArti(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, quot: []const u8, json: std.json.Value) !Answ {
        if (try self.quotChec(gpa, quot)) |bad| return bad;
        if (!self.apiOn(quot, "artifactregistry.googleapis.com")) return errj(gpa, 403, "Artifact Registry API has not been used in this project");
        if (std.mem.indexOf(u8, path, "/operations/") != null) return self.opGet(gpa, path["v1/".len..]);
        const pref = try std.fmt.allocPrint(gpa, "v1/projects/{s}/locations/us-central1/repositories", .{quot});
        if (std.mem.eql(u8, path, pref) and meth == .POST) {
            const rid = formGetz(quer, "repositoryId") orelse return errj(gpa, 400, "repositoryId missing");
            if (json != .object) return errj(gpa, 400, "no body");
            const fmtv = json.object.get("format") orelse .null;
            const modv = json.object.get("mode") orelse .null;
            const conf = json.object.get("remoteRepositoryConfig") orelse return errj(gpa, 400, "remoteRepositoryConfig missing");
            if (fmtv != .string or !std.mem.eql(u8, fmtv.string, "DOCKER") or modv != .string or !std.mem.eql(u8, modv.string, "REMOTE_REPOSITORY")) return errj(gpa, 400, "format/mode");
            const uri = (try pathStr(conf, &.{ "dockerRepository", "customRepository", "uri" })) orelse return errj(gpa, 400, "customRepository.uri missing");
            try self.repos.append(gpa, .{ .path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ pref, rid }), .uri = try gpa.dupe(u8, uri) });
            self.nextOp += 1;
            return self.opNew(gpa, try std.fmt.allocPrint(gpa, "projects/{s}/locations/us-central1/operations/{d}", .{ quot, self.nextOp }));
        }
        if (meth == .GET) for (self.repos.items) |item| if (std.mem.eql(u8, item.path, path)) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"format\":\"DOCKER\",\"mode\":\"REMOTE_REPOSITORY\",\"remoteRepositoryConfig\":{{\"dockerRepository\":{{\"customRepository\":{{\"uri\":\"{s}\"}}}}}}}}", .{ item.path, item.uri }) };
        return errj(gpa, 404, "repository not found");
    }

    // nested string by key path
    fn pathStr(val: std.json.Value, keys: []const []const u8) !?[]const u8 {
        var cur = val;
        for (keys) |key| {
            if (cur != .object) return null;
            cur = cur.object.get(key) orelse return null;
        }
        return if (cur == .string) cur.string else null;
    }

    // one form/query field
    fn formGetz(body: []const u8, name: []const u8) ?[]const u8 {
        var iter = std.mem.splitScalar(u8, body, '&');
        while (iter.next()) |part| {
            const eqzz = std.mem.indexOfScalar(u8, part, '=') orelse continue;
            if (std.mem.eql(u8, part[0..eqzz], name)) return part[eqzz + 1 ..];
        }
        return null;
    }

    // service JSON as Cloud Run returns it
    fn svcJson(self: *Mock, gpa: std.mem.Allocator, svc: Svc) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"uri\":\"{s}\",\"ingress\":\"{s}\",\"generation\":\"{d}\",\"template\":{{\"serviceAccount\":\"{s}\",\"timeout\":\"{s}\",\"maxInstanceRequestConcurrency\":{d},\"scaling\":{{\"minInstanceCount\":{d},\"maxInstanceCount\":{d}}},\"containers\":[{{\"image\":\"{s}\",\"resources\":{{\"limits\":{{\"cpu\":\"{s}\",\"memory\":\"{s}\"}},\"cpuIdle\":{s}}}}}]}},\"terminalCondition\":{{\"type\":\"Ready\",\"state\":\"{s}\"}}}}", .{ svc.name, svc.uri, svc.ingr, svc.gens, svc.sacc, svc.time, svc.conc, svc.mini, svc.maxi, svc.image, svc.cpu, svc.mem, if (svc.idle) "true" else "false", if (svc.ready) "CONDITION_SUCCEEDED" else "CONDITION_FAILED" });
    }

    // Cloud Run v2
    fn routRun(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, quot: []const u8, json: std.json.Value) !Answ {
        if (try self.quotChec(gpa, quot)) |bad| return bad;
        if (!self.apiOn(quot, "run.googleapis.com")) return errj(gpa, 403, "Cloud Run Admin API has not been used in this project");
        if (std.mem.indexOf(u8, path, "/operations/") != null) return self.opGet(gpa, path["v2/".len..]);
        const pre = try std.fmt.allocPrint(gpa, "v2/projects/{s}/locations/us-central1/services", .{quot});
        const pro = self.projOf(quot).?;
        if (!pro.bill) return errj(gpa, 403, "Billing must be enabled");
        if (std.mem.eql(u8, path, pre) and meth == .POST) {
            if (self.svc != null) return errj(gpa, 409, "service already exists");
            const sid = formGetz(quer, "serviceId") orelse return errj(gpa, 400, "serviceId missing");
            return self.svcPut(gpa, json, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ pre[3..], sid }), quot);
        }
        if (after(path, pre)) |tail| {
            if (tail.len < 2 or tail[0] != '/') return errj(gpa, 404, "no such run route");
            const rest = tail[1..];
            if (std.mem.endsWith(u8, rest, ":getIamPolicy") and meth == .GET) return polGet(&self.svcPol);
            if (std.mem.endsWith(u8, rest, ":setIamPolicy") and meth == .POST) return self.polSet(gpa, &self.svcPol, json, true);
            const cur = self.svc orelse return errj(gpa, 404, "service not found");
            if (!std.mem.eql(u8, cur.name[std.mem.lastIndexOfScalar(u8, cur.name, '/').? + 1 ..], rest)) return errj(gpa, 404, "service not found");
            if (meth == .GET) return .{ .body = try self.svcJson(gpa, cur) };
            if (meth == .PATCH) return self.svcPut(gpa, json, cur.name, quot);
        }
        return errj(gpa, 404, "no such run route");
    }

    // check and store a service body
    fn svcPut(self: *Mock, gpa: std.mem.Allocator, json: std.json.Value, name: []const u8, quot: []const u8) !Answ {
        if (json != .object) return errj(gpa, 400, "no body");
        const tmpl = json.object.get("template") orelse return errj(gpa, 400, "template missing");
        if (tmpl != .object) return errj(gpa, 400, "template");
        const scal = tmpl.object.get("scaling") orelse return errj(gpa, 400, "template.scaling missing");
        const conts = tmpl.object.get("containers") orelse return errj(gpa, 400, "containers missing");
        if (scal != .object or conts != .array or conts.array.items.len != 1) return errj(gpa, 400, "scaling or containers shape");
        const maxi = intOf(scal.object.get("maxInstanceCount") orelse .null);
        const mini = intOf(scal.object.get("minInstanceCount") orelse .null);
        if (maxi < 1 or maxi > 10 or mini < 0 or mini > maxi) return errj(gpa, 400, "instance counts out of range");
        const cont = conts.array.items[0];
        const image = (try pathStr(cont, &.{"image"})) orelse return errj(gpa, 400, "image missing");
        const cpuz = (try pathStr(cont, &.{ "resources", "limits", "cpu" })) orelse return errj(gpa, 400, "cpu limit missing");
        const memo = (try pathStr(cont, &.{ "resources", "limits", "memory" })) orelse return errj(gpa, 400, "memory limit missing");
        const resv = (cont.object.get("resources") orelse .null);
        const idle = if (resv == .object) (resv.object.get("cpuIdle") orelse .null) else .null;
        if (idle != .bool) return errj(gpa, 400, "cpuIdle missing");
        const sacc = (try pathStr(tmpl, &.{"serviceAccount"})) orelse return errj(gpa, 400, "serviceAccount missing");
        var known = false;
        for (self.sas.items) |item| if (std.mem.eql(u8, item, sacc)) {
            known = true;
        };
        if (!known) return errj(gpa, 400, "service account does not exist");
        const time = (try pathStr(tmpl, &.{"timeout"})) orelse return errj(gpa, 400, "timeout missing");
        const ingr = (try pathStr(json, &.{"ingress"})) orelse return errj(gpa, 400, "ingress missing");
        const gens = if (self.svc) |old| old.gens + 1 else 1;
        self.svc = .{ .name = try gpa.dupe(u8, name), .image = try gpa.dupe(u8, image), .sacc = try gpa.dupe(u8, sacc), .mini = mini, .maxi = maxi, .idle = idle.bool, .cpu = try gpa.dupe(u8, cpuz), .mem = try gpa.dupe(u8, memo), .conc = intOf(tmpl.object.get("maxInstanceRequestConcurrency") orelse .null), .time = try gpa.dupe(u8, time), .ingr = try gpa.dupe(u8, ingr), .uri = try std.fmt.allocPrint(gpa, "http://{s}:{d}/svc/{s}", .{ CF.host, self.port, name[std.mem.lastIndexOfScalar(u8, name, '/').? + 1 ..] }), .ready = !self.svcFail, .gens = gens };
        self.nextOp += 1;
        return self.opNew(gpa, try std.fmt.allocPrint(gpa, "projects/{s}/locations/us-central1/operations/{d}", .{ quot, self.nextOp }));
    }

    fn intOf(val: std.json.Value) i64 {
        return switch (val) {
            .integer => |n| n,
            else => -1,
        };
    }

    // Cloud Monitoring v3
    fn routMoni(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, quer: []const u8, quot: []const u8) !Answ {
        if (try self.quotChec(gpa, quot)) |bad| return bad;
        if (!self.apiOn(quot, "monitoring.googleapis.com")) return errj(gpa, 403, "Monitoring API has not been used in this project");
        if (meth != .GET or !std.mem.endsWith(u8, path, "/timeSeries")) return errj(gpa, 404, "no such monitoring route");
        const filt = formGetz(quer, "filter") orelse return errj(gpa, 400, "filter missing");
        if (formGetz(quer, "interval.startTime") == null or formGetz(quer, "interval.endTime") == null) return errj(gpa, 400, "interval missing");
        if (std.mem.indexOf(u8, filt, "request_count") != null) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"timeSeries\":[{{\"points\":[{{\"value\":{{\"int64Value\":\"{d}\"}}}}]}}]}}", .{self.useReqs}) };
        if (std.mem.indexOf(u8, filt, "cpu") != null) return .{ .body = try std.fmt.allocPrint(gpa, "{{\"timeSeries\":[{{\"points\":[{{\"value\":{{\"doubleValue\":{d}}}}}]}}]}}", .{self.useCpuz}) };
        return .{ .body = try std.fmt.allocPrint(gpa, "{{\"timeSeries\":[{{\"points\":[{{\"value\":{{\"doubleValue\":{d}}}}}]}}]}}", .{self.useMemo}) };
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
