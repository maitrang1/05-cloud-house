// =====================================================================
// Des: Step actions for the start: preflight with the vault, then the two hand jobs (sign-up with email link, API key). Each action detects first and only asks the human when it must.
// Flo: preflight: open the vault > sign-up: key vaulted? skip, else guide > key: env var or hidden prompt > prove it with GET /jobs > vault it
// Inp: Ctx
// Out: Outc per action
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const fail = @import("ve-fail.zig");

const Ctx = ctxm.Ctx;
const Outc = engi.Outc;

const CF = .{ .idenSign = "acco-sign", .idenKeyz = "keyz-make", .exitHand = 4 };

// a poll that never finishes by itself: the human types g
fn pollNeve(ctx: *Ctx) anyerror!bool {
    _ = ctx;
    return false;
}

// the key from the env var, "" when unset
fn keyEnvz(ctx: *Ctx) []const u8 {
    return std.mem.trim(u8, ctx.env.get(ctx.conf.cron.keyz_envz) orelse "", " \r\n\t");
}

// preflight: data folder is ready (boot made it), the vault opens
pub fn prefChec(ctx: *Ctx) anyerror!Outc {
    const vlt = ctx.vault() catch |erro| {
        if (fail.vaulFail(erro)) |one| return .{ .fail = one };
        return erro;
    };
    ctx.say("   os: {s}\n", .{osyz.nameOsys()});
    return .{ .done = if (vlt.fresh) "new vault (it is written with the first secret)" else "vault opened" };
}

// hand job 1: sign up and click the email link (no way to detect it before the key exists)
pub fn accoSign(ctx: *Ctx) anyerror!Outc {
    if (try ctx.keyLoad()) return .{ .skip = "an API key is already vaulted: the account exists" };
    if (keyEnvz(ctx).len != 0) return .{ .skip = "the API key comes from the env var" };
    if (ctx.handSeen(CF.idenSign)) return .{ .done = "you confirmed the sign-up" };
    return .{ .wait = .{ .urlz = ctx.conf.guid.sign, .lines = .{ "1. Sign up with your email and a password.", "2. Open the email from cron-job.org and click the link.", "3. Then type g here." }, .poll = pollNeve } };
}

// hand job 2: the API key (env var, or hidden prompt after the guide); proven by GET /jobs, then vaulted
pub fn keyzMake(ctx: *Ctx) anyerror!Outc {
    if (try ctx.keyLoad()) return .{ .done = "the API key is in the vault" };
    var cand = keyEnvz(ctx);
    if (cand.len == 0) {
        if (!ctx.handSeen(CF.idenKeyz)) return .{ .wait = .{ .urlz = ctx.conf.guid.keyp, .lines = .{ "1. Settings > API: switch it on, create a key, copy it.", "2. Optional: lock the key to your IP (it then works only from here).", "3. Type g, then paste the key when asked. It stays hidden." }, .poll = pollNeve } };
        const typed = ctx.line.hidd(ctx.conf.cron.prom) orelse "";
        cand = std.mem.trim(u8, typed, " \r\n\t");
        if (cand.len == 0) {
            try ctx.handDrop(CF.idenKeyz);
            return .{ .fail = .{ .what = "no API key given", .why = "the prompt got an empty line", .fix = "run again and paste the key", .code = CF.exitHand } };
        }
    }
    ctx.cron.key = cand;
    ctx.au.hideAdd(ctx.a, cand);
    const rep = ctx.cron.list() catch |erro| {
        ctx.cron.key = "";
        return fail.callFail(ctx, erro, "check the API key");
    };
    if (!rep.okay()) return fail.replFail(ctx, rep, "check the API key");
    const vlt = try ctx.vault();
    try vlt.putz(ctx.conf.vaul.keya, cand);
    return .{ .done = "the key works; it is in the vault" };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
