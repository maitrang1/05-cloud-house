// =====================================================================
// Des: Steps 7-11: the API-key connection, the API destination to your tick URL, the rule that sends bus events to it, the schedule group and the one tick schedule, and the final check that every piece equals the config. Every step finds first and converges: missing is made, different is replaced, never removed.
// Flo: find or make connection > destination > rule + target > schedule group + schedule > re-read all and compare
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, vault, signed client)
// Out: engine rows conn-make, dest-make, rule-make, sche-make, tick-chec; checkAll() and pauseSet() for the drift, pause and resume commands
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const evnt = @import("ap-evnt.zig");
const sche = @import("ap-sche.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;

const CF = .{ .stConn = "AUTHORIZED", .stDest = "ACTIVE", .stRule = "ENABLED", .stOn = "ENABLED", .stOff = "DISABLED", .pattFmt = "{{\"source\":[\"{s}\"],\"detail-type\":[\"{s}\"]}}", .skipUrl = "tick.urlz is empty: set it to your dispatcher address, then run again" };

pub fn rows(ctx: *Ctx) [4]engi.Row {
    return .{ ctxx.row(ctx, "conn-make", &connMake), ctxx.row(ctx, "dest-make", &destMake), ctxx.row(ctx, "rule-make", &ruleMake), ctxx.row(ctx, "sche-make", &scheMake) };
}

pub fn rowChec(ctx: *Ctx) engi.Row {
    return ctxx.row(ctx, "tick-chec", &tickChec);
}

fn live(ctx: *Ctx) !void {
    if (!try ctx.useCreds()) return error.NoCreds;
}

// strip spaces and newlines so AWS-reformatted JSON compares equal
pub fn squeeze(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var outp: std.ArrayList(u8) = .empty;
    for (text) |byte| if (byte != ' ' and byte != '\n' and byte != '\r' and byte != '\t') try outp.append(gpa, byte);
    return outp.toOwnedSlice(gpa);
}

fn pattOf(ctx: *Ctx) ![]const u8 {
    return std.fmt.allocPrint(ctx.gpa, CF.pattFmt, .{ ctx.conf.tick.srcz, ctx.conf.tick.dtyp });
}

// poll a state reader until it says want or the time is up
fn stateWait(ctx: *Ctx, comptime what: []const u8) !void {
    var left: u64 = ctx.conf.wait.time;
    while (true) {
        const stz = (try evnt.connGet(ctx.aws, ctx.conf.name.conn)) orelse return error.WaitTime;
        if (std.mem.eql(u8, stz.state, CF.stConn)) return;
        if (left <= ctx.conf.wait.poll) {
            osyz.errz(what ++ " is {s}, not " ++ CF.stConn ++ "\nfix: wait a minute and rerun, it resumes here\n", .{stz.state});
            return error.WaitTime;
        }
        left -= ctx.conf.wait.poll;
        ctx.sleepSecs(ctx.conf.wait.poll);
    }
}

// step 7
fn connMake(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    var note: []const u8 = "connection found";
    if ((try evnt.connGet(ctx.aws, ctx.conf.name.conn)) == null) {
        const keyv: []const u8 = ctx.vaul.getz(ctxx.CF.vkTick) orelse blk: {
            const made = try ctx.randHex();
            try ctx.vaul.putz(ctxx.CF.vkTick, made); // vault first: the dispatcher needs this value
            break :blk made;
        };
        _ = try evnt.connMake(ctx.aws, ctx.conf.name.conn, ctx.conf.tick.keyn, keyv);
        note = "connection made";
    } else if (ctx.vaul.getz(ctxx.CF.vkTick) == null) {
        osyz.errz("connection {s} exists but its secret is not in the vault\nwhy: it was made by another run or another vault\nfix: make a new name in name.conn and rerun (the app never deletes the old one)\n", .{ctx.conf.name.conn});
        return error.SecretLost;
    }
    try stateWait(ctx, "connection");
    const have = (try evnt.connGet(ctx.aws, ctx.conf.name.conn)) orelse return error.ConnVerify;
    idsz.conn = have.arn;
    try ctx.stat.save();
    return .{ .okay = note };
}

// step 8
fn destMake(ctx: *Ctx) anyerror!Done {
    if (ctx.conf.tick.urlz.len == 0) return .{ .skip = CF.skipUrl };
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const tick = ctx.conf.tick;
    var note: []const u8 = "destination found";
    if (try evnt.destGet(ctx.aws, ctx.conf.name.dest)) |have| {
        if (!std.mem.eql(u8, have.urlz, tick.urlz) or !std.mem.eql(u8, have.meth, tick.meth)) {
            try evnt.destSet(ctx.aws, ctx.conf.name.dest, idsz.conn, tick.meth, tick.urlz, tick.rlim);
            note = "destination updated to the configured address";
        }
    } else {
        _ = try evnt.destMake(ctx.aws, ctx.conf.name.dest, idsz.conn, tick.meth, tick.urlz, tick.rlim);
        note = "destination made";
    }
    const back = (try evnt.destGet(ctx.aws, ctx.conf.name.dest)) orelse return error.DestVerify;
    if (!std.mem.eql(u8, back.state, CF.stDest)) return error.DestVerify;
    idsz.dest = back.arn;
    try ctx.stat.save();
    return .{ .okay = note };
}

// step 9
fn ruleMake(ctx: *Ctx) anyerror!Done {
    if (ctx.stat.data.idsz.dest.len == 0) return .{ .skip = CF.skipUrl };
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const tick = ctx.conf.tick;
    _ = try evnt.rulePut(ctx.aws, ctx.conf.name.rule, tick.busn, try pattOf(ctx), true);
    try evnt.targPut(ctx.aws, ctx.conf.name.rule, tick.busn, idsz.dest, idsz.rolr, tick.ages, tick.retr);
    const back = (try evnt.ruleGet(ctx.aws, ctx.conf.name.rule, tick.busn)) orelse return error.RuleVerify;
    idsz.rule = back.arn;
    var found = false;
    for (try evnt.targList(ctx.aws, ctx.conf.name.rule, tick.busn)) |item| if (std.mem.eql(u8, item.Arn, idsz.dest)) {
        found = true;
    };
    if (!found) return error.RuleVerify;
    try ctx.stat.save();
    return .{ .okay = "rule and target set" };
}

// what the schedule should be, from config and state
pub fn wantOf(ctx: *Ctx, enab: bool) !sche.Want {
    const tick = ctx.conf.tick;
    const busa = (try evnt.busGet(ctx.aws, tick.busn)) orelse return error.NoBus;
    return .{ .grup = ctx.conf.name.grup, .expr = tick.rate, .enab = enab, .bus = busa, .role = ctx.stat.data.idsz.rols, .input = tick.body, .srcz = tick.srcz, .dtyp = tick.dtyp, .ages = tick.ages, .retr = tick.retr };
}

// true when AWS says the role is not ready to be assumed yet (a fresh role takes seconds)
fn roleLate(last: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(last, "assume") != null or std.ascii.indexOfIgnoreCase(last, "role") != null;
}

// step 10
fn scheMake(ctx: *Ctx) anyerror!Done {
    if (ctx.stat.data.idsz.rule.len == 0) return .{ .skip = CF.skipUrl };
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const name = ctx.conf.name.sche;
    const want = try wantOf(ctx, ctx.conf.tick.on);
    if (!try sche.grupGet(ctx.aws, want.grup)) try sche.grupMake(ctx.aws, want.grup);
    var note: []const u8 = "schedule found";
    if (try sche.scheGet(ctx.aws, want.grup, name)) |have| {
        if (try schePart(ctx, have, want) > 0) {
            try sche.scheSet(ctx.aws, name, want);
            note = "schedule replaced to match the config";
        }
    } else {
        var left: u64 = ctx.conf.wait.time;
        while (true) {
            sche.scheMake(ctx.aws, name, want) catch |erro| {
                if (erro == error.ApiFail and roleLate(ctx.aws.last) and left > ctx.conf.wait.poll) {
                    left -= ctx.conf.wait.poll;
                    ctx.sleepSecs(ctx.conf.wait.poll);
                    continue;
                }
                return erro;
            };
            break;
        }
        note = "schedule made";
    }
    const back = (try sche.scheGet(ctx.aws, want.grup, name)) orelse return error.ScheVerify;
    idsz.sche = back.arn;
    try ctx.stat.save();
    return .{ .okay = note };
}

// how many fields of the schedule differ from what we want; each one is printed
fn schePart(ctx: *Ctx, have: sche.Have, want: sche.Want) !u32 {
    var diff: u32 = 0;
    const state: []const u8 = if (want.enab) CF.stOn else CF.stOff;
    const pair = [_][3][]const u8{
        .{ "state", have.state, state },     .{ "rate", have.expr, want.expr },       .{ "bus", have.bus, want.bus },
        .{ "role", have.role, want.role },   .{ "input", have.input, want.input },    .{ "source", have.srcz, want.srcz },
        .{ "detail-type", have.dtyp, want.dtyp },
    };
    for (pair) |item| if (!std.mem.eql(u8, item[1], item[2])) {
        diff += 1;
        ctx.say("  schedule {s}: AWS has \"{s}\", config wants \"{s}\"\n", .{ item[0], item[1], item[2] });
    };
    return diff;
}

// re-read every piece and count the differences from config (used by step 11 and the drift command)
pub fn checkAll(ctx: *Ctx) !u32 {
    var diff: u32 = 0;
    const idsz = ctx.stat.data.idsz;
    const tick = ctx.conf.tick;
    const conn = try evnt.connGet(ctx.aws, ctx.conf.name.conn);
    if (conn == null or !std.mem.eql(u8, conn.?.state, CF.stConn)) {
        diff += 1;
        ctx.say("  connection: missing or not {s}\n", .{CF.stConn});
    }
    if (tick.urlz.len == 0) {
        ctx.say("  to do: {s}\n", .{CF.skipUrl});
        return diff;
    }
    if (try evnt.destGet(ctx.aws, ctx.conf.name.dest)) |dest| {
        if (!std.mem.eql(u8, dest.urlz, tick.urlz) or !std.mem.eql(u8, dest.meth, tick.meth) or !std.mem.eql(u8, dest.state, CF.stDest)) {
            diff += 1;
            ctx.say("  destination: AWS has {s} {s} ({s}), config wants {s} {s}\n", .{ dest.meth, dest.urlz, dest.state, tick.meth, tick.urlz });
        }
    } else {
        diff += 1;
        ctx.say("  destination: missing\n", .{});
    }
    if (try evnt.ruleGet(ctx.aws, ctx.conf.name.rule, tick.busn)) |rule| {
        const want = try squeeze(ctx.gpa, try pattOf(ctx));
        const have = try squeeze(ctx.gpa, rule.patt);
        if (!std.mem.eql(u8, want, have) or !std.mem.eql(u8, rule.state, CF.stRule)) {
            diff += 1;
            ctx.say("  rule: pattern or state differs ({s})\n", .{rule.state});
        }
        var found = false;
        for (try evnt.targList(ctx.aws, ctx.conf.name.rule, tick.busn)) |item| if (std.mem.eql(u8, item.Arn, idsz.dest) and std.mem.eql(u8, item.RoleArn, idsz.rolr)) {
            found = true;
        };
        if (!found) {
            diff += 1;
            ctx.say("  rule: the target is not the destination with its role\n", .{});
        }
    } else {
        diff += 1;
        ctx.say("  rule: missing\n", .{});
    }
    const want = try wantOf(ctx, tick.on);
    if (try sche.scheGet(ctx.aws, want.grup, ctx.conf.name.sche)) |have| {
        diff += try schePart(ctx, have, want);
    } else {
        diff += 1;
        ctx.say("  schedule: missing\n", .{});
    }
    return diff;
}

// pause or resume: replace the schedule with the same fields and the other state
pub fn pauseSet(ctx: *Ctx, enab: bool) !void {
    try live(ctx);
    const want = try wantOf(ctx, enab);
    const have = (try sche.scheGet(ctx.aws, want.grup, ctx.conf.name.sche)) orelse return error.NoSchedule;
    var keep = want;
    keep.expr = have.expr; // pause changes the state only, never the rate
    keep.input = have.input;
    try sche.scheSet(ctx.aws, ctx.conf.name.sche, keep);
}

// step 11
fn tickChec(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const diff = try checkAll(ctx);
    if (diff > 0) {
        ctx.drift = true;
        osyz.errz("drift: {d} piece(s) differ from the config. Run `fix --live` to make AWS match\n", .{diff});
        return .{ .okay = "DRIFT: see the lines above" };
    }
    return .{ .okay = if (ctx.conf.tick.urlz.len == 0) "pieces so far equal config" else "all pieces equal config" };
}

test "squeeze strips layout only" {
    const outp = try squeeze(std.testing.allocator, "{ \"a\" : [\"b\"]\n}");
    defer std.testing.allocator.free(outp);
    try std.testing.expectEqualStrings("{\"a\":[\"b\"]}", outp);
    try std.testing.expect(roleLate("The execution role you provide must allow EventBridge Scheduler to assume the role"));
    try std.testing.expect(!roleLate("bad rate"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
