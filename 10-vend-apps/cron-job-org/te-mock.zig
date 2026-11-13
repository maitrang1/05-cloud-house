// =====================================================================
// Des: A pretend cron-job.org on a loopback port, for tests and the guide run. Strict like the real API: bearer key, JSON content-type, known fields only, id rules, daily and create limits. It also plays the clock: on a history read it "fires" the job once against a built-in tick target and records the secret header it got.
// Flo: listen on a spare port > thread: accept > read request > route (tick target | jobs | job | history) > answer; knobs and counters for the tests
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests on 127.0.0.1
// Out: JSON answers; counters (seen, bads, deletes, creates, tickRuns), the request log
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file; see te-mock-run.zig)
// =====================================================================
const std = @import("std");

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .keyz = "mock-api-key-0001", .idBase = 4000, .tickHead = "x-tick-secret", .tickPath = "/svc/tick", .predSecs = 60, .methMaxz = 8, .tmoMaxz = 30 };

pub const keyz = CF.keyz;

const Answ = struct { code: u16 = 200, body: []const u8 = "{}", retr: bool = false };
const Hd = struct { name: []const u8, valu: []const u8 };
const Hist = struct { iden: []const u8, date: i64, stat: i64, code: i64, text: []const u8, url: []const u8 };

const Job = struct {
    id: u32,
    enabled: bool = false,
    title: []const u8 = "",
    url: []const u8 = "",
    save: bool = false,
    tmoz: i64 = -1,
    redi: bool = false,
    meth: i64 = 0,
    tzon: []const u8 = "UTC",
    hours: []const i64 = &.{},
    mdays: []const i64 = &.{},
    mins: []const i64 = &.{},
    months: []const i64 = &.{},
    wdays: []const i64 = &.{},
    nfail: bool = false,
    nfcnt: i64 = 1,
    nsucc: bool = false,
    ndisa: bool = false,
    nmode: i64 = 1,
    heads: []const Hd = &.{},
    body: []const u8 = "",
    lastStat: i64 = 0,
    lastExec: i64 = 0,
    lastDur: i64 = 0,
    hist: std.ArrayList(Hist) = .empty,
};

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,

    // knobs
    dayLimi: u32 = 100,
    createMax: u32 = 5,
    lockIp: bool = false,
    hideNoti: bool = false,
    tickCode: u16 = 202,
    autoTick: bool = true,
    tickWant: []const u8 = "",

    // state
    jobs: std.ArrayList(Job) = .empty,
    nextId: u32 = CF.idBase,

    // counters
    authReqs: u32 = 0,
    creates: u32 = 0,
    deletes: u32 = 0,
    seen: u32 = 0,
    bads: u32 = 0,
    tickRuns: u32 = 0,
    tickSecret: []const u8 = "",
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

    // base url of the API, caller frees
    pub fn base(self: *Mock, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://{s}:{d}", .{ CF.host, self.port });
    }

    // the built-in tick target as a url, caller frees
    pub fn tickUrl(self: *Mock, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://{s}:{d}{s}", .{ CF.host, self.port, CF.tickPath });
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

    // test helper: a job somebody else made (same title as ours, or any)
    pub fn jobAdd(self: *Mock, title: []const u8, url: []const u8) !void {
        const gpa = self.aren.allocator();
        self.nextId += 1;
        try self.jobs.append(gpa, .{ .id = self.nextId, .title = try gpa.dupe(u8, title), .url = try gpa.dupe(u8, url), .enabled = true });
    }

    // test helper: the vendor switches a job off (25 failures in a row)
    pub fn jobOff(self: *Mock, indx: usize) void {
        self.jobs.items[indx].enabled = false;
    }

    // test helper: somebody edits a job in the Console
    pub fn jobTmo(self: *Mock, indx: usize, tmoz: i64) void {
        self.jobs.items[indx].tmoz = tmoz;
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
        const path = try gpa.dupe(u8, requ.head.target);
        var auth: []const u8 = "";
        var ctyp: []const u8 = "";
        var secr: []const u8 = "";
        var iter = requ.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, "authorization")) auth = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, "content-type")) ctyp = try gpa.dupe(u8, head.value);
            if (std.ascii.eqlIgnoreCase(head.name, CF.tickHead)) secr = try gpa.dupe(u8, head.value);
        }
        var bbuf: [4096]u8 = undefined;
        const body = if (meth.requestHasBody()) try (try requ.readerExpectContinue(&bbuf)).allocRemaining(gpa, .limited(CF.bodyMaxz)) else "";
        self.seen += 1;
        try self.logz.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ @tagName(meth), path }));
        const answ = self.rout(gpa, meth, path, auth, ctyp, secr, body) catch Answ{ .code = 500, .body = "{\"error\":\"mock crashed\"}" };
        if (answ.code >= 400 and answ.code != 404 and answ.code != 429 and answ.code != 403 and answ.code != 401) self.bads += 1;
        const hdrs = [_]std.http.Header{ .{ .name = "Retry-After", .value = "1" }, .{ .name = "Content-Type", .value = "application/json" } };
        try requ.respond(answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &hdrs else hdrs[1..] });
    }

    // an error body in the vendor's plain shape
    fn errj(gpa: std.mem.Allocator, code: u16, mess: []const u8) !Answ {
        return .{ .code = code, .body = try std.fmt.allocPrint(gpa, "{{\"error\":\"{s}\"}}", .{mess}) };
    }

    // text after a prefix, or null
    fn after(path: []const u8, pref: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, path, pref)) path[pref.len..] else null;
    }

    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, auth: []const u8, ctyp: []const u8, secr: []const u8, body: []const u8) !Answ {
        if (std.mem.eql(u8, path, CF.tickPath)) return self.tickTarget(gpa, secr);
        const want = try std.fmt.allocPrint(gpa, "Bearer {s}", .{CF.keyz});
        if (!std.mem.eql(u8, auth, want)) return errj(gpa, 401, "Invalid API key");
        self.authReqs += 1;
        if (self.authReqs > self.dayLimi) return errj(gpa, 429, "Daily request limit exceeded");
        if (self.lockIp) return errj(gpa, 403, "API key not allowed from this IP");
        if (std.mem.eql(u8, path, "/jobs")) {
            if (meth == .GET) return self.jobList(gpa);
            if (meth == .PUT) return self.jobCreate(gpa, ctyp, body);
            return errj(gpa, 405, "method not allowed");
        }
        const rest = after(path, "/jobs/") orelse return errj(gpa, 404, "not found");
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const idtx = if (slash) |sl| rest[0..sl] else rest;
        const tail = if (slash) |sl| rest[sl..] else "";
        const idnn = std.fmt.parseInt(u32, idtx, 10) catch return errj(gpa, 400, "bad job id");
        const indx = for (self.jobs.items, 0..) |one, ix| {
            if (one.id == idnn) break ix;
        } else return errj(gpa, 404, "job not found");
        if (tail.len == 0) {
            if (meth == .GET) return .{ .body = try jobOut(gpa, self.jobs.items[indx], true, self.hideNoti, true) };
            if (meth == .PATCH) return self.jobPatch(gpa, indx, ctyp, body);
            if (meth == .DELETE) {
                self.deletes += 1;
                return errj(gpa, 405, "delete is not allowed in this mock");
            }
            return errj(gpa, 405, "method not allowed");
        }
        if (std.mem.eql(u8, tail, "/history") and meth == .GET) return self.history(gpa, indx);
        return errj(gpa, 404, "not found");
    }

    // the built-in tick target: needs the secret header; answers tickCode
    fn tickTarget(self: *Mock, gpa: std.mem.Allocator, secr: []const u8) !Answ {
        self.tickRuns += 1;
        self.tickSecret = try gpa.dupe(u8, secr);
        if (secr.len == 0) return .{ .code = 401 };
        if (self.tickWant.len != 0 and !std.mem.eql(u8, self.tickWant, secr)) return .{ .code = 401 };
        return .{ .code = self.tickCode };
    }

    fn jobList(self: *Mock, gpa: std.mem.Allocator) !Answ {
        var aloc: std.Io.Writer.Allocating = .init(gpa);
        try aloc.writer.writeAll("{\"jobs\":[");
        for (self.jobs.items, 0..) |one, indx| {
            if (indx != 0) try aloc.writer.writeAll(",");
            try aloc.writer.writeAll(try jobOut(gpa, one, false, false, false));
        }
        try aloc.writer.writeAll("],\"someFailed\":false}");
        return .{ .body = try aloc.toOwnedSlice() };
    }

    // one job as JSON; list = bare Job, detail = DetailedJob wrapped in jobDetails
    fn jobOut(gpa: std.mem.Allocator, one: Job, detl: bool, hide: bool, wrap: bool) ![]u8 {
        var aloc: std.Io.Writer.Allocating = .init(gpa);
        var js: std.json.Stringify = .{ .writer = &aloc.writer };
        if (wrap) {
            try js.beginObject();
            try js.objectField("jobDetails");
        }
        try js.beginObject();
        try js.objectField("jobId");
        try js.write(one.id);
        try js.objectField("enabled");
        try js.write(one.enabled);
        try js.objectField("title");
        try js.write(one.title);
        try js.objectField("saveResponses");
        try js.write(one.save);
        try js.objectField("url");
        try js.write(one.url);
        try js.objectField("lastStatus");
        try js.write(one.lastStat);
        try js.objectField("lastDuration");
        try js.write(one.lastDur);
        try js.objectField("lastExecution");
        try js.write(one.lastExec);
        try js.objectField("nextExecution");
        try js.write(if (one.enabled) one.lastExec + CF.predSecs else 0);
        try js.objectField("type");
        try js.write(@as(u32, 0));
        try js.objectField("requestTimeout");
        try js.write(one.tmoz);
        try js.objectField("redirectSuccess");
        try js.write(one.redi);
        try js.objectField("folderId");
        try js.write(@as(u32, 0));
        try js.objectField("requestMethod");
        try js.write(one.meth);
        try js.objectField("schedule");
        try js.beginObject();
        try js.objectField("timezone");
        try js.write(one.tzon);
        try js.objectField("expiresAt");
        try js.write(@as(u32, 0));
        try js.objectField("hours");
        try js.write(one.hours);
        try js.objectField("mdays");
        try js.write(one.mdays);
        try js.objectField("minutes");
        try js.write(one.mins);
        try js.objectField("months");
        try js.write(one.months);
        try js.objectField("wdays");
        try js.write(one.wdays);
        try js.endObject();
        if (detl) {
            try js.objectField("auth");
            try js.beginObject();
            try js.objectField("enable");
            try js.write(false);
            try js.endObject();
            if (!hide) {
                try js.objectField("notification");
                try js.beginObject();
                try js.objectField("onFailure");
                try js.write(one.nfail);
                try js.objectField("onFailureCount");
                try js.write(one.nfcnt);
                try js.objectField("onSuccess");
                try js.write(one.nsucc);
                try js.objectField("onDisable");
                try js.write(one.ndisa);
                try js.objectField("mode");
                try js.write(one.nmode);
                try js.endObject();
            }
            try js.objectField("extendedData");
            try js.beginObject();
            try js.objectField("headers");
            try js.beginObject();
            for (one.heads) |hd| {
                try js.objectField(hd.name);
                try js.write(hd.valu);
            }
            try js.endObject();
            try js.objectField("body");
            try js.write(one.body);
            try js.endObject();
        }
        try js.endObject();
        if (wrap) try js.endObject();
        return aloc.toOwnedSlice();
    }

    fn jsonOf(gpa: std.mem.Allocator, ctyp: []const u8, body: []const u8) ?std.json.Value {
        if (std.mem.indexOf(u8, ctyp, "application/json") == null) return null;
        const val = std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return null;
        const job = if (val == .object) val.object.get("job") else null;
        return if (job != null and job.? == .object) job.? else null;
    }

    fn jobCreate(self: *Mock, gpa: std.mem.Allocator, ctyp: []const u8, body: []const u8) !Answ {
        const job = jsonOf(gpa, ctyp, body) orelse return errj(gpa, 400, "no job in the payload (JSON content type needed)");
        if (self.creates >= self.createMax) return errj(gpa, 429, "too many jobs created, try later");
        self.nextId += 1;
        var one: Job = .{ .id = self.nextId };
        if (try applyJob(gpa, &one, job)) |mess| return errj(gpa, 400, mess);
        if (one.url.len == 0) return errj(gpa, 400, "url is mandatory");
        self.creates += 1;
        try self.jobs.append(gpa, one);
        return .{ .body = try std.fmt.allocPrint(gpa, "{{\"jobId\":{d}}}", .{one.id}) };
    }

    fn jobPatch(self: *Mock, gpa: std.mem.Allocator, indx: usize, ctyp: []const u8, body: []const u8) !Answ {
        const job = jsonOf(gpa, ctyp, body) orelse return errj(gpa, 400, "no job in the payload (JSON content type needed)");
        var one = self.jobs.items[indx];
        if (try applyJob(gpa, &one, job)) |mess| return errj(gpa, 400, mess);
        self.jobs.items[indx] = one;
        return .{};
    }

    // read a list of ints from a JSON array
    fn listOf(gpa: std.mem.Allocator, val: std.json.Value, lo: i64, hi: i64) !?[]const i64 {
        if (val != .array or val.array.items.len == 0) return null;
        const outp = try gpa.alloc(i64, val.array.items.len);
        for (val.array.items, 0..) |item, indx| {
            if (item != .integer) return null;
            if (!(item.integer == -1 or (item.integer >= lo and item.integer <= hi))) return null;
            outp[indx] = item.integer;
        }
        if (outp.len > 1) for (outp) |one| if (one == -1) return null;
        return outp;
    }

    // set fields from a job object (create or patch); returns an error text, or null when fine
    fn applyJob(gpa: std.mem.Allocator, one: *Job, job: std.json.Value) !?[]const u8 {
        var iter = job.object.iterator();
        while (iter.next()) |entr| {
            const key = entr.key_ptr.*;
            const val = entr.value_ptr.*;
            if (std.mem.eql(u8, key, "url")) {
                if (val != .string or !std.mem.startsWith(u8, val.string, "http")) return "bad url";
                one.url = try gpa.dupe(u8, val.string);
            } else if (std.mem.eql(u8, key, "enabled")) {
                if (val != .bool) return "enabled must be boolean";
                one.enabled = val.bool;
            } else if (std.mem.eql(u8, key, "title")) {
                if (val != .string) return "title must be a string";
                one.title = try gpa.dupe(u8, val.string);
            } else if (std.mem.eql(u8, key, "saveResponses")) {
                if (val != .bool) return "saveResponses must be boolean";
                one.save = val.bool;
            } else if (std.mem.eql(u8, key, "requestTimeout")) {
                if (val != .integer or val.integer < 1 or val.integer > CF.tmoMaxz) return "requestTimeout must be 1..30";
                one.tmoz = val.integer;
            } else if (std.mem.eql(u8, key, "redirectSuccess")) {
                if (val != .bool) return "redirectSuccess must be boolean";
                one.redi = val.bool;
            } else if (std.mem.eql(u8, key, "requestMethod")) {
                if (val != .integer or val.integer < 0 or val.integer > CF.methMaxz) return "requestMethod must be 0..8";
                one.meth = val.integer;
            } else if (std.mem.eql(u8, key, "schedule")) {
                if (val != .object) return "schedule must be an object";
                var sit = val.object.iterator();
                while (sit.next()) |se| {
                    const sk = se.key_ptr.*;
                    const sv = se.value_ptr.*;
                    if (std.mem.eql(u8, sk, "timezone")) {
                        if (sv != .string) return "timezone must be a string";
                        one.tzon = try gpa.dupe(u8, sv.string);
                    } else if (std.mem.eql(u8, sk, "expiresAt")) {
                        if (sv != .integer) return "expiresAt must be an integer";
                    } else if (std.mem.eql(u8, sk, "hours")) {
                        one.hours = (try listOf(gpa, sv, 0, 23)) orelse return "bad hours";
                    } else if (std.mem.eql(u8, sk, "mdays")) {
                        one.mdays = (try listOf(gpa, sv, 1, 31)) orelse return "bad mdays";
                    } else if (std.mem.eql(u8, sk, "minutes")) {
                        one.mins = (try listOf(gpa, sv, 0, 59)) orelse return "bad minutes";
                    } else if (std.mem.eql(u8, sk, "months")) {
                        one.months = (try listOf(gpa, sv, 1, 12)) orelse return "bad months";
                    } else if (std.mem.eql(u8, sk, "wdays")) {
                        one.wdays = (try listOf(gpa, sv, 0, 6)) orelse return "bad wdays";
                    } else return "unknown schedule field";
                }
            } else if (std.mem.eql(u8, key, "notification")) {
                if (val != .object) return "notification must be an object";
                var nit = val.object.iterator();
                while (nit.next()) |ne| {
                    const nk = ne.key_ptr.*;
                    const nv = ne.value_ptr.*;
                    if (std.mem.eql(u8, nk, "onFailure")) {
                        if (nv != .bool) return "onFailure must be boolean";
                        one.nfail = nv.bool;
                    } else if (std.mem.eql(u8, nk, "onFailureCount")) {
                        if (nv != .integer or nv.integer < 1) return "onFailureCount must be 1 or more";
                        one.nfcnt = nv.integer;
                    } else if (std.mem.eql(u8, nk, "onSuccess")) {
                        if (nv != .bool) return "onSuccess must be boolean";
                        one.nsucc = nv.bool;
                    } else if (std.mem.eql(u8, nk, "onDisable")) {
                        if (nv != .bool) return "onDisable must be boolean";
                        one.ndisa = nv.bool;
                    } else if (std.mem.eql(u8, nk, "mode")) {
                        if (nv != .integer or nv.integer < 0 or nv.integer > 2) return "mode must be 0..2";
                        one.nmode = nv.integer;
                    } else return "unknown notification field";
                }
            } else if (std.mem.eql(u8, key, "extendedData")) {
                if (val != .object) return "extendedData must be an object";
                var eit = val.object.iterator();
                while (eit.next()) |ee| {
                    const ek = ee.key_ptr.*;
                    const ev = ee.value_ptr.*;
                    if (std.mem.eql(u8, ek, "headers")) {
                        if (ev != .object) return "headers must be an object";
                        var hds: std.ArrayList(Hd) = .empty;
                        var hit = ev.object.iterator();
                        while (hit.next()) |he| {
                            if (he.value_ptr.* != .string) return "header values must be strings";
                            try hds.append(gpa, .{ .name = try gpa.dupe(u8, he.key_ptr.*), .valu = try gpa.dupe(u8, he.value_ptr.string) });
                        }
                        one.heads = try hds.toOwnedSlice(gpa);
                    } else if (std.mem.eql(u8, ek, "body")) {
                        if (ev != .string) return "body must be a string";
                        one.body = try gpa.dupe(u8, ev.string);
                    } else return "unknown extendedData field";
                }
            } else return "unknown job field";
        }
        return null;
    }

    // history of a job; with autoTick one run "happens" first
    fn history(self: *Mock, gpa: std.mem.Allocator, indx: usize) !Answ {
        const job = &self.jobs.items[indx];
        const now = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
        if (self.autoTick and job.enabled) {
            var code: i64 = 0;
            if (std.mem.endsWith(u8, job.url, CF.tickPath)) {
                var secr: []const u8 = "";
                for (job.heads) |hd| if (std.ascii.eqlIgnoreCase(hd.name, CF.tickHead)) {
                    secr = hd.valu;
                };
                const ans = try self.tickTarget(gpa, secr);
                code = ans.code;
            }
            const okay = code >= 200 and code < 300;
            job.lastStat = if (okay) 1 else 4;
            job.lastExec = now;
            job.lastDur = 33;
            try job.hist.append(gpa, .{ .iden = try std.fmt.allocPrint(gpa, "run-{d}", .{job.hist.items.len + 1}), .date = now, .stat = job.lastStat, .code = code, .text = if (okay) "OK" else "HTTP error", .url = job.url });
        }
        var aloc: std.Io.Writer.Allocating = .init(gpa);
        var js: std.json.Stringify = .{ .writer = &aloc.writer };
        try js.beginObject();
        try js.objectField("history");
        try js.beginArray();
        for (job.hist.items) |hi| {
            try js.beginObject();
            try js.objectField("jobId");
            try js.write(job.id);
            try js.objectField("identifier");
            try js.write(hi.iden);
            try js.objectField("date");
            try js.write(hi.date);
            try js.objectField("datePlanned");
            try js.write(hi.date);
            try js.objectField("jitter");
            try js.write(@as(u32, 12));
            try js.objectField("url");
            try js.write(hi.url);
            try js.objectField("duration");
            try js.write(@as(u32, 33));
            try js.objectField("status");
            try js.write(hi.stat);
            try js.objectField("statusText");
            try js.write(hi.text);
            try js.objectField("httpStatus");
            try js.write(hi.code);
            try js.objectField("headers");
            try js.write(null);
            try js.objectField("body");
            try js.write(null);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("predictions");
        try js.beginArray();
        if (job.enabled) try js.write(now + CF.predSecs);
        try js.endArray();
        try js.endObject();
        return .{ .body = try aloc.toOwnedSlice() };
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
