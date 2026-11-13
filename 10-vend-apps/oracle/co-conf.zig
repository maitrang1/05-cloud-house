// =====================================================================
// Des: Reads the settings file and the steps file and checks them. Every tunable lives there. A missing or unknown setting stops the app with the line and column of the mistake.
// Flo: read file > parse strict > check values > return typed settings
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: paths of 00-config.json and 10-steps.json
// Out: Conf and Steps structs, or an error with line and column
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .versWant = 1, .tmplMaxz = 32, .portMaxz = 65535, .bootMinz = 47, .dutyMaxz = 90 };

pub const Ingr = struct { port: u32, cidr: []const u8, desc: []const u8 };

// the settings contract, v1 (no defaults: every key must be in the file)
pub const Conf = struct {
    vers: u32,
    data: struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8, back: []const u8 },
    vaul: struct { envz: []const u8, time: u32, memo: u32, para: u24 },
    http: struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 },
    apis: struct { iden: []const u8, iaas: []const u8, vers: []const u8 },
    urls: struct { sign: []const u8, keys: []const u8 },
    keyz: struct { file: []const u8, tool: []const u8, bits: u32, comm: []const u8 },
    cred: struct { tena: []const u8, user: []const u8, regi: []const u8 },
    comp: struct { name: []const u8, desc: []const u8 },
    netw: struct { vcnn: []const u8, vcnc: []const u8, subn: []const u8, subc: []const u8, igwn: []const u8, routn: []const u8, secn: []const u8, ruln: []const u8 },
    ingr: []const Ingr,
    inst: struct { name: []const u8, shap: []const u8, free: []const []const u8, imgo: []const u8, imgv: []const u8, boot: u32, ocpu: u32, memg: u32, fall: []const u8, fcpu: u32, fmem: u32, user: []const u8, wait: u32, poll: u32 },
    boot: struct { urlz: []const u8, sha2: []const u8, bina: []const u8, svcn: []const u8, svcu: []const u8, args: []const u8 },
    cini: []const []const u8,
    unit: []const []const u8,
    keep: struct { on: bool, duty: u32, secs: u32 },
    kunit: []const []const u8,
    paid: struct { okay: bool, cap: u32 },
    quot: struct { warn: u32, vmax: u32, bmax: u32, ocpm: u32, memm: u32 },
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
    tool: struct { time: u32 },
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

fn hasText(list: []const []const u8, need: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, need)) return true;
    return false;
}

// value rules that types cannot express
fn confChec(conf: Conf, diag: *Diag) Erro!void {
    const fail: ?[]const u8 = blk: {
        if (conf.vers != CF.versWant) break :blk "vers must be 1";
        if (conf.http.trys == 0) break :blk "http.trys must be above 0";
        if (conf.guid.poll == 0 or conf.inst.poll == 0) break :blk "guid.poll and inst.poll must be above 0";
        if (std.mem.indexOf(u8, conf.apis.iden, "{regi}") == null or std.mem.indexOf(u8, conf.apis.iaas, "{regi}") == null) break :blk "apis.iden and apis.iaas must contain {regi}";
        if (!std.mem.startsWith(u8, conf.apis.iden, "https://") and !std.mem.startsWith(u8, conf.apis.iden, "http://127.0.0.1")) break :blk "apis.iden must be https (or loopback)";
        if (conf.keyz.bits < 2048) break :blk "keyz.bits must be 2048 or more";
        if (conf.ingr.len == 0) break :blk "ingr must list at least the ssh port";
        for (conf.ingr) |item| if (item.port == 0 or item.port > CF.portMaxz or item.cidr.len == 0) break :blk "ingr rows need port 1..65535 and a cidr";
        if (conf.inst.free.len == 0) break :blk "inst.free must list the Always Free shapes";
        if (!conf.paid.okay and !hasText(conf.inst.free, conf.inst.shap)) break :blk "inst.shap is not in inst.free and paid.okay is false";
        if (conf.inst.fall.len > 0 and !hasText(conf.inst.free, conf.inst.fall) and !conf.paid.okay) break :blk "inst.fall is not in inst.free and paid.okay is false";
        if (conf.inst.ocpu > conf.quot.ocpm or conf.inst.memg > conf.quot.memm) break :blk "inst.ocpu / inst.memg are above the free quota quot.ocpm / quot.memm";
        if ((conf.inst.ocpu == 0) != (conf.inst.memg == 0)) break :blk "inst.ocpu and inst.memg are both 0 (fixed shape) or both set (flex shape)";
        if (conf.inst.boot < CF.bootMinz) break :blk "inst.boot must be 47 GB or more";
        if (conf.quot.vmax == 0 or conf.quot.bmax == 0 or conf.quot.warn == 0 or conf.quot.warn > 100) break :blk "quot.* must be above 0 and quot.warn at most 100";
        if (conf.keep.duty == 0 or conf.keep.duty > CF.dutyMaxz or conf.keep.secs == 0) break :blk "keep.duty must be 1..90 and keep.secs above 0";
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

// fill a list of lines and join them with newlines (trailing newline included)
pub fn linzFill(gpa: std.mem.Allocator, lines: []const []const u8, pair: []const Pair) ![]u8 {
    var outp: std.ArrayList(u8) = .empty;
    for (lines) |item| {
        try outp.appendSlice(gpa, try tmplFill(gpa, item, pair));
        try outp.append(gpa, '\n');
    }
    return outp.toOwnedSlice(gpa);
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
    try std.testing.expect(!conf.paid.okay and !conf.keep.on);
    try std.testing.expectEqual(@as(usize, 2), conf.ingr.len);
    const steps = try stepLoad(aren.allocator(), std.testing.io, "10-steps.json", &diag);
    var hand: u32 = 0;
    for (steps.step) |item| hand = @max(hand, item.hand);
    try std.testing.expectEqual(@as(u32, 3), hand); // the 3 hand jobs, no more
    try std.testing.expectEqual(@as(usize, 12), steps.step.len);
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
    const shap = try std.mem.replaceOwned(u8, gpa, good, "\"shap\": \"VM.Standard.A1.Flex\"", "\"shap\": \"VM.Standard.E4.Flex\"");
    try std.testing.expectError(error.ConfValu, confPars(gpa, shap, &diag));
    const bits = try std.mem.replaceOwned(u8, gpa, good, "\"bits\": 2048", "\"bits\": 1024");
    try std.testing.expectError(error.ConfValu, confPars(gpa, bits, &diag));
    const plai = try std.mem.replaceOwned(u8, gpa, good, "https://identity.{regi}", "http://identity.{regi}");
    try std.testing.expectError(error.ConfValu, confPars(gpa, plai, &diag));
    const paid = try std.mem.replaceOwned(u8, gpa, good, "\"okay\": false, \"cap\": 0", "\"okay\": true, \"cap\": 0");
    try std.testing.expectError(error.ConfValu, confPars(gpa, paid, &diag));
}

test "template fill and step order check" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const text = try tmplFill(gpa, "https://iaas.{regi}.x/{vers}", &.{ .{ "regi", "eu-1" }, .{ "vers", "v1" } });
    try std.testing.expectEqualStrings("https://iaas.eu-1.x/v1", text);
    var diag = Diag{};
    const bad = "{\"vers\":1,\"vend\":\"x\",\"step\":[{\"numb\":1,\"iden\":\"a\",\"kind\":\"auto\",\"hand\":0,\"name\":\"n\",\"need\":\"n\",\"done\":\"d\"}]}";
    try std.testing.expectError(error.ConfValu, stepPars(gpa, bad, &diag));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
