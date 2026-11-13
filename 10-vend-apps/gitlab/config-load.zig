// =====================================================================
// Des: Reads the settings file and checks it. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json
// Out: Conf struct, or an error with line and column
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .daysMaxz = 365, .tmplMaxz = 32 };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, step: []const u8, acct: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24 },
    repo: struct { path: []const u8, bran: []const u8, remo: []const u8 },
    gitl: struct { host: []const u8, webz: []const u8, apiz: []const u8, oaut: []const u8, user: []const u8, proj: []const u8, visi: []const u8, push: []const u8, sign: []const u8, sett: std.json.Value },
    gith: struct { apiz: []const u8, vers: []const u8, secr: []const u8, ping: []const u8, varz: []const u8, flow: []const u8, tmpl: []const u8, mess: []const u8, wait: u32 },
    oaut: struct { clid: []const u8, scop: []const u8 },
    logi: struct { orde: []const []const u8 },
    tool: struct { gitz: []const u8, sshk: []const u8, sshz: []const u8, glab: []const u8, ghcl: []const u8, time: u32 },
    glab: struct { stat: []const []const u8, logi: []const []const u8, toke: []const []const u8 },
    ghcl: struct { toke: []const []const u8 },
    sshz: struct { file: []const u8, conf: []const u8, titl: []const u8, user: []const u8, veri: bool },
    prot: struct { push: u32, merg: u32, forc: bool },
    toke: struct { name: []const u8, scop: []const []const u8, role: u32, days: u32, rota: u32 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    limi: struct { stor: u64, apiz: u32, warn: u32, cimn: u32, mirx: u32, usrx: u32 },
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

// GitLab's three visibility levels; anything else is a typo
fn visiOkay(visi: []const u8) bool {
    for ([_][]const u8{ "private", "internal", "public" }) |item| if (std.mem.eql(u8, visi, item)) return true;
    return false;
}

// value rules that types cannot express
fn confChec(conf: Conf, diag: *Diag) Erro!void {
    const fail: ?[]const u8 = if (conf.vers != CF.versWant) "vers must be 1" else if (conf.toke.days == 0 or conf.toke.days > CF.daysMaxz) "toke.days must be 1..365" else if (conf.toke.rota >= conf.toke.days and conf.toke.days > 1) "toke.rota must be below toke.days" else if (!visiOkay(conf.gitl.visi)) "gitl.visi must be private, internal or public" else if (conf.prot.forc) "prot.forc must be false" else if (conf.gitl.sett != .object) "gitl.sett must be an object" else if (conf.guid.poll == 0) "guid.poll must be above 0" else if (conf.http.trys == 0) "http.trys must be above 0" else if (conf.logi.orde.len == 0) "logi.orde must list a method" else if (conf.toke.scop.len == 0) "toke.scop must list a scope" else if (conf.limi.warn == 0 or conf.limi.warn > 100) "limi.warn must be 1..100" else if (conf.limi.stor == 0) "limi.stor must be above 0" else null;
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

// the private account file in the data folder fills gitl.user so no personal value sits in the synced config; a missing file changes nothing
pub fn acctOverride(gpa: std.mem.Allocator, io: std.Io, path: []const u8, conf: *Conf, diag: *Diag) Erro!void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| {
        if (erro == error.FileNotFound) return;
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfRead;
    };
    const Acct = struct { user: []const u8 = "" };
    const got = std.json.parseFromSliceLeaky(Acct, gpa, text, .{ .ignore_unknown_fields = false }) catch |erro| {
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfJson;
    };
    if (got.user.len > 0) conf.gitl.user = got.user;
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

// the shipped config must load: guards the real file against typos
test "shipped config parses" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    const conf = confLoad(aren.allocator(), std.testing.io, "00-config.json", &diag) catch |erro| {
        std.debug.print("config: {s} line {d} col {d}\n", .{ diag.mess, diag.line, diag.colu });
        return erro;
    };
    try std.testing.expectEqualStrings("gitlab.com", conf.gitl.host);
    try std.testing.expectEqual(@as(u32, 90), conf.toke.days);
    try std.testing.expect(!conf.gitl.sett.object.get("shared_runners_enabled").?.bool);
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
    const open = try std.mem.replaceOwned(u8, gpa, good, "\"visi\": \"public\"", "\"visi\": \"open\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, open, &diag));
    const forc = try std.mem.replaceOwned(u8, gpa, good, "\"forc\": false", "\"forc\": true");
    try std.testing.expectError(error.ConfValu, confPars(gpa, forc, &diag));
}

test "visibility is a setting: private, internal and public load; the shipped file is public" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = Diag{};
    const good = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "00-config.json", gpa, .limited(CF.fileMaxz));
    try std.testing.expectEqualStrings("public", (try confPars(gpa, good, &diag)).gitl.visi);
    for ([_][]const u8{ "private", "internal" }) |level| {
        const text = try std.mem.replaceOwned(u8, gpa, good, "\"visi\": \"public\"", try std.fmt.allocPrint(gpa, "\"visi\": \"{s}\"", .{level}));
        try std.testing.expectEqualStrings(level, (try confPars(gpa, text, &diag)).gitl.visi);
    }
}

test "account file fills gitl.user, a missing file changes nothing, an unknown key is refused; the shipped user is blank" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const io = std.testing.io;
    var diag = Diag{};
    var conf = try confLoad(gpa, io, "00-config.json", &diag);
    try std.testing.expectEqualStrings("", conf.gitl.user);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const path = try std.fs.path.join(gpa, &.{ dir, "gitlab-account.json" });
    try acctOverride(gpa, io, path, &conf, &diag);
    try std.testing.expectEqualStrings("", conf.gitl.user);
    try tmp.dir.writeFile(io, .{ .sub_path = "gitlab-account.json", .data = "{\"user\":\"ann\"}" });
    try acctOverride(gpa, io, path, &conf, &diag);
    try std.testing.expectEqualStrings("ann", conf.gitl.user);
    try tmp.dir.writeFile(io, .{ .sub_path = "gitlab-account.json", .data = "{\"mail\":\"x\"}" });
    try std.testing.expectError(error.ConfJson, acctOverride(gpa, io, path, &conf, &diag));
}

test "template fill" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const text = try tmplFill(aren.allocator(), "git@{host}:{user}/{proj}.git", &.{ .{ "host", "gitlab.com" }, .{ "user", "ann" }, .{ "proj", "cloud-house" } });
    try std.testing.expectEqualStrings("git@gitlab.com:ann/cloud-house.git", text);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
