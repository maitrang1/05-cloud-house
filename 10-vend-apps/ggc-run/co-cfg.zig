// =====================================================================
// Des: Reads the settings file and the step list and checks them. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings; steps: read file, or fall back to the embedded copy
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json, optional path of the step file
// Out: Conf struct and Steps struct, or an error with line and column
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .maxiCeil = 10, .pctMaxz = 100, .budgMaxz = 10.0, .tmplMaxz = 32, .projMinz = 6, .projMaxz = 30, .loopHost = "http://127.0.0.1", .stepEmbd = @embedFile("df-steps.json") };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, stat: []const u8, audi: []const u8, hand: []const u8, step: []const u8 },
    goog: struct { regi: []const u8, free: []const []const u8, proj_base: []const u8, proj_iden: []const u8, proj_name: []const u8, serv: []const u8, sacc: []const u8, arty: []const u8 },
    apis: struct { crmz: []const u8, bill: []const u8, budg: []const u8, usag: []const u8, iamz: []const u8, arti: []const u8, runz: []const u8, moni: []const u8 },
    enab: []const []const u8,
    auth: struct { mode: []const u8, toke_envz: []const u8, quot_head: bool, life_secs: u32 },
    tool: struct { gclo: []const u8, time: u32 },
    gclo: struct { acct: []const []const u8, logi: []const []const u8, toke: []const []const u8, revo: []const []const u8 },
    budg: struct { name: []const u8, amou: u32, step: []const f64, bill_acct: []const u8 },
    imag: struct { refe: []const u8, sour: []const u8, upst: []const u8 },
    serv: struct { mini: u32, maxi: u32, cpuz: []const u8, memo: []const u8, idle: bool, conc: u32, time: []const u8, publ: bool, ingr: []const u8, port: u32, role: []const u8 },
    tick: struct { path: []const u8, prob: bool, okay: []const u32, ruid: []const u8 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32, sign: []const u8, bill: []const u8, cons: []const u8 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32, lro_msec: u32, lro_secs: u32 },
    limi: struct { reqs: u64, vcpu: u64, gibs: u64, warn: u32 },

    // true when tokens come from gcloud (else from an env var)
    pub fn gcloMode(self: *const Conf) bool {
        return std.mem.eql(u8, self.auth.mode, "gcloud");
    }
};

// one row of the step list
pub const StepRow = struct { numb: u32, iden: []const u8, kind: []const u8, acts: []const u8, hand: u32, name: []const u8, need: []const u8, done: []const u8 };

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

// true when an API base is https, or the loopback mock
fn baseOkay(base: []const u8) bool {
    return std.mem.startsWith(u8, base, "https://") or std.mem.startsWith(u8, base, CF.loopHost);
}

// true for a legal Google project id: 6-30 chars, lowercase, digits, hyphen, starts with a letter
pub fn projIdenOkay(text: []const u8) bool {
    if (text.len < CF.projMinz or text.len > CF.projMaxz or !std.ascii.isLower(text[0]) or text[text.len - 1] == '-') return false;
    for (text) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    return true;
}

// true when the region is on the free-tier list
fn regiFree(regi: []const u8, free: []const []const u8) bool {
    for (free) |one| if (std.mem.eql(u8, one, regi)) return true;
    return false;
}

// value rules that types cannot express
fn confChec(conf: Conf, diag: *Diag) Erro!void {
    const apis = conf.apis;
    const fail: ?[]const u8 = if (conf.vers != CF.versWant) "vers must be 1" else if (!std.mem.eql(u8, conf.auth.mode, "gcloud") and !std.mem.eql(u8, conf.auth.mode, "env")) "auth.mode must be gcloud or env" else if (conf.serv.maxi < 1 or conf.serv.maxi > CF.maxiCeil) "serv.maxi must be 1..10" else if (conf.serv.mini > conf.serv.maxi) "serv.mini must not be above serv.maxi" else if (conf.serv.conc == 0) "serv.conc must be above 0" else if (conf.budg.amou == 0) "budg.amou must be above 0" else if (conf.budg.step.len == 0) "budg.step must list a threshold" else if (conf.limi.warn == 0 or conf.limi.warn > CF.pctMaxz) "limi.warn must be 1..100" else if (conf.http.trys == 0) "http.trys must be above 0" else if (conf.guid.poll == 0) "guid.poll must be above 0" else if (conf.goog.regi.len == 0 or conf.goog.serv.len == 0 or conf.goog.sacc.len == 0) "goog.regi, goog.serv, goog.sacc must be set" else if (!regiFree(conf.goog.regi, conf.goog.free)) "goog.regi must be one of goog.free (free-tier regions); other regions bill from the first second" else if (conf.goog.proj_iden.len != 0 and !projIdenOkay(conf.goog.proj_iden)) "goog.proj_iden is not a legal project id" else if (conf.goog.proj_iden.len == 0 and !projIdenOkay(conf.goog.proj_base)) "goog.proj_base is not a legal project id prefix" else if (conf.tick.path.len == 0 or conf.tick.path[0] != '/') "tick.path must start with /" else if (conf.tick.okay.len == 0) "tick.okay must list a status" else if (conf.imag.refe.len == 0 and conf.imag.sour.len == 0) "imag.refe or imag.sour must be set" else if (conf.imag.sour.len != 0 and !baseOkay(conf.imag.upst)) "imag.upst must be https" else if (conf.enab.len == 0) "enab must list an API" else if (conf.gclo.toke.len == 0 or conf.gclo.acct.len == 0) "gclo.acct and gclo.toke must be set" else if (!baseOkay(apis.crmz) or !baseOkay(apis.bill) or !baseOkay(apis.budg) or !baseOkay(apis.usag) or !baseOkay(apis.iamz) or !baseOkay(apis.arti) or !baseOkay(apis.runz) or !baseOkay(apis.moni)) "every apis.* base must be https" else null;
    if (fail) |mess| {
        diag.* = .{ .mess = mess };
        return error.ConfValu;
    }
    for (conf.budg.step) |pct| if (!(pct > 0 and pct <= CF.budgMaxz)) {
        diag.* = .{ .mess = "budg.step values must be above 0 and at most 10" };
        return error.ConfValu;
    };
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
test "shipped config and steps parse" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    const conf = confLoad(aren.allocator(), std.testing.io, "00-config.json", &diag) catch |erro| {
        std.debug.print("config: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return erro;
    };
    try std.testing.expectEqual(@as(u32, 1), conf.serv.maxi);
    try std.testing.expectEqual(@as(u32, 0), conf.serv.mini);
    try std.testing.expect(conf.gcloMode());
    const steps = try stepLoad(aren.allocator(), std.testing.io, "no-such-steps.json", &diag);
    try std.testing.expectEqual(@as(usize, 12), steps.step.len);
    var hand: u32 = 0;
    for (steps.step) |row| hand += row.hand;
    try std.testing.expectEqual(@as(u32, 6), hand);
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
        .{ "\"maxi\": 1", "\"maxi\": 11" },
        .{ "\"maxi\": 1", "\"maxi\": 0" },
        .{ "\"mode\": \"gcloud\"", "\"mode\": \"pass\"" },
        .{ "https://run.googleapis.com", "http://run.googleapis.com" },
        .{ "\"warn\": 80", "\"warn\": 0" },
        .{ "\"path\": \"/tick\"", "\"path\": \"tick\"" },
        .{ "\"proj_base\": \"cloud-house\"", "\"proj_base\": \"Cloud House\"" },
        .{ "\"amou\": 1", "\"amou\": 0" },
        .{ "\"regi\": \"us-central1\"", "\"regi\": \"europe-west1\"" },
    };
    for (case) |pair| {
        const bad = try std.mem.replaceOwned(u8, gpa, good, pair[0], pair[1]);
        try std.testing.expectError(error.ConfValu, confPars(gpa, bad, &diag));
    }
}

test "project id rule and template fill" {
    try std.testing.expect(projIdenOkay("cloud-house-ab12cd"));
    try std.testing.expect(!projIdenOkay("Cloud"));
    try std.testing.expect(!projIdenOkay("1abcdef"));
    try std.testing.expect(!projIdenOkay("abc"));
    try std.testing.expect(!projIdenOkay("abcdef-"));
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const text = try tmplFill(aren.allocator(), "revoke {acct} now", &.{.{ "acct", "ann@example.com" }});
    try std.testing.expectEqualStrings("revoke ann@example.com now", text);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
