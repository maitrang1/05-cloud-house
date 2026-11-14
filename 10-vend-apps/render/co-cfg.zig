// =====================================================================
// Des: Reads the settings file and checks it. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json
// Out: Conf struct, or an error with line and column
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .kindWant = "web_service", .planFree = "free", .tmplMaxz = 32, .dayMaxz = 31 };

// one env var the service gets; the value comes from the vault key `vaul`
pub const Envz = struct { name: []const u8, vaul: []const u8, need: bool };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, wire: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24, keyz: []const u8 },
    rend: struct { apiz: []const u8, sign: []const u8, keyp: []const u8, keyf: []const u8, owne: []const u8, name: []const u8, kind: []const u8, imag: []const u8, plan: []const u8, regi: []const u8, heal: []const u8, inst: u32 },
    envs: []const Envz,
    guar: struct { paid: bool, capz: u32 },
    wire: struct { slot: []const u8, laye: []const u8 },
    cold: struct { wait: u32, poll: u32, wind: u32 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    limi: struct { hour: u32, warn: u32, day: u32 },
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
    const paid = !std.mem.eql(u8, conf.rend.plan, CF.planFree);
    const fail: ?[]const u8 = if (conf.vers != CF.versWant) "vers must be 1" else if (!std.mem.eql(u8, conf.rend.kind, CF.kindWant)) "rend.kind must be web_service" else if (conf.rend.heal.len == 0 or conf.rend.heal[0] != '/') "rend.heal must start with /" else if (conf.rend.name.len == 0) "rend.name must not be empty" else if (conf.rend.inst == 0) "rend.inst must be above 0" else if (!paid and conf.rend.inst != 1) "free plan runs exactly one instance: rend.inst must be 1" else if (paid and (!conf.guar.paid or conf.guar.capz == 0)) "paid plan needs guar.paid true and guar.capz above 0" else if (conf.guid.poll == 0 or conf.cold.poll == 0) "guid.poll and cold.poll must be above 0" else if (conf.http.trys == 0) "http.trys must be above 0" else if (conf.limi.day == 0 or conf.limi.day > CF.dayMaxz) "limi.day must be 1..31" else if (conf.limi.warn == 0 or conf.limi.warn > 100) "limi.warn must be 1..100" else null;
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
    try std.testing.expectEqualStrings("free", conf.rend.plan);
    try std.testing.expect(!conf.guar.paid);
    try std.testing.expectEqualStrings("/healthz", conf.rend.heal);
}

test "unknown key refused with a position" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    try std.testing.expectError(error.ConfJson, confPars(aren.allocator(), "{\n  \"vers\": 1,\n  \"oops\": 2\n}", &diag));
    try std.testing.expectEqual(@as(u64, 3), diag.line);
}

test "free plan refuses more than one instance" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = Diag{};
    const good = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "00-config.json", gpa, .limited(CF.fileMaxz));
    const two = try std.mem.replaceOwned(u8, gpa, good, "\"inst\": 1", "\"inst\": 2");
    try std.testing.expectError(error.ConfValu, confPars(gpa, two, &diag));
}

test "paid plan refused without the opt-in and a cap" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = Diag{};
    const good = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "00-config.json", gpa, .limited(CF.fileMaxz));
    const paid = try std.mem.replaceOwned(u8, gpa, good, "\"plan\": \"free\"", "\"plan\": \"starter\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, paid, &diag));
    try std.testing.expectEqualStrings("paid plan needs guar.paid true and guar.capz above 0", diag.mess);
    const okay = try std.mem.replaceOwned(u8, gpa, paid, "\"guar\": { \"paid\": false, \"capz\": 0 }", "\"guar\": { \"paid\": true, \"capz\": 10 }");
    _ = try confPars(gpa, okay, &diag);
    const bad = try std.mem.replaceOwned(u8, gpa, good, "\"heal\": \"/healthz\"", "\"heal\": \"healthz\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, bad, &diag));
}

test "home fill" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const text = try homeFill(aren.allocator(), "/h", "{home}/.05-cloud-house-secre");
    try std.testing.expectEqualStrings("/h/.05-cloud-house-secre", text);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
