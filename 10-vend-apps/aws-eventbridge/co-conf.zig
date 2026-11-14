// =====================================================================
// Des: Reads the settings file and the steps file and checks them. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: paths of 00-config.json and 10-steps.json
// Out: Conf and Steps structs, or an error with line and column
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .tmplMaxz = 32, .nameMaxz = 64, .agesMin = 60, .agesMax = 86400, .retrMax = 185, .minuDay = 1440, .minuHou = 60, .regiMin = 5, .regiMax = 40 };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, back: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    cred: struct { regi: []const u8, mail: []const u8 },
    apis: struct { sts: []const u8, iam: []const u8, iamr: []const u8, budg: []const u8, budr: []const u8, even: []const u8, sche: []const u8 },
    urls: struct { sign: []const u8, cons: []const u8, keys: []const u8, plan: []const u8 },
    name: struct { user: []const u8, grup: []const u8, sche: []const u8, conn: []const u8, dest: []const u8, rule: []const u8, rols: []const u8, rolr: []const u8, budg: []const u8, poli: []const u8 },
    tick: struct { urlz: []const u8, meth: []const u8, keyn: []const u8, rate: []const u8, rlim: u32, srcz: []const u8, dtyp: []const u8, busn: []const u8, body: []const u8, ages: u32, retr: u32, on: bool },
    budg: struct { limi: []const u8, unit: []const u8, warn: u32 },
    quot: struct { warn: u32, free: u64, evtp: f64, apip: f64, days: u32 },
    wait: struct { poll: u32, time: u32 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
    paid: struct { okay: bool, cap: u32 },
};

// one row of 10-steps.json
pub const Step = struct { numb: u32, iden: []const u8, kind: []const u8, hand: u32, name: []const u8, need: []const u8, done: []const u8 };
pub const Steps = struct { vers: u32, vend: []const u8, step: []const Step };

// where a parse error sits in the file
pub const Diag = struct { line: u64 = 0, colu: u64 = 0, mess: []const u8 = "" };

pub const Erro = error{ ConfRead, ConfJson, ConfValu };

// parse strict JSON text into any contract type (arena allocator expected)
fn jsonStri(comptime T: type, gpa: std.mem.Allocator, text: []const u8, diag: *Diag) Erro!T {
    var scan = std.json.Scanner.initCompleteInput(gpa, text);
    var jdia = std.json.Diagnostics{};
    scan.enableDiagnostics(&jdia);
    return std.json.parseFromTokenSourceLeaky(T, gpa, &scan, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |erro| {
        diag.* = .{ .line = jdia.getLine(), .colu = jdia.getColumn(), .mess = @errorName(erro) };
        return error.ConfJson;
    };
}

// parse settings text, then check the values types cannot express
pub fn confPars(gpa: std.mem.Allocator, text: []const u8, diag: *Diag) Erro!Conf {
    const conf = try jsonStri(Conf, gpa, text, diag);
    try confChec(conf, diag);
    return conf;
}

// ticks per month for "rate(N unit)"; null when the text is not a valid rate
pub fn rateMont(rate: []const u8, days: u32) ?u64 {
    if (!std.mem.startsWith(u8, rate, "rate(") or !std.mem.endsWith(u8, rate, ")")) return null;
    const inne = rate["rate(".len .. rate.len - 1];
    const spac = std.mem.indexOfScalar(u8, inne, ' ') orelse return null;
    const numb = std.fmt.parseInt(u32, inne[0..spac], 10) catch return null;
    if (numb == 0) return null;
    const unit = inne[spac + 1 ..];
    const one = numb == 1;
    const mins: u64 = if (std.mem.eql(u8, unit, if (one) "minute" else "minutes")) 1 else if (std.mem.eql(u8, unit, if (one) "hour" else "hours")) CF.minuHou else if (std.mem.eql(u8, unit, if (one) "day" else "days")) CF.minuDay else return null;
    return @as(u64, days) * CF.minuDay / (mins * numb);
}

// true for a name AWS accepts: letters, digits, . _ -
pub fn nameOkay(text: []const u8) bool {
    if (text.len == 0 or text.len > CF.nameMaxz) return false;
    for (text) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
    return true;
}

// true for a region id like eu-west-1
pub fn regiOkay(text: []const u8) bool {
    if (text.len < CF.regiMin or text.len > CF.regiMax) return false;
    for (text) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    return true;
}

// https only, loopback http allowed for the mock, and {regi} where a region goes
fn urlzOkay(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "https://") or std.mem.startsWith(u8, text, "http://127.0.0.1");
}

// value rules that types cannot express
fn confChec(conf: Conf, diag: *Diag) Erro!void {
    const nam = conf.name;
    const fail: ?[]const u8 = blk: {
        if (conf.vers != CF.versWant) break :blk "vers must be 1";
        if (conf.http.trys == 0) break :blk "http.trys must be above 0";
        if (conf.cred.regi.len > 0 and !regiOkay(conf.cred.regi)) break :blk "cred.regi must be empty or a region id like us-east-1";
        if (!regiOkay(conf.apis.iamr) or !regiOkay(conf.apis.budr)) break :blk "apis.iamr and apis.budr must be region ids";
        for ([_][]const u8{ conf.apis.sts, conf.apis.even, conf.apis.sche }) |item| if (std.mem.indexOf(u8, item, "{regi}") == null and !std.mem.startsWith(u8, item, "http://127.0.0.1")) break :blk "apis.sts, apis.even and apis.sche must contain {regi}";
        for ([_][]const u8{ conf.apis.sts, conf.apis.iam, conf.apis.budg, conf.apis.even, conf.apis.sche }) |item| if (!urlzOkay(item)) break :blk "every apis.* address must start with https://";
        for ([_][]const u8{ nam.user, nam.grup, nam.sche, nam.conn, nam.dest, nam.rule, nam.rols, nam.rolr, nam.budg, nam.poli }) |item| if (!nameOkay(item)) break :blk "name.* may use letters, digits, . _ - only (1..64)";
        if (conf.tick.urlz.len > 0 and !std.mem.startsWith(u8, conf.tick.urlz, "https://")) break :blk "tick.urlz must be empty or start with https://";
        if (!(std.mem.eql(u8, conf.tick.meth, "POST") or std.mem.eql(u8, conf.tick.meth, "PUT") or std.mem.eql(u8, conf.tick.meth, "PATCH"))) break :blk "tick.meth must be POST, PUT or PATCH";
        if (conf.tick.keyn.len == 0 or conf.tick.srcz.len == 0 or conf.tick.dtyp.len == 0 or conf.tick.busn.len == 0) break :blk "tick.keyn, srcz, dtyp and busn must not be empty";
        if (std.mem.startsWith(u8, conf.tick.srcz, "aws.")) break :blk "tick.srcz must not start with aws.";
        const mont = rateMont(conf.tick.rate, conf.quot.days) orelse break :blk "tick.rate must look like rate(1 minute) or rate(5 minutes)";
        if (conf.tick.rlim == 0) break :blk "tick.rlim must be above 0";
        if (conf.tick.ages < CF.agesMin or conf.tick.ages > CF.agesMax) break :blk "tick.ages must be 60..86400";
        if (conf.tick.retr > CF.retrMax) break :blk "tick.retr must be 185 or less";
        if (conf.quot.free == 0 or conf.quot.days == 0 or conf.quot.warn == 0 or conf.quot.warn > 100) break :blk "quot.free and quot.days must be above 0, quot.warn 1..100";
        if (mont > conf.quot.free and !conf.paid.okay) break :blk "tick.rate gives more ticks per month than quot.free and paid.okay is false";
        const lim = std.fmt.parseFloat(f64, conf.budg.limi) catch break :blk "budg.limi must be a number like 1.0";
        if (lim <= 0 or conf.budg.unit.len == 0 or conf.budg.warn == 0 or conf.budg.warn > 100) break :blk "budg.limi above 0, budg.unit set, budg.warn 1..100";
        if (conf.wait.poll == 0 or conf.guid.poll == 0) break :blk "wait.poll and guid.poll must be above 0";
        if (conf.paid.okay and conf.paid.cap == 0) break :blk "paid.okay needs a paid.cap above 0";
        break :blk null;
    };
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

// parse the steps text and check it is numbered 0..n in order with unique ids
pub fn stepPars(gpa: std.mem.Allocator, text: []const u8, diag: *Diag) Erro!Steps {
    const steps = try jsonStri(Steps, gpa, text, diag);
    var fail: ?[]const u8 = if (steps.vers != CF.versWant) "steps vers must be 1" else null;
    for (steps.step, 0..) |item, indx| {
        if (item.numb != indx) fail = "steps must be numbered 0..n in order";
        for (steps.step[0..indx]) |prev| if (std.mem.eql(u8, prev.iden, item.iden)) {
            fail = "step ids must be unique";
        };
    }
    if (fail) |mess| {
        diag.* = .{ .mess = mess };
        return error.ConfValu;
    }
    return steps;
}

// read + parse the steps file
pub fn stepLoad(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diag) Erro!Steps {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| {
        diag.* = .{ .mess = @errorName(erro) };
        return error.ConfRead;
    };
    return stepPars(gpa, text, diag);
}

// replace every {name} in a template
pub fn tmplFill(gpa: std.mem.Allocator, tmpl: []const u8, name: []const u8, valu: []const u8) ![]u8 {
    var keyz: [CF.tmplMaxz]u8 = undefined;
    const mark = try std.fmt.bufPrint(&keyz, "{{{s}}}", .{name});
    return std.mem.replaceOwned(u8, gpa, tmpl, mark, valu);
}

// the shipped files must load: guards the real files against typos
test "shipped config and steps parse" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var diag = Diag{};
    const conf = confLoad(aren.allocator(), std.testing.io, "00-config.json", &diag) catch |erro| {
        std.debug.print("config: {s} line {d} col {d} {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return erro;
    };
    try std.testing.expect(!conf.paid.okay and conf.tick.urlz.len == 0);
    try std.testing.expectEqual(@as(?u64, 43200), rateMont(conf.tick.rate, conf.quot.days));
    const steps = try stepLoad(aren.allocator(), std.testing.io, "10-steps.json", &diag);
    var hand: u32 = 0;
    for (steps.step) |item| hand = @max(hand, item.hand);
    try std.testing.expectEqual(@as(u32, 3), hand); // the 3 hand jobs, no more
    try std.testing.expectEqual(@as(usize, 14), steps.step.len);
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
    const rate = try std.mem.replaceOwned(u8, gpa, good, "rate(1 minute)", "rate(1 minutes)");
    try std.testing.expectError(error.ConfValu, confPars(gpa, rate, &diag));
    const free = try std.mem.replaceOwned(u8, gpa, good, "\"free\": 14000000", "\"free\": 40000");
    try std.testing.expectError(error.ConfValu, confPars(gpa, free, &diag));
    const plai = try std.mem.replaceOwned(u8, gpa, good, "https://scheduler.{regi}", "http://scheduler.{regi}");
    try std.testing.expectError(error.ConfValu, confPars(gpa, plai, &diag));
    const urlz = try std.mem.replaceOwned(u8, gpa, good, "\"urlz\": \"\"", "\"urlz\": \"http://x.test/t\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, urlz, &diag));
    const paid = try std.mem.replaceOwned(u8, gpa, good, "\"okay\": false, \"cap\": 0", "\"okay\": true, \"cap\": 0");
    try std.testing.expectError(error.ConfValu, confPars(gpa, paid, &diag));
    const srcz = try std.mem.replaceOwned(u8, gpa, good, "\"cloud-house.tick\"", "\"aws.tick\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, srcz, &diag));
}

test "rate maths and template fill and step order check" {
    try std.testing.expectEqual(@as(?u64, 8640), rateMont("rate(5 minutes)", 30));
    try std.testing.expectEqual(@as(?u64, 720), rateMont("rate(1 hour)", 30));
    try std.testing.expectEqual(@as(?u64, 30), rateMont("rate(1 day)", 30));
    try std.testing.expect(rateMont("rate(0 minutes)", 30) == null);
    try std.testing.expect(rateMont("cron(* * * * ? *)", 30) == null);
    try std.testing.expect(rateMont("rate(2 minute)", 30) == null);
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const text = try tmplFill(gpa, "https://events.{regi}.x", "regi", "eu-1");
    try std.testing.expectEqualStrings("https://events.eu-1.x", text);
    var diag = Diag{};
    const bad = "{\"vers\":1,\"vend\":\"x\",\"step\":[{\"numb\":1,\"iden\":\"a\",\"kind\":\"auto\",\"hand\":0,\"name\":\"n\",\"need\":\"n\",\"done\":\"d\"}]}";
    try std.testing.expectError(error.ConfValu, stepPars(gpa, bad, &diag));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
