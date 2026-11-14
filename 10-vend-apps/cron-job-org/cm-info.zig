// =====================================================================
// Des: Read-only commands: plan (steps and marks), status (the job as the vendor sees it, exit 3 when it is off or failing), usage (today's request count, no call).
// Flo: plan: print rows > status: key from vault > GET the job > print > exit code > usage: read the counter
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: text on stdout, exit code
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const cron = @import("ap-cron.zig");
const date = @import("co-date.zig");
const fail = @import("ve-fail.zig");

const CF = .{ .exitOkay = 0, .exitFail = 1, .exitWarn = 3, .keyJob = "jobid", .keyLast = "last_tick" };

pub fn plan(ctx: *ctxm.Ctx) u8 {
    engi.plan(ctx);
    return CF.exitOkay;
}

// time text, "-" for 0
fn when(ctx: *ctxm.Ctx, secs: i64) []const u8 {
    if (secs == 0) return "-";
    return date.rfc3339(ctx.a, secs) catch "?";
}

// the job as the vendor sees it; exit 3 when disabled or the last run failed
pub fn status(ctx: *ctxm.Ctx) !u8 {
    const iden = ctx.st.valu(CF.keyJob);
    if (iden.len == 0) {
        ctx.say("no tick job yet: run first\n", .{});
        return CF.exitFail;
    }
    const have = ctx.keyLoad() catch |erro| return fail.vaulExit(ctx, erro);
    if (!have) {
        ctx.say("no API key in the vault: run first\n", .{});
        return CF.exitFail;
    }
    const rep = ctx.cron.get(iden) catch |erro| {
        if (erro == error.QuotaDay) {
            ctx.say("the daily request limit is used up; try tomorrow (UTC)\n", .{});
            return CF.exitFail;
        }
        return erro;
    };
    if (!rep.okay()) {
        const outc = try fail.replFail(ctx, rep, "read the tick job");
        ctx.say("failed: {s}\nwhy: {s}\nfix: {s}\n", .{ outc.fail.what, outc.fail.why, outc.fail.fix });
        return CF.exitFail;
    }
    const det = cron.detail(rep);
    const enab = cron.obj(det, "enabled") == .bool and cron.obj(det, "enabled").bool;
    const lstat = cron.int(cron.obj(det, "lastStatus"));
    const lexe = cron.int(cron.obj(det, "lastExecution"));
    ctx.say("job        {s}\ntitle      {s}\nurl        {s}\nenabled    {s}\nlast run   {s} (status {d}, {d} ms)\nnext run   {s}\n", .{ iden, cron.str(cron.obj(det, "title")), cron.str(cron.obj(det, "url")), if (enab) "yes" else "NO", when(ctx, lexe), lstat, cron.int(cron.obj(det, "lastDuration")), when(ctx, cron.int(cron.obj(det, "nextExecution"))) });
    ctx.quotaShow();
    const sick = !enab or (lexe != 0 and lstat != cron.status_okay);
    if (sick) ctx.say("WARNING: the job is {s}\n", .{if (!enab) "disabled (the vendor disables a job after 25 failures in a row)" else "failing"});
    return if (sick) CF.exitWarn else CF.exitOkay;
}

// exit 3 when today's request count is at or over limi.warn percent (no vendor call)
pub fn usage(ctx: *ctxm.Ctx) u8 {
    ctx.quotaShow();
    if (ctx.quotaWarn()) {
        ctx.say("WARNING: at or over the warn level ({d}%)\n", .{ctx.conf.limi.warn});
        return CF.exitWarn;
    }
    return CF.exitOkay;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
