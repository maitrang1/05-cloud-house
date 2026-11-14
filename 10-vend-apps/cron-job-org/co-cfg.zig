// =====================================================================
// Des: Reads the settings file and the step list and checks them. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings; steps: read file, or fall back to the embedded copy
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json, optional path of the step file
// Out: Conf struct and Steps struct, or an error with line and column
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .pctMaxz = 100, .loopHost = "http://127.0.0.1", .stepEmbd = @embedFile("df-steps.json"), .passMinz = 8, .secaMinz = 16, .secaMaxz = 64, .methMaxz = 8, .noteModeMax = 2, .minuMaxz = 59, .hourMaxz = 23, .mdayMaxz = 31, .montMaxz = 12, .wdayMaxz = 6 };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, hand: []const u8, step: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24, keya: []const u8, keyt: []const u8, prom: []const u8 },
    cron: struct { base: []const u8, keyz_envz: []const u8, prom: []const u8 },
    tick: struct { urlz: []const u8, from: []const u8, fiel: []const u8, head: []const u8, seca: u32 },
    jobz: struct { titl: []const u8, enab: bool, meth: u32, tmoz: u32, save: bool, redi: bool, tzon: []const u8, mins: []const i32, hour: []const i32, mday: []const i32, mont: []const i32, wday: []const i32, body: []const u8, ctyp: []const u8 },
    noti: struct { fail: bool, fcnt: u32, succ: bool, disa: bool, mode: u32 },
    veri: struct { tries: u32, gap: u32, okay: []const u32 },
    guid: struct { open: bool, poll: u32, wait: u32, sign: []const u8, keyp: []const u8 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    limi: struct { dayl: u32, warn: u32, tmax: u32, tryz: u32 },
};

// one row of the step list; redo = run again on every run (cheap checks), never skipped by an old mark
pub const StepRow = struct { numb: u32, iden: []const u8, kind: []const u8, acts: []const u8, hand: u32, redo: bool, name: []const u8, need: []const u8, done: []const u8 };

// the step list contract, v1
pub const Steps = struct { vers: u32, vend: []const u8, step: []const StepRow };

// where a parse error sits in the file
pub const Diag = struct { line: u64 = 0, colu: u64 = 0, mess: []const u8 = "" };

pub const Erro = error{ ConfRead, ConfJson, ConfValu };

// strict JSON text into any contract struct (arena allocator expected)
fn jsonPars(comptime T: type, gpa: std.mem.Allocator, text: []const u8, diag: *Diag) Erro!T {
    var scan = std.json.Scanner.initCompleteInput(gpa, text);
    var jdia = std.json.Diagnostics{};
    scan.enableDiagnostics(&jdia);
    return std.json.parseFromTokenSourceLeaky(T, gpa, &scan, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |erro| {
        diag.* = .{ .line = jdia.getLine(), .colu = jdia.getColumn(), .mess = @errorName(erro) };
        return error.ConfJson;
    };
}

// true when a base is https, or the loopback mock
pub fn baseOkay(base: []const u8) bool {
    return std.mem.startsWith(u8, base, "https://") or std.mem.startsWith(u8, base, CF.loopHost);
}

// true when every value of a schedule list is -1 (any) alone, or inside lo..hi
fn listOkay(list: []const i32, lo: i32, hi: i32) bool {
    if (list.len == 0) return false;
    if (list.len == 1 and list[0] == -1) return true;
    for (list) |item| if (item < lo or item > hi) return false;
    return true;
}

// true when a header name is plain token text
fn headOkay(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return false;
    return true;
}

// value rules that types cannot express
fn confChec(conf: Conf, diag: *Diag) Erro!void {
    const jobz = conf.jobz;
    const fail: ?[]const u8 = if (conf.vers != CF.versWant) "vers must be 1" else if (!baseOkay(conf.cron.base)) "cron.base must be https" else if (conf.tick.urlz.len != 0 and !baseOkay(conf.tick.urlz)) "tick.urlz must be https or empty" else if (!headOkay(conf.tick.head)) "tick.head must be a plain header name" else if (conf.tick.seca < CF.secaMinz or conf.tick.seca > CF.secaMaxz) "tick.seca must be 16..64 bytes" else if (jobz.titl.len == 0) "jobz.titl must be set" else if (jobz.meth > CF.methMaxz) "jobz.meth must be 0..8" else if (jobz.tmoz == 0 or jobz.tmoz > conf.limi.tmax) "jobz.tmoz must be 1..limi.tmax (the vendor cuts calls at 30 s)" else if (!listOkay(jobz.mins, 0, CF.minuMaxz) or !listOkay(jobz.hour, 0, CF.hourMaxz) or !listOkay(jobz.mday, 1, CF.mdayMaxz) or !listOkay(jobz.mont, 1, CF.montMaxz) or !listOkay(jobz.wday, 0, CF.wdayMaxz)) "jobz.mins/hour/mday/mont/wday must be [-1] or values in range" else if (conf.noti.fcnt == 0) "noti.fcnt must be 1 or more" else if (conf.noti.mode > CF.noteModeMax) "noti.mode must be 0..2" else if (conf.veri.tries == 0 or conf.veri.tries > conf.limi.tryz) "veri.tries must be 1..limi.tryz (each try costs a request of the daily quota)" else if (conf.veri.okay.len == 0) "veri.okay must list a status" else if (conf.guid.poll == 0) "guid.poll must be above 0" else if (conf.http.trys == 0) "http.trys must be above 0" else if (conf.limi.dayl == 0) "limi.dayl must be above 0" else if (conf.limi.warn == 0 or conf.limi.warn > CF.pctMaxz) "limi.warn must be 1..100" else if (conf.vaul.keya.len == 0 or conf.vaul.keyt.len == 0 or std.mem.eql(u8, conf.vaul.keya, conf.vaul.keyt)) "vaul.keya and vaul.keyt must be set and different" else if (conf.vaul.time == 0 or conf.vaul.memo == 0 or conf.vaul.para == 0) "vaul.time, memo, para must be above 0" else null;
    if (fail) |mess| {
        diag.* = .{ .mess = mess };
        return error.ConfValu;
    }
}

// parse strict JSON text into Conf
pub fn confPars(gpa: std.mem.Allocator, text: []const u8, diag: *Diag) Erro!Conf {
    const conf = try jsonPars(Conf, gpa, text, diag);
    try confChec(conf, diag);
    return conf;
}

// read + parse the settings file
pub fn confLoad(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diag) Erro!Conf {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| {
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfRead;
    };
    return confPars(gpa, text, diag);
}

// the step list: a file at path wins, else the embedded copy
pub fn stepLoad(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diag) Erro!Steps {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch CF.stepEmbd;
    const steps = try jsonPars(Steps, gpa, text, diag);
    if (steps.vers != CF.versWant or steps.step.len == 0) {
        diag.* = .{ .mess = "steps: vers must be 1 and the list must not be empty" };
        return error.ConfValu;
    }
    for (steps.step, 0..) |row, indx| {
        const kind_ok = std.mem.eql(u8, row.kind, "auto") or std.mem.eql(u8, row.kind, "guide") or std.mem.eql(u8, row.kind, "ask");
        if (!kind_ok or row.iden.len == 0 or row.acts.len == 0 or row.numb != indx) {
            diag.* = .{ .mess = "steps: bad kind, empty id, or numbers not 0,1,2,..." };
            return error.ConfValu;
        }
    }
    return steps;
}

// minimum passphrase length (the vault refuses shorter ones)
pub fn passMin() usize {
    return CF.passMinz;
}

// the shipped config must load: guards the real file against typos
test "shipped config and steps parse" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    const conf = confLoad(aren.allocator(), std.testing.io, "00-config.json", &diag) catch |erro| {
        std.debug.print("config: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return erro;
    };
    try std.testing.expectEqual(@as(u32, 100), conf.limi.dayl);
    try std.testing.expectEqual(@as(usize, 1), conf.jobz.mins.len);
    const steps = try stepLoad(aren.allocator(), std.testing.io, "no-such-steps.json", &diag);
    try std.testing.expectEqual(@as(usize, 7), steps.step.len);
    var hand: u32 = 0;
    for (steps.step) |row| hand += row.hand;
    try std.testing.expectEqual(@as(u32, 3), hand); // hand ids 0,1,2 = two hand jobs
}

test "unknown key refused with a position" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    try std.testing.expectError(error.ConfJson, confPars(aren.allocator(), "{\n  \"vers\": 1,\n  \"oops\": 2\n}", &diag));
    try std.testing.expectEqual(@as(u64, 3), diag.line);
}

test "unsafe values refused" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = Diag{};
    const good = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "00-config.json", gpa, .limited(CF.fileMaxz));
    const case = [_][2][]const u8{
        .{ "https://api.cron-job.org", "http://api.cron-job.org" },
        .{ "\"tmoz\": 25", "\"tmoz\": 31" },
        .{ "\"tmoz\": 25", "\"tmoz\": 0" },
        .{ "\"mins\": [-1]", "\"mins\": [60]" },
        .{ "\"mins\": [-1]", "\"mins\": []" },
        .{ "\"mday\": [-1]", "\"mday\": [0]" },
        .{ "\"head\": \"X-Tick-Secret\"", "\"head\": \"X Tick\"" },
        .{ "\"seca\": 32", "\"seca\": 4" },
        .{ "\"warn\": 80", "\"warn\": 0" },
        .{ "\"dayl\": 100", "\"dayl\": 0" },
        .{ "\"tries\": 3", "\"tries\": 9" },
        .{ "\"mode\": 1 }", "\"mode\": 5 }" },
        .{ "\"keyt\": \"cronjoborg.tick\"", "\"keyt\": \"cronjoborg.apikey\"" },
    };
    for (case) |pair| {
        const bad = try std.mem.replaceOwned(u8, gpa, good, pair[0], pair[1]);
        try std.testing.expect(!std.mem.eql(u8, bad, good));
        try std.testing.expectError(error.ConfValu, confPars(gpa, bad, &diag));
    }
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
