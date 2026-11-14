// =====================================================================
// Des: Reads the settings file and checks it. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json
// Out: Conf struct, or an error with line and column
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .periMaxz = 59, .hourMinu = 60, .tokeMinl = 8 };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, wire: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24, keyz: []const u8 },
    cfla: struct { apiz: []const u8, sign: []const u8, keyp: []const u8, minl: u32, acco: []const u8, subd: []const u8, scri: []const u8, rout: []const u8, comp: []const u8 },
    trig: struct { url: []const u8, path: []const u8, meth: []const u8, head: []const u8, secr: []const u8 },
    cron: struct { peri: u32 },
    rout: struct { wait: u32, poll: u32 },
    wire: struct { slot: []const u8, laye: []const u8 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    limi: struct { reqs: u32, warn: u32, trig: u32 },
};

// where a parse error sits in the file
pub const Diag = struct { line: u64 = 0, colu: u64 = 0, mess: []const u8 = "" };

pub const Erro = error{ ConfRead, ConfJson, ConfValu };

// parse strict JSON text into Conf (arena allocator expected)
pub fn confPars(gpa: std.mem.Allocator, text: []const u8, diag: *Diag) Erro!Conf {
    var scan = std.json.Scanner.initCompleteInput(gpa, text);
    var jdia = std.json.Diagnostics{};
    scan.enableDiagnostics(&jdia);
    const conf = std.json.parseFromTokenSourceLeaky(Conf, gpa, &scan, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |erro| {
        diag.* = .{ .line = jdia.getLine(), .colu = jdia.getColumn(), .mess = @errorName(erro) };
        return error.ConfJson;
    };
    try confChec(conf, diag);
    return conf;
}

// value rules that types cannot express
fn confChec(conf: Conf, diag: *Diag) Erro!void {
    const fail: ?[]const u8 = if (conf.vers != CF.versWant) "vers must be 1" else if (conf.cfla.scri.len == 0) "cfla.scri must not be empty" else if (conf.cfla.minl < CF.tokeMinl) "cfla.minl must be 8 or more" else if (std.mem.indexOf(u8, conf.cfla.rout, "{scri}") == null) "cfla.rout must contain {scri}" else if (conf.cron.peri == 0 or conf.cron.peri > CF.periMaxz or CF.hourMinu % conf.cron.peri != 0) "cron.peri must divide 60 (1,2,3,4,5,6,10,12,15,20,30)" else if (conf.trig.path.len == 0 or conf.trig.path[0] != '/') "trig.path must start with /" else if (conf.trig.meth.len == 0 or conf.trig.head.len == 0) "trig.meth and trig.head must not be empty" else if (conf.guid.poll == 0 or conf.rout.poll == 0) "guid.poll and rout.poll must be above 0" else if (conf.http.trys == 0) "http.trys must be above 0" else if (conf.limi.reqs == 0 or conf.limi.trig == 0) "limi.reqs and limi.trig must be above 0" else if (conf.limi.warn == 0 or conf.limi.warn > 100) "limi.warn must be 1..100" else null;
    if (fail) |mess| {
        diag.* = .{ .mess = mess };
        return error.ConfValu;
    }
}

// read + parse the settings file
pub fn confLoad(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diag) Erro!Conf {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| {
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfRead;
    };
    return confPars(gpa, text, diag);
}

// replace a leading "{home}" with the real home folder
pub fn homeFill(gpa: std.mem.Allocator, home: []const u8, path: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, path, "{home}", home);
}

// the shipped config must load: guards the real file against typos
test "shipped config parses" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    const conf = confLoad(aren.allocator(), std.testing.io, "00-config.json", &diag) catch |erro| {
        std.debug.print("config: {s} line {d} col {d}\n", .{ diag.mess, diag.line, diag.colu });
        return erro;
    };
    try std.testing.expectEqualStrings("cloud-house-tick", conf.cfla.scri);
    try std.testing.expectEqual(@as(u32, 5), conf.cron.peri);
}

test "unknown key refused with a position" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    try std.testing.expectError(error.ConfJson, confPars(aren.allocator(), "{\n  \"vers\": 1,\n  \"oops\": 2\n}", &diag));
    try std.testing.expectEqual(@as(u64, 3), diag.line);
}

test "bad values refused: period, route template, trigger path" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = Diag{};
    const good = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "00-config.json", gpa, .limited(CF.fileMaxz));
    const peri = try std.mem.replaceOwned(u8, gpa, good, "\"peri\": 5", "\"peri\": 0");
    try std.testing.expectError(error.ConfValu, confPars(gpa, peri, &diag));
    try std.testing.expectEqualStrings("cron.peri must divide 60 (1,2,3,4,5,6,10,12,15,20,30)", diag.mess);
    const sevn = try std.mem.replaceOwned(u8, gpa, good, "\"peri\": 5", "\"peri\": 7");
    try std.testing.expectError(error.ConfValu, confPars(gpa, sevn, &diag));
    const rout = try std.mem.replaceOwned(u8, gpa, good, "{scri}.{subd}", "x.{subd}");
    try std.testing.expectError(error.ConfValu, confPars(gpa, rout, &diag));
    const path = try std.mem.replaceOwned(u8, gpa, good, "\"path\": \"/tick\"", "\"path\": \"tick\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, path, &diag));
}

test "home fill" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const text = try homeFill(aren.allocator(), "/h", "{home}/.05-cloud-house-secre");
    try std.testing.expectEqualStrings("/h/.05-cloud-house-secre", text);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
