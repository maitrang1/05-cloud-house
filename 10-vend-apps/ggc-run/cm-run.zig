// =====================================================================
// Des: The run command: without --go it only prints the plan and the hand-job count (dry-run); with --go it runs every step and prints the report.
// Flo: no --go: plan, stop > --go: engine over the step table > report > exit code
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, live flag
// Out: exit code 0 ok, 1 failed, 2 usage, 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const tabl = @import("ve-table.zig");

pub fn run(ctx: *ctxm.Ctx, live: bool) !u8 {
    if (!live) {
        engi.plan(ctx);
        ctx.say("dry-run: nothing was changed. Pass --go to run for real.\n", .{});
        return 0;
    }
    const rep = try engi.run(ctx, &tabl.table);
    engi.report(ctx, rep);
    return rep.code;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
