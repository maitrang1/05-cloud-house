// =====================================================================
// Des: Steps 4-6: the budget alert (first, because everything after can cost cents), the scoped IAM user with its own access key (vaulted at once), and the two roles Scheduler and the rule assume. Every make is find-first; policies are replace-style so a rerun changes nothing.
// Flo: find or make budget > find or make user + policy + key > vault key > poll until it works > find or make both roles
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, vault, signed client)
// Out: engine rows budg-make, iamu-make, role-make
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const conf = @import("co-conf.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const iamz = @import("ap-iam.zig");
const evnt = @import("ap-evnt.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;

const CF = .{
    .keyMax = 2, // AWS allows two access keys per user
    .poliName = "scoped",
    .trustFmt = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"{svcz}\"},\"Action\":\"sts:AssumeRole\",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"{acct}\"}}}]}",
    .svcSche = "scheduler.amazonaws.com",
    .svcEven = "events.amazonaws.com",
    .rolePut = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"{busa}\"}]}",
    .roleInv = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"events:InvokeApiDestination\",\"Resource\":\"arn:aws:events:{regi}:{acct}:api-destination/{dest}/*\"}]}",
    .userPol = "{\"Version\":\"2012-10-17\",\"Statement\":[" ++
        "{\"Effect\":\"Allow\",\"Action\":[\"scheduler:GetScheduleGroup\",\"scheduler:CreateScheduleGroup\"],\"Resource\":\"arn:aws:scheduler:{regi}:{acct}:schedule-group/{grup}\"}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"scheduler:GetSchedule\",\"scheduler:CreateSchedule\",\"scheduler:UpdateSchedule\"],\"Resource\":\"arn:aws:scheduler:{regi}:{acct}:schedule/{grup}/*\"}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"events:DescribeEventBus\"],\"Resource\":\"arn:aws:events:{regi}:{acct}:event-bus/{busn}\"}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"events:DescribeRule\",\"events:PutRule\",\"events:PutTargets\",\"events:ListTargetsByRule\"],\"Resource\":\"arn:aws:events:{regi}:{acct}:rule/{rule}\"}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"events:DescribeConnection\",\"events:CreateConnection\",\"events:DescribeApiDestination\",\"events:CreateApiDestination\"],\"Resource\":[\"arn:aws:events:{regi}:{acct}:connection/{conn}/*\",\"arn:aws:events:{regi}:{acct}:api-destination/{dest}/*\"]}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:CreateSecret\",\"secretsmanager:DescribeSecret\",\"secretsmanager:GetSecretValue\",\"secretsmanager:PutSecretValue\",\"secretsmanager:UpdateSecret\"],\"Resource\":\"arn:aws:secretsmanager:{regi}:{acct}:secret:events!connection/{conn}/*\"}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"iam:GetRole\",\"iam:GetRolePolicy\",\"iam:CreateRole\",\"iam:PutRolePolicy\",\"iam:PassRole\"],\"Resource\":[\"arn:aws:iam::{acct}:role/{rols}\",\"arn:aws:iam::{acct}:role/{rolr}\"]}," ++
        "{\"Effect\":\"Allow\",\"Action\":[\"budgets:ViewBudget\"],\"Resource\":\"arn:aws:budgets::{acct}:budget/{budg}\"}]}",
};

pub fn rows(ctx: *Ctx) [3]engi.Row {
    return .{ ctxx.row(ctx, "budg-make", &budgMake), ctxx.row(ctx, "iamu-make", &iamuMake), ctxx.row(ctx, "role-make", &roleMake) };
}

fn live(ctx: *Ctx) !void {
    if (!try ctx.useCreds()) return error.NoCreds;
}

// fill the {name} marks of a policy template from config and state
pub fn docFill(ctx: *Ctx, tmpl: []const u8) ![]const u8 {
    const idsz = ctx.stat.data.idsz;
    const nam = ctx.conf.name;
    const pair = [_][2][]const u8{
        .{ "regi", idsz.regi }, .{ "acct", idsz.acct },      .{ "grup", nam.grup },       .{ "busn", ctx.conf.tick.busn }, .{ "rule", nam.rule },
        .{ "conn", nam.conn },  .{ "dest", nam.dest },       .{ "rols", nam.rols },       .{ "rolr", nam.rolr },           .{ "budg", nam.budg },
    };
    var text: []const u8 = tmpl;
    for (pair) |item| text = try conf.tmplFill(ctx.gpa, text, item[0], item[1]);
    return text;
}

// step 4
fn budgMake(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const name = ctx.conf.name.budg;
    if (try evnt.budgGet(ctx.aws, idsz.acct, name)) {
        idsz.budg = name;
        try ctx.stat.save();
        return .{ .okay = "budget found" };
    }
    var mail: []const u8 = ctx.vaul.getz(ctxx.CF.vkMail) orelse ctx.conf.cred.mail;
    if (mail.len == 0) {
        ctx.say("  Which email should get the budget alert? ", .{});
        const got = ctx.inpu.wait(ctx.conf.guid.wait) orelse return error.GuidTime;
        if (std.mem.eql(u8, got, "x")) return engi.Stop.EngiStop;
        mail = got;
    }
    if (std.mem.indexOfScalar(u8, mail, '@') == null) {
        osyz.errz("that is not an email address\nfix: type it like name@example.com, or set cred.mail\n", .{});
        return error.BadMail;
    }
    try ctx.vaul.putz(ctxx.CF.vkMail, mail);
    try evnt.budgMake(ctx.aws, idsz.acct, name, ctx.conf.budg.limi, ctx.conf.budg.unit, ctx.conf.budg.warn, mail);
    if (!try evnt.budgGet(ctx.aws, idsz.acct, name)) return error.BudgVerify;
    idsz.budg = name;
    try ctx.stat.save();
    ctx.say("  AWS emails {s} a confirmation link: click it once so alerts reach you.\n", .{mail});
    return .{ .okay = "budget made" };
}

// step 5
fn iamuMake(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const name = ctx.conf.name.user;
    if (ctx.scoped() != null and ctx.boot == null) return .{ .okay = "scoped key already in the vault" };
    if (!try iamz.userGet(ctx.aws, name)) try iamz.userMake(ctx.aws, name);
    try iamz.userPolicy(ctx.aws, name, CF.poliName, try docFill(ctx, CF.userPol));
    idsz.user = name;
    try ctx.stat.save();

    // a key already in the vault and accepted: nothing to mint
    if (ctx.scoped()) |cred| {
        ctx.http.creds = cred;
        const ok = (try iamz.stsWho(ctx.aws)) != null;
        _ = try ctx.useCreds();
        if (ok) return .{ .okay = "scoped key already works" };
    }
    const have = try iamz.keysList(ctx.aws, name);
    if (have.len >= CF.keyMax) {
        osyz.errz("user {s} already has {d} access keys and none is in the vault\nwhy: a key is shown only once; AWS allows two per user\nfix: console > IAM > Users > {s} > Security credentials > make one inactive, then rerun\n", .{ name, have.len, name });
        return error.KeysFull;
    }
    const pair = try iamz.keyMake(ctx.aws, name);
    try ctx.vaul.putz(ctxx.CF.vkAkid, pair.akid); // vault first: the secret is shown once
    try ctx.vaul.putz(ctxx.CF.vkSecr, pair.secr);
    idsz.keyi = pair.akid;
    try ctx.stat.save();

    // a new key can take seconds to be accepted: poll
    var tail: u64 = ctx.conf.wait.time;
    while (true) {
        ctx.http.creds = ctx.scoped();
        const ok = (try iamz.stsWho(ctx.aws)) != null;
        _ = try ctx.useCreds();
        if (ok) break;
        if (tail <= ctx.conf.wait.poll) {
            osyz.errz("the new key is not accepted yet: {s}\nfix: wait a minute and rerun, it resumes here\n", .{ctx.aws.last});
            return error.WaitTime;
        }
        tail -= ctx.conf.wait.poll;
        ctx.sleepSecs(ctx.conf.wait.poll);
    }
    return .{ .okay = "scoped user made, key vaulted" };
}

// find or make one role; returns its arn
fn roleOne(ctx: *Ctx, name: []const u8, svcz: []const u8, polr: []const u8) ![]const u8 {
    const arnz = (try iamz.roleGet(ctx.aws, name)) orelse blk: {
        const trus = try conf.tmplFill(ctx.gpa, try conf.tmplFill(ctx.gpa, CF.trustFmt, "svcz", svcz), "acct", ctx.stat.data.idsz.acct);
        break :blk try iamz.roleMake(ctx.aws, name, trus);
    };
    try iamz.rolePolicy(ctx.aws, name, CF.poliName, polr);
    return arnz;
}

// step 6
fn roleMake(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const busa = (try evnt.busGet(ctx.aws, ctx.conf.tick.busn)) orelse {
        osyz.errz("event bus {s} not found\nwhy: tick.busn names a bus that does not exist\nfix: use \"default\" or make the bus in the console\n", .{ctx.conf.tick.busn});
        return error.NoBus;
    };
    const polr = try conf.tmplFill(ctx.gpa, CF.rolePut, "busa", busa);
    idsz.rols = try roleOne(ctx, ctx.conf.name.rols, CF.svcSche, polr);
    idsz.rolr = try roleOne(ctx, ctx.conf.name.rolr, CF.svcEven, try docFill(ctx, CF.roleInv));
    try ctx.stat.save();
    return .{ .okay = "both roles ready" };
}

test "policy templates fill with no mark left" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = conf.Diag{};
    const cfg = try conf.confLoad(gpa, std.testing.io, "00-config.json", &diag);
    var stz = @import("co-state.zig").Stat{ .gpa = gpa, .io = std.testing.io, .path = "x" };
    stz.data.idsz = .{ .regi = "us-east-1", .acct = "123456789012" };
    var ctx: Ctx = undefined;
    ctx.gpa = gpa;
    ctx.conf = &cfg;
    ctx.stat = &stz;
    const doc = try docFill(&ctx, CF.userPol);
    try std.testing.expect(std.mem.indexOf(u8, doc, "arn:aws:scheduler:us-east-1:123456789012:schedule-group/cloud-house") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, doc, '{') != null); // json braces stay
    for ([_][]const u8{ "{regi}", "{acct}", "{grup}", "{busn}", "{rule}", "{conn}", "{dest}", "{rols}", "{rolr}", "{budg}" }) |mark| try std.testing.expect(std.mem.indexOf(u8, doc, mark) == null);
    _ = try std.json.parseFromSlice(std.json.Value, gpa, doc, .{}); // still valid JSON
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
