// =====================================================================
// Des: Reads the settings file and checks it. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json
// Out: Conf struct, or an error with line and column
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .tmplMaxz = 32, .portMaxz = 65535 };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, acct: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24 },
    repo: struct { path: []const u8, bran: []const u8, remo: []const u8, push: []const u8 },
    rele: struct { base: []const u8, vers: []const u8, arch: []const u8, file: []const u8, sums: []const u8, maxb: u32 },
    host: struct { bina: []const u8, work: []const u8, conf: []const u8, unit: []const u8, svcu: []const u8, pubh: []const u8, port: u32, sshp: u32 },
    ini: []const []const u8,
    unit: []const []const u8,
    cmds: struct { chek: []const []const u8, runa: []const []const u8, mkus: []const []const u8, chmo: []const []const u8, chow: []const []const u8, reld: []const []const u8, enab: []const []const u8 },
    bkup: struct { onzz: bool, svcf: []const u8, tmrf: []const u8, svc: []const []const u8, tmr: []const []const u8, enab: []const []const u8 },
    limi: struct { ramm: u32, diskm: u32, warn: u32 },
    admi: struct { user: []const u8, mail: []const u8 },
    toke: struct { name: []const u8, scop: []const []const u8 },
    frep: struct { name: []const u8, visi: []const u8, sett: std.json.Value },
    prot: std.json.Value,
    sshz: struct { file: []const u8, titl: []const u8 },
    tool: struct { gitz: []const u8, sshk: []const u8, time: u32 },
    boot: struct { poll: u32, wait: u32 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
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
    const fail: ?[]const u8 = if (conf.vers != CF.versWant) "vers must be 1" else if (!std.mem.eql(u8, conf.frep.visi, "private") and !std.mem.eql(u8, conf.frep.visi, "public")) "frep.visi must be private or public" else if (conf.frep.sett != .object) "frep.sett must be an object" else if (conf.prot != .object) "prot must be an object" else if (forcOn(conf.prot)) "prot.enable_force_push must be false" else if (conf.rele.vers.len == 0) "rele.vers must name a release" else if (conf.host.port == 0 or conf.host.port > CF.portMaxz or conf.host.sshp == 0 or conf.host.sshp > CF.portMaxz) "host.port and host.sshp must be 1..65535" else if (conf.host.port == conf.host.sshp) "host.port and host.sshp must differ" else if (conf.toke.scop.len == 0) "toke.scop must list a scope" else if (conf.http.trys == 0) "http.trys must be above 0" else if (conf.boot.poll == 0) "boot.poll must be above 0" else if (conf.guid.poll == 0) "guid.poll must be above 0" else if (!iniRegiOff(conf.ini)) "ini must keep DISABLE_REGISTRATION = true" else if (conf.limi.warn == 0 or conf.limi.warn > 100) "limi.warn must be 1..100" else if (conf.bkup.onzz and (conf.bkup.svc.len == 0 or conf.bkup.tmr.len == 0 or conf.bkup.enab.len == 0)) "bkup svc, tmr and enab must have lines when bkup.onzz" else null;
    if (fail) |mess| {
        diag.* = .{ .mess = mess };
        return error.ConfValu;
    }
}

// true when the protection body turns force push on
fn forcOn(prot: std.json.Value) bool {
    const valu = prot.object.get("enable_force_push") orelse return false;
    return valu == .bool and valu.bool;
}

// true when the app.ini lines keep registration off
fn iniRegiOff(ini: []const []const u8) bool {
    for (ini) |line| if (std.mem.eql(u8, std.mem.trim(u8, line, " "), "DISABLE_REGISTRATION = true")) return true;
    return false;
}

// read + parse the settings file
pub fn confLoad(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diag) Erro!Conf {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| {
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfRead;
    };
    return confPars(gpa, text, diag);
}

// the private account file in the data folder fills admi.user / admi.mail so no personal value sits in the synced config; a missing file changes nothing
pub fn acctOverride(gpa: std.mem.Allocator, io: std.Io, path: []const u8, conf: *Conf, diag: *Diag) Erro!void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| {
        if (erro == error.FileNotFound) return;
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfRead;
    };
    const Acct = struct { user: []const u8 = "", mail: []const u8 = "" };
    const got = std.json.parseFromSliceLeaky(Acct, gpa, text, .{ .ignore_unknown_fields = false }) catch |erro| {
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfJson;
    };
    if (got.user.len > 0) conf.admi.user = got.user;
    if (got.mail.len > 0) conf.admi.mail = got.mail;
}

// one name/value pair for tmplFill
pub const Pair = struct { []const u8, []const u8 };

// replace every {name} in a template
pub fn tmplFill(gpa: std.mem.Allocator, tmpl: []const u8, pair: []const Pair) ![]u8 {
    var text = try gpa.dupe(u8, tmpl);
    for (pair) |item| {
        var keyz: [CF.tmplMaxz]u8 = undefined;
        const mark = try std.fmt.bufPrint(&keyz, "{{{s}}}", .{item[0]});
        text = try std.mem.replaceOwned(u8, gpa, text, mark, item[1]);
    }
    return text;
}

// fill a template argv list
pub fn argvFill(gpa: std.mem.Allocator, argv: []const []const u8, pair: []const Pair) ![]const []const u8 {
    const outp = try gpa.alloc([]const u8, argv.len);
    for (argv, 0..) |item, indx| outp[indx] = try tmplFill(gpa, item, pair);
    return outp;
}

// fill a list of lines and join them with newlines (trailing newline included)
pub fn linzFill(gpa: std.mem.Allocator, lines: []const []const u8, pair: []const Pair) ![]u8 {
    var outp: std.ArrayList(u8) = .empty;
    for (lines) |item| {
        try outp.appendSlice(gpa, try tmplFill(gpa, item, pair));
        try outp.append(gpa, '\n');
    }
    return outp.toOwnedSlice(gpa);
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
    try std.testing.expectEqualStrings("private", conf.frep.visi);
    try std.testing.expect(std.mem.startsWith(u8, conf.repo.path, "{home}/")); // no machine name in the shipped file
    try std.testing.expect(!conf.frep.sett.object.get("has_actions").?.bool);
    try std.testing.expect(!conf.prot.object.get("enable_force_push").?.bool);
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
    const publ = try std.mem.replaceOwned(u8, gpa, good, "\"visi\": \"private\"", "\"visi\": \"open\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, publ, &diag));
    const forc = try std.mem.replaceOwned(u8, gpa, good, "\"enable_force_push\": false", "\"enable_force_push\": true");
    try std.testing.expectError(error.ConfValu, confPars(gpa, forc, &diag));
    const regi = try std.mem.replaceOwned(u8, gpa, good, "DISABLE_REGISTRATION = true", "DISABLE_REGISTRATION = false");
    try std.testing.expectError(error.ConfValu, confPars(gpa, regi, &diag));
    const port = try std.mem.replaceOwned(u8, gpa, good, "\"sshp\": 2222", "\"sshp\": 3000");
    try std.testing.expectError(error.ConfValu, confPars(gpa, port, &diag));
}

test "account file fills admi, a missing file changes nothing, an unknown key is refused; the shipped admin is blank" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const io = std.testing.io;
    var diag = Diag{};
    var conf = try confLoad(gpa, io, "00-config.json", &diag);
    try std.testing.expectEqualStrings("", conf.admi.user);
    try std.testing.expectEqualStrings("", conf.admi.mail);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const path = try std.fs.path.join(gpa, &.{ dir, "forgejo-account.json" });
    try acctOverride(gpa, io, path, &conf, &diag);
    try std.testing.expectEqualStrings("", conf.admi.user);
    try tmp.dir.writeFile(io, .{ .sub_path = "forgejo-account.json", .data = "{\"user\":\"ann\",\"mail\":\"ann@example.com\"}" });
    try acctOverride(gpa, io, path, &conf, &diag);
    try std.testing.expectEqualStrings("ann", conf.admi.user);
    try std.testing.expectEqualStrings("ann@example.com", conf.admi.mail);
    try tmp.dir.writeFile(io, .{ .sub_path = "forgejo-account.json", .data = "{\"pass\":\"x\"}" });
    try std.testing.expectError(error.ConfJson, acctOverride(gpa, io, path, &conf, &diag));
}

test "template fill" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const text = try tmplFill(aren.allocator(), "ssh://git@{host}:{port}/{user}.git", &.{ .{ "host", "h" }, .{ "port", "2222" }, .{ "user", "ann" } });
    try std.testing.expectEqualStrings("ssh://git@h:2222/ann.git", text);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
