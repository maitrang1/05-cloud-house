// =====================================================================
// Des: The run command: without --go it only prints the plan and the hand-job count (dry-run, the vault stays closed); with --go it runs every step and prints the report.
// Flo: no --go: plan, stop > --go: engine over the step table > report > exit code (3 when the day's request count is at the warn level)
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, live flag
// Out: exit code 0 ok, 1 failed, 2 usage, 3 quota warn, 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const tabl = @import("ve-table.zig");

const CF = .{ .exitWarn = 3 };

pub fn run(ctx: *ctxm.Ctx, live: bool) !u8 {
    if (!live) {
        engi.plan(ctx);
        ctx.say("dry-run: nothing was changed, the vault stayed closed. Pass --go to run for real.\n", .{});
        return 0;
    }
    const rep = try engi.run(ctx, &tabl.table);
    engi.report(ctx, rep);
    if (rep.code == 0 and ctx.quotaWarn()) return CF.exitWarn;
    return rep.code;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
