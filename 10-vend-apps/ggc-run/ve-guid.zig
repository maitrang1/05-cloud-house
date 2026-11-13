// =====================================================================
// Des: Step actions for the start: preflight, then the three hand jobs (Google account, login code, billing card). Each action detects first and only asks the human when it must.
// Flo: preflight > account: logged in? skip, else guide > login: run gcloud login, check a token works > billing: linked? done, else guide until an account shows up, then link
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: Outc per action
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const bill = @import("ap-bill.zig");

const Ctx = ctxm.Ctx;
const Outc = engi.Outc;

const CF = .{ .keyBill = "bill", .keyLogi = "logi_from", .valApp = "app", .valPre = "pre", .idenSign = "goog-sign", .idenLogi = "goog-logi" };

// a poll that never finishes by itself: the human types g
fn pollNeve(ctx: *Ctx) anyerror!bool {
    _ = ctx;
    return false;
}

// a poll that finishes when an open billing account appears
fn pollBill(ctx: *Ctx) anyerror!bool {
    const list = bill.openList(ctx.gcp, ctx.conf.apis.bill) catch return false;
    return list.len > 0;
}

// preflight: the one tool we need (login only), or the token variable
pub fn toolChec(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    if (!cfg.gcloMode()) {
        if (try ctx.auth.who() == null) return .{ .fail = .{ .what = "no access token", .why = "auth.mode is env but the variable is empty", .fix = "set the env var named in auth.toke_envz, then re-run" } };
        return .{ .done = "token comes from the env var" };
    }
    if (!ctx.tool.have(cfg.tool.gclo)) return .{ .fail = .{ .what = "gcloud not found", .why = "it is needed once, for the login code", .fix = "install the Google Cloud CLI, open a new terminal, re-run" } };
    ctx.say("   os: {s}\n", .{osyz.nameOsys()});
    return .{ .done = "gcloud found" };
}

// hand job 1: a Google account (no way to detect it before the login)
pub fn googSign(ctx: *Ctx) anyerror!Outc {
    if (!ctx.conf.gcloMode()) return .{ .skip = "token comes from the env var" };
    if (ctx.handSeen(CF.idenSign)) return .{ .done = "you confirmed a Google account" };
    if (try ctx.auth.who()) |acct| return .{ .skip = try std.fmt.allocPrint(ctx.a, "already logged in as {s}", .{acct}) };
    return .{ .wait = .{ .urlz = ctx.conf.guid.sign, .lines = .{ "1. Sign in, or create a normal personal Google account.", "2. No bots, no shared logins.", "3. Then type g here." }, .poll = pollNeve } };
}

// hand job 2: approve the login code; then prove a token works
pub fn googLogi(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    var acct = try ctx.auth.who();
    if (acct == null) {
        if (!cfg.gcloMode()) return .{ .fail = .{ .what = "no access token", .why = "the env var is empty", .fix = "set the env var named in auth.toke_envz" } };
        ctx.say("   gcloud will show a link. Open it, approve, paste the code back here.\n", .{});
        ctx.handled += 1;
        if (!try ctx.auth.login()) return .{ .fail = .{ .what = "gcloud login did not finish", .why = "the login was cancelled or failed", .fix = "re-run; it asks for the code again" } };
        acct = try ctx.auth.who();
        if (acct == null) return .{ .fail = .{ .what = "no logged-in account after login", .why = "gcloud reports no active account", .fix = "run gcloud auth list, then re-run" } };
        try ctx.st.putz(CF.keyLogi, CF.valApp);
    } else if (ctx.st.valu(CF.keyLogi).len == 0) {
        try ctx.st.putz(CF.keyLogi, CF.valPre);
    }
    const rep = ctx.gcp.call(.GET, try std.fmt.allocPrint(ctx.a, "{s}/v3/projects:search?pageSize=1", .{cfg.apis.crmz}), null) catch |erro| return .{ .fail = .{ .what = "no usable access token", .why = @errorName(erro), .fix = "log in again: gcloud auth login --no-launch-browser" } };
    if (!rep.okay()) return .{ .fail = .{ .what = "Google refused the token", .why = rep.errText(), .fix = "log in again: gcloud auth login --no-launch-browser" } };
    return .{ .done = try std.fmt.allocPrint(ctx.a, "token works for {s}", .{acct.?}) };
}

// hand job 3: a billing card; then link the project
pub fn billLink(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const proj = ctx.projId();
    if (proj.len == 0) return .{ .fail = .{ .what = "no project yet", .why = "the project step has not run", .fix = "re-run from the start" } };
    if (try bill.linked(ctx.gcp, cfg.apis.bill, proj)) |acct| {
        try ctx.st.putz(CF.keyBill, acct);
        return .{ .done = try std.fmt.allocPrint(ctx.a, "billing is on (account {s})", .{acct}) };
    }
    const list = try bill.openList(ctx.gcp, cfg.apis.bill);
    if (list.len == 0) return .{ .wait = .{ .urlz = cfg.guid.bill, .lines = .{ "1. Add a payment card; start the billing account.", "2. Free tier needs a card on file; a budget alert is set later.", "3. Wait a few seconds, I detect it. Or type g." }, .poll = pollBill } };
    var pick: ?[]const u8 = null;
    if (cfg.budg.bill_acct.len != 0) {
        for (list) |item| if (std.mem.eql(u8, item.iden, cfg.budg.bill_acct)) {
            pick = item.iden;
        };
        if (pick == null) return .{ .fail = .{ .what = "billing account not found", .why = "budg.bill_acct is not one of your open accounts", .fix = "fix budg.bill_acct in 00-config.json" } };
    } else if (list.len == 1) {
        pick = list[0].iden;
    } else {
        return .{ .fail = .{ .what = "more than one open billing account", .why = "the app will not guess which one to charge", .fix = "set budg.bill_acct in 00-config.json to one of them" } };
    }
    try bill.link(ctx.gcp, cfg.apis.bill, proj, pick.?);
    if ((try bill.linked(ctx.gcp, cfg.apis.bill, proj)) == null) return .{ .fail = .{ .what = "billing link not confirmed", .why = "billingInfo still shows billing off", .fix = "wait a minute and re-run" } };
    try ctx.st.putz(CF.keyBill, pick.?);
    return .{ .done = try std.fmt.allocPrint(ctx.a, "linked billing account {s}", .{pick.?}) };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
