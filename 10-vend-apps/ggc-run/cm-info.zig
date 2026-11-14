// =====================================================================
// Des: Read-only commands: plan (steps and marks), status (what the app learned), usage (this month's free-quota use).
// Flo: plan: print rows > status: print state values > usage: ask Monitoring, print, exit 3 on warning
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: text on stdout, exit code
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const ship = @import("ve-ship.zig");

const CF = .{ .exitOkay = 0, .exitFail = 1, .exitWarn = 3, .keys = [_][]const u8{ "proj", "pnum", "bill", "sacc", "image", "uri", "logi_from" } };

pub fn plan(ctx: *ctxm.Ctx) u8 {
    engi.plan(ctx);
    return CF.exitOkay;
}

pub fn status(ctx: *ctxm.Ctx) u8 {
    for (CF.keys) |key| {
        const valu = ctx.st.valu(key);
        ctx.say("{s: <10} {s}\n", .{ key, if (valu.len == 0) "-" else valu });
    }
    return CF.exitOkay;
}

// exit 3 when any meter is at or over limi.warn percent
pub fn usage(ctx: *ctxm.Ctx) u8 {
    if (ctx.projId().len == 0) {
        ctx.say("no project yet: run first\n", .{});
        return CF.exitFail;
    }
    const warn = ship.usageShow(ctx) catch |erro| {
        ctx.say("usage: n/a ({s}); metrics can lag a few minutes\n", .{@errorName(erro)});
        return CF.exitFail;
    };
    return if (warn) CF.exitWarn else CF.exitOkay;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
