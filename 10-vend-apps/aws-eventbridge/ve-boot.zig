// =====================================================================
// Des: Steps 0-3: check the settings and the tick rate against the free quota, the two sign-up hand jobs, and the console hand job that mints the first access key. The pasted key stays in memory; a signed call to STS proves it works and names the account.
// Flo: check rate > guide sign-up > guide console login + MFA > ask region > ask hidden key pair > poll STS until AWS accepts it
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, vault, typed lines)
// Out: engine rows pref-chec, sign-card, cons-mfa, keyz-boot
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const conf = @import("co-conf.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const iamz = @import("ap-iam.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;

const CF = .{ .idMinz = 16, .idMaxz = 128, .secMinz = 20, .secMaxz = 128 };

pub fn rows(ctx: *Ctx) [4]engi.Row {
    return .{
        ctxx.row(ctx, "pref-chec", &prefChec),
        ctxx.row(ctx, "sign-card", &signCard),
        ctxx.row(ctx, "cons-mfa", &consMfa),
        ctxx.row(ctx, "keyz-boot", &keyzBoot),
    };
}

// step 0: the rate must fit the free quota unless --paid
fn prefChec(ctx: *Ctx) anyerror!Done {
    const mont = conf.rateMont(ctx.conf.tick.rate, ctx.conf.quot.days) orelse return error.BadRate;
    if (mont > ctx.conf.quot.free and !ctx.paid) {
        osyz.errz("{d} ticks a month is above the free {d}\nwhy: it would cost money\nfix: lower tick.rate, or set paid.okay + paid.cap and run with --paid\n", .{ mont, ctx.conf.quot.free });
        return error.NeedPaid;
    }
    return .{ .okay = try std.fmt.allocPrint(ctx.gpa, "config ok, {d} ticks a month of {d} free", .{ mont, ctx.conf.quot.free }) };
}

fn neverPoll(raw: *anyopaque) anyerror!bool {
    _ = raw;
    return false; // not detectable: the human types g
}

// step 1: hand job 1
fn signCard(ctx: *Ctx) anyerror!Done {
    return .{ .wait = .{
        .urlz = ctx.conf.urls.sign,
        .line = .{ "Fill in email, name, card and phone. When it asks for a plan, choose PAID (the free plan is suspended after 6 months).", "Open the email from AWS and click its link.", "When the sign-up says your account is ready, type g." },
        .poll = &neverPoll,
        .ctx = ctx,
    } };
}

// step 2: hand job 2
fn consMfa(ctx: *Ctx) anyerror!Done {
    return .{ .wait = .{
        .urlz = ctx.conf.urls.cons,
        .line = .{ "Log in as the root user with your email.", "Set up MFA when asked (an authenticator app) and approve the code.", "When you can see the console home page, type g." },
        .poll = &neverPoll,
        .ctx = ctx,
    } };
}

// true for text shaped like an access key id
pub fn idShape(text: []const u8) bool {
    if (text.len < CF.idMinz or text.len > CF.idMaxz) return false;
    for (text) |byte| if (!std.ascii.isAlphanumeric(byte)) return false;
    return true;
}

// true for text shaped like a secret access key
pub fn secShape(text: []const u8) bool {
    if (text.len < CF.secMinz or text.len > CF.secMaxz) return false;
    for (text) |byte| if (byte <= ' ') return false;
    return true;
}

// step 3: hand job 3
fn keyzBoot(ctx: *Ctx) anyerror!Done {
    const idsz = &ctx.stat.data.idsz;
    if (idsz.regi.len == 0) idsz.regi = ctx.conf.cred.regi;
    if (idsz.regi.len == 0) {
        ctx.say("  Type the region for the tick (example: us-east-1): ", .{});
        const got = ctx.inpu.wait(ctx.conf.guid.wait) orelse return error.GuidTime;
        if (std.mem.eql(u8, got, "x")) return engi.Stop.EngiStop;
        if (!conf.regiOkay(got)) {
            osyz.errz("not a region id: use lowercase letters, digits and dashes, like us-east-1\n", .{});
            return error.BadRegion;
        }
        idsz.regi = got;
    }
    try ctx.stat.save();

    // resumed run: the scoped key may already work
    if (ctx.scoped() != null and try ctx.useCreds()) {
        if (try iamz.stsWho(ctx.aws)) |acct| {
            idsz.acct = acct;
            try ctx.stat.save();
            return .{ .okay = "scoped key already works" };
        }
    }

    if (ctx.boot == null) {
        if (ctx.conf.guid.open) _ = osyz.urlzOpen(ctx.io, ctx.gpa, ctx.conf.urls.keys);
        ctx.say("  open: {s}\n  1. Click your account name (top right) > Security credentials.\n  2. Access keys > Create access key. Tick the warning box, then Create.\n  3. Paste the two values below. They stay in memory only and are never saved.\n", .{ctx.conf.urls.keys});
        const akid = ctx.inpu.hidd("  access key id: ") orelse return error.GuidTime;
        if (std.mem.eql(u8, akid, "x")) return engi.Stop.EngiStop;
        const secr = ctx.inpu.hidd("  secret access key: ") orelse return error.GuidTime;
        if (!idShape(akid) or !secShape(secr)) {
            osyz.errz("those values do not look like an access key id and secret\nfix: copy both again from the console (no spaces) and rerun\n", .{});
            return error.BadKey;
        }
        ctx.boot = .{ .akid = akid, .secr = secr };
    }

    // detect, don't ask: poll a signed STS call until AWS accepts the key
    if (!try ctx.useCreds()) return error.NoCreds;
    var tail: u64 = ctx.conf.wait.time;
    while (true) {
        if (try iamz.stsWho(ctx.aws)) |acct| {
            idsz.acct = acct;
            break;
        }
        if (tail <= ctx.conf.wait.poll) {
            osyz.errz("AWS still refuses the key: {s}\nfix: check the key was copied whole and your PC clock is right (limit 5 minutes), then rerun\n", .{ctx.aws.last});
            ctx.boot = null;
            return error.GuidTime;
        }
        tail -= ctx.conf.wait.poll;
        ctx.sleepSecs(ctx.conf.wait.poll);
    }
    try ctx.stat.save();
    return .{ .okay = "signed call to STS works" };
}

test "key shapes" {
    try std.testing.expect(idShape("AKIAIOSFODNN7EXAMPLE"));
    try std.testing.expect(!idShape("AKIA short"));
    try std.testing.expect(secShape("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"));
    try std.testing.expect(!secShape("has space inside the secret value ok ok"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
