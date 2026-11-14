// =====================================================================
// Des: The cron-job.org REST client. One call counts against the free daily request limit before it goes out. Builds the job body from settings, finds a job by title, compares a job with the settings, reads the history. It has no delete call on purpose.
// Flo: check key + daily count > call (bearer key, JSON) > charge the count > parse reply; job: want > JSON > drift groups > patch body
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: base url, API key, method, path, optional body
// Out: Reply (code, parsed JSON, raw text); job ids, drift groups, newest history item
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("co-http.zig");
const stat = @import("co-state.zig");
const date = @import("co-date.zig");

const CF = .{ .msecSecs = 1000, .rawShow = 200, .keyDay = "day", .keyCnt = "dcnt", .pathJobs = "/jobs", .pathHist = "/history", .emptyBody = "{}", .keyJobs = "jobs", .keyDeta = "jobDetails", .keyHist = "history", .keyPred = "predictions", .statOkay = 1 };

pub const Erro = error{ QuotaDay, NoKey, BadReply };

// one parsed answer
pub const Reply = struct {
    code: u16,
    val: std.json.Value,
    raw: []const u8,

    pub fn okay(self: Reply) bool {
        return self.code >= 200 and self.code < 300;
    }

    // the vendor's error text (string or object.message), else the start of the raw body
    pub fn errText(self: Reply) []const u8 {
        if (self.val == .object) if (self.val.object.get("error")) |errv| {
            if (errv == .string) return errv.string;
            if (errv == .object) if (errv.object.get("message")) |msg| if (msg == .string) return msg.string;
        };
        return if (self.raw.len > CF.rawShow) self.raw[0..CF.rawShow] else self.raw;
    }
};

// object member or .null
pub fn obj(val: std.json.Value, key: []const u8) std.json.Value {
    if (val != .object) return .null;
    return val.object.get(key) orelse .null;
}

// string value or ""
pub fn str(val: std.json.Value) []const u8 {
    return if (val == .string) val.string else "";
}

// integer value (also numbers and numeric strings), else 0
pub fn int(val: std.json.Value) i64 {
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(@trunc(f)),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

// one header of the tick request; secr = the value is the tick secret (never compared with the reply)
pub const Head = struct { name: []const u8, valu: []const u8, secr: bool = false };

// what the job must look like, built from settings
pub const Want = struct {
    url: []const u8,
    title: []const u8,
    enabled: bool,
    save: bool,
    tmoz: u32,
    redi: bool,
    meth: u32,
    tzon: []const u8,
    mins: []const i32,
    hour: []const i32,
    mday: []const i32,
    mont: []const i32,
    wday: []const i32,
    nfail: bool,
    nfcnt: u32,
    nsucc: bool,
    ndisa: bool,
    nmode: u32,
    heads: []const Head,
    body: []const u8,
};

// the parts of a job that are compared and patched as a unit
pub const Group = enum { url, enabled, title, save, timeout, redirect, method, schedule, notification, extended };

pub const all_groups = [_]Group{ .url, .enabled, .title, .save, .timeout, .redirect, .method, .schedule, .notification, .extended };

fn has(only: ?[]const Group, grup: Group) bool {
    const list = only orelse return true;
    for (list) |item| if (item == grup) return true;
    return false;
}

// {"job":{...}} with every group, or only the listed ones (a patch)
pub fn jobJson(gpa: std.mem.Allocator, want: Want, only: ?[]const Group) ![]u8 {
    var aloc: std.Io.Writer.Allocating = .init(gpa);
    var js: std.json.Stringify = .{ .writer = &aloc.writer };
    try js.beginObject();
    try js.objectField("job");
    try js.beginObject();
    if (has(only, .url)) {
        try js.objectField("url");
        try js.write(want.url);
    }
    if (has(only, .enabled)) {
        try js.objectField("enabled");
        try js.write(want.enabled);
    }
    if (has(only, .title)) {
        try js.objectField("title");
        try js.write(want.title);
    }
    if (has(only, .save)) {
        try js.objectField("saveResponses");
        try js.write(want.save);
    }
    if (has(only, .timeout)) {
        try js.objectField("requestTimeout");
        try js.write(want.tmoz);
    }
    if (has(only, .redirect)) {
        try js.objectField("redirectSuccess");
        try js.write(want.redi);
    }
    if (has(only, .method)) {
        try js.objectField("requestMethod");
        try js.write(want.meth);
    }
    if (has(only, .schedule)) {
        try js.objectField("schedule");
        try js.beginObject();
        try js.objectField("timezone");
        try js.write(want.tzon);
        try js.objectField("expiresAt");
        try js.write(@as(u32, 0));
        try js.objectField("hours");
        try js.write(want.hour);
        try js.objectField("mdays");
        try js.write(want.mday);
        try js.objectField("minutes");
        try js.write(want.mins);
        try js.objectField("months");
        try js.write(want.mont);
        try js.objectField("wdays");
        try js.write(want.wday);
        try js.endObject();
    }
    if (has(only, .notification)) {
        try js.objectField("notification");
        try js.beginObject();
        try js.objectField("onFailure");
        try js.write(want.nfail);
        try js.objectField("onFailureCount");
        try js.write(want.nfcnt);
        try js.objectField("onSuccess");
        try js.write(want.nsucc);
        try js.objectField("onDisable");
        try js.write(want.ndisa);
        try js.objectField("mode");
        try js.write(want.nmode);
        try js.endObject();
    }
    if (has(only, .extended)) {
        try js.objectField("extendedData");
        try js.beginObject();
        try js.objectField("headers");
        try js.beginObject();
        for (want.heads) |item| {
            try js.objectField(item.name);
            try js.write(item.valu);
        }
        try js.endObject();
        try js.objectField("body");
        try js.write(want.body);
        try js.endObject();
    }
    try js.endObject();
    try js.endObject();
    return aloc.toOwnedSlice();
}

// true when val is a string that differs from want (absent or other type = cannot compare = no drift)
fn strDiff(val: std.json.Value, want: []const u8) bool {
    return val == .string and !std.mem.eql(u8, val.string, want);
}

fn intDiff(val: std.json.Value, want: i64) bool {
    return (val == .integer or val == .float) and int(val) != want;
}

fn boolDiff(val: std.json.Value, want: bool) bool {
    return val == .bool and val.bool != want;
}

// true when val is an array that differs from want
fn listDiff(val: std.json.Value, want: []const i32) bool {
    if (val != .array) return false;
    if (val.array.items.len != want.len) return true;
    for (val.array.items, want) |item, wnt| if (int(item) != wnt) return true;
    return false;
}

// headers differ: missing wanted header, wrong plain value, or an extra header we do not own
fn headDiff(val: std.json.Value, want: []const Head) bool {
    if (val != .object) return false;
    for (want) |item| {
        var found = false;
        var iter = val.object.iterator();
        while (iter.next()) |entr| {
            if (!std.ascii.eqlIgnoreCase(entr.key_ptr.*, item.name)) continue;
            found = true;
            if (!item.secr and strDiff(entr.value_ptr.*, item.valu)) return true;
        }
        if (!found) return true;
    }
    if (val.object.count() != want.len) return true;
    return false;
}

// the groups of a job (reply object) that differ from want; secr_same = the tick secret is unchanged since the last write
pub fn drift(gpa: std.mem.Allocator, want: Want, det: std.json.Value, secr_same: bool) ![]Group {
    var outp: std.ArrayList(Group) = .empty;
    if (strDiff(obj(det, "url"), want.url)) try outp.append(gpa, .url);
    if (boolDiff(obj(det, "enabled"), want.enabled)) try outp.append(gpa, .enabled);
    if (strDiff(obj(det, "title"), want.title)) try outp.append(gpa, .title);
    if (boolDiff(obj(det, "saveResponses"), want.save)) try outp.append(gpa, .save);
    if (intDiff(obj(det, "requestTimeout"), want.tmoz)) try outp.append(gpa, .timeout);
    if (boolDiff(obj(det, "redirectSuccess"), want.redi)) try outp.append(gpa, .redirect);
    if (intDiff(obj(det, "requestMethod"), want.meth)) try outp.append(gpa, .method);
    const sch = obj(det, "schedule");
    if (strDiff(obj(sch, "timezone"), want.tzon) or listDiff(obj(sch, "hours"), want.hour) or listDiff(obj(sch, "mdays"), want.mday) or listDiff(obj(sch, "minutes"), want.mins) or listDiff(obj(sch, "months"), want.mont) or listDiff(obj(sch, "wdays"), want.wday)) try outp.append(gpa, .schedule);
    const nti = obj(det, "notification");
    if (boolDiff(obj(nti, "onFailure"), want.nfail) or intDiff(obj(nti, "onFailureCount"), want.nfcnt) or boolDiff(obj(nti, "onSuccess"), want.nsucc) or boolDiff(obj(nti, "onDisable"), want.ndisa) or intDiff(obj(nti, "mode"), want.nmode)) try outp.append(gpa, .notification);
    const ext = obj(det, "extendedData");
    if (!secr_same or headDiff(obj(ext, "headers"), want.heads) or strDiff(obj(ext, "body"), want.body)) try outp.append(gpa, .extended);
    return outp.toOwnedSlice(gpa);
}

// the job object of a "jobDetails" reply (the docs show an object and an array; both work)
pub fn detail(rep: Reply) std.json.Value {
    const det = obj(rep.val, CF.keyDeta);
    if (det == .array) return if (det.array.items.len > 0) det.array.items[0] else .null;
    return det;
}

pub const Found = struct { coun: u32 = 0, iden: []const u8 = "" };

// jobs in a list reply whose title equals the wanted one
pub fn titleFind(gpa: std.mem.Allocator, rep: Reply, title: []const u8) !Found {
    var out: Found = .{};
    const jobs = obj(rep.val, CF.keyJobs);
    if (jobs != .array) return out;
    for (jobs.array.items) |item| if (std.mem.eql(u8, str(obj(item, "title")), title)) {
        out.coun += 1;
        if (out.coun == 1) out.iden = try std.fmt.allocPrint(gpa, "{d}", .{int(obj(item, "jobId"))});
    };
    return out;
}

pub const Last = struct { seen: bool = false, date: i64 = 0, stat: i64 = 0, code: i64 = 0, text: []const u8 = "" };

// the newest history item and the next predicted run (0 = none)
pub fn historyLast(rep: Reply) struct { last: Last, next: i64 } {
    var out: Last = .{};
    const hist = obj(rep.val, CF.keyHist);
    if (hist == .array) for (hist.array.items) |item| {
        const when = int(obj(item, "date"));
        if (!out.seen or when > out.date) out = .{ .seen = true, .date = when, .stat = int(obj(item, "status")), .code = int(obj(item, "httpStatus")), .text = str(obj(item, "statusText")) };
    };
    const pred = obj(rep.val, CF.keyPred);
    const next: i64 = if (pred == .array and pred.array.items.len > 0) int(pred.array.items[0]) else 0;
    return .{ .last = out, .next = next };
}

pub const status_okay: i64 = CF.statOkay;

pub const Cron = struct {
    a: std.mem.Allocator,
    io: std.Io,
    http: *http.Http,
    st: *stat.State,
    base: []const u8,
    dayl: u32,
    key: []const u8 = "",
    calls: u32 = 0,

    // the UTC day as text
    fn today(self: *const Cron) ![]u8 {
        const secs = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), CF.msecSecs);
        return self.a.dupe(u8, &date.datePlus(secs, 0));
    }

    // requests counted for today
    pub fn used(self: *const Cron) u32 {
        const day = self.today() catch return 0;
        if (!std.mem.eql(u8, self.st.valu(CF.keyDay), day)) return 0;
        return std.fmt.parseInt(u32, self.st.valu(CF.keyCnt), 10) catch 0;
    }

    // add n requests to today's count and save
    fn charge(self: *Cron, coun: u32) void {
        const day = self.today() catch return;
        const sum = self.used() + coun;
        const text = std.fmt.allocPrint(self.a, "{d}", .{sum}) catch return;
        self.st.putz(CF.keyDay, day) catch return;
        self.st.putz(CF.keyCnt, text) catch return;
        self.st.save(self.io) catch {};
    }

    // one call; refuses before sending when the day is used up
    pub fn call(self: *Cron, meth: std.http.Method, path: []const u8, body: ?[]const u8) !Reply {
        if (self.key.len == 0) return error.NoKey;
        if (self.used() >= self.dayl) return error.QuotaDay;
        const urlz = try std.mem.concat(self.a, u8, &.{ self.base, path });
        const sent: ?[]const u8 = if (meth.requestHasBody()) (body orelse CF.emptyBody) else null;
        const before = self.http.coun;
        const resp = self.http.call(.{ .meth = meth, .urlz = urlz, .bear = self.key, .body = sent }) catch |erro| {
            self.charge(self.http.coun - before);
            return erro;
        };
        self.charge(self.http.coun - before);
        self.calls += 1;
        const val: std.json.Value = if (resp.body.len == 0) .null else std.json.parseFromSliceLeaky(std.json.Value, self.a, resp.body, .{ .allocate = .alloc_always }) catch .null;
        return .{ .code = resp.code, .val = val, .raw = resp.body };
    }

    pub fn list(self: *Cron) !Reply {
        return self.call(.GET, CF.pathJobs, null);
    }

    pub fn get(self: *Cron, iden: []const u8) !Reply {
        return self.call(.GET, try std.mem.concat(self.a, u8, &.{ CF.pathJobs, "/", iden }), null);
    }

    // create: returns the new job id as text
    pub fn create(self: *Cron, body: []const u8) !struct { rep: Reply, iden: []const u8 } {
        const rep = try self.call(.PUT, CF.pathJobs, body);
        const iden: []const u8 = if (rep.okay() and int(obj(rep.val, "jobId")) != 0) try std.fmt.allocPrint(self.a, "{d}", .{int(obj(rep.val, "jobId"))}) else "";
        return .{ .rep = rep, .iden = iden };
    }

    pub fn patch(self: *Cron, iden: []const u8, body: []const u8) !Reply {
        return self.call(.PATCH, try std.mem.concat(self.a, u8, &.{ CF.pathJobs, "/", iden }), body);
    }

    pub fn history(self: *Cron, iden: []const u8) !Reply {
        return self.call(.GET, try std.mem.concat(self.a, u8, &.{ CF.pathJobs, "/", iden, CF.pathHist }), null);
    }
};

const test_want = Want{ .url = "https://x.test/tick", .title = "t", .enabled = true, .save = false, .tmoz = 25, .redi = false, .meth = 1, .tzon = "UTC", .mins = &.{-1}, .hour = &.{-1}, .mday = &.{-1}, .mont = &.{-1}, .wday = &.{-1}, .nfail = true, .nfcnt = 1, .nsucc = true, .ndisa = true, .nmode = 1, .heads = &.{ .{ .name = "Content-Type", .valu = "application/json" }, .{ .name = "X-Tick-Secret", .valu = "s3cret-value", .secr = true } }, .body = "{}" };

test "job json: full body parses back, patch body holds only its groups" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const full = try jobJson(gpa, test_want, null);
    const val = try std.json.parseFromSliceLeaky(std.json.Value, gpa, full, .{});
    const job = obj(val, "job");
    try std.testing.expectEqualStrings("https://x.test/tick", str(obj(job, "url")));
    try std.testing.expectEqual(@as(i64, 1), int(obj(job, "requestMethod")));
    try std.testing.expectEqual(@as(i64, -1), int(obj(obj(job, "schedule"), "minutes").array.items[0]));
    try std.testing.expectEqualStrings("s3cret-value", str(obj(obj(obj(job, "extendedData"), "headers"), "X-Tick-Secret")));
    const part = try jobJson(gpa, test_want, &.{ .enabled, .schedule });
    const pjob = obj(try std.json.parseFromSliceLeaky(std.json.Value, gpa, part, .{}), "job");
    try std.testing.expectEqual(@as(usize, 2), pjob.object.count());
    try std.testing.expect(obj(pjob, "url") == .null);
}

test "drift: equal job has none, each change names its group, absent fields never drift" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const full = try jobJson(gpa, test_want, null);
    const same = obj(try std.json.parseFromSliceLeaky(std.json.Value, gpa, full, .{}), "job");
    try std.testing.expectEqual(@as(usize, 0), (try drift(gpa, test_want, same, true)).len);
    // the secret changed in the vault since the last write
    const dsec = try drift(gpa, test_want, same, false);
    try std.testing.expectEqual(@as(usize, 1), dsec.len);
    try std.testing.expectEqual(Group.extended, dsec[0]);
    // job disabled by the vendor, timeout changed, extra header added
    var bad = try std.mem.replaceOwned(u8, gpa, full, "\"enabled\":true", "\"enabled\":false");
    bad = try std.mem.replaceOwned(u8, gpa, bad, "\"requestTimeout\":25", "\"requestTimeout\":10");
    bad = try std.mem.replaceOwned(u8, gpa, bad, "\"headers\":{", "\"headers\":{\"X-Evil\":\"1\",");
    const dbad = try drift(gpa, test_want, obj(try std.json.parseFromSliceLeaky(std.json.Value, gpa, bad, .{}), "job"), true);
    try std.testing.expectEqual(@as(usize, 3), dbad.len);
    // nothing to compare in the reply: no drift
    try std.testing.expectEqual(@as(usize, 0), (try drift(gpa, test_want, try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"jobId\":5}", .{}), true)).len);
}

test "title find, history pick, detail shapes" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const lst = Reply{ .code = 200, .raw = "", .val = try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"jobs\":[{\"jobId\":7,\"title\":\"a\"},{\"jobId\":9,\"title\":\"t\"},{\"jobId\":11,\"title\":\"t\"}]}", .{}) };
    const fnd = try titleFind(gpa, lst, "t");
    try std.testing.expectEqual(@as(u32, 2), fnd.coun);
    try std.testing.expectEqualStrings("9", fnd.iden);
    const hst = Reply{ .code = 200, .raw = "", .val = try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"history\":[{\"date\":10,\"status\":4,\"httpStatus\":500},{\"date\":20,\"status\":1,\"httpStatus\":202}],\"predictions\":[99]}", .{}) };
    const lst2 = historyLast(hst);
    try std.testing.expectEqual(@as(i64, 202), lst2.last.code);
    try std.testing.expectEqual(@as(i64, 99), lst2.next);
    const arr = Reply{ .code = 200, .raw = "", .val = try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"jobDetails\":[{\"jobId\":3}]}", .{}) };
    try std.testing.expectEqual(@as(i64, 3), int(obj(detail(arr), "jobId")));
}

test "error text from string and object shapes" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const one = Reply{ .code = 401, .raw = "raw", .val = try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"error\":\"Invalid API key\"}", .{}) };
    try std.testing.expectEqualStrings("Invalid API key", one.errText());
    const two = Reply{ .code = 400, .raw = "raw", .val = try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"error\":{\"message\":\"bad\"}}", .{}) };
    try std.testing.expectEqualStrings("bad", two.errText());
    try std.testing.expect(!one.okay());
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
