// =====================================================================
// Des: The one table that maps a step's action name in the step data to the function that does it.
// Flo: name in df-steps.json > function pointer
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: table of Entry
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const engi = @import("co-engine.zig");
const guid = @import("ve-guid.zig");
const setup = @import("ve-setup.zig");
const ship = @import("ve-ship.zig");

pub const table = [_]engi.Entry{
    .{ .acts = "tool.chec", .run = guid.toolChec },
    .{ .acts = "goog.sign", .run = guid.googSign },
    .{ .acts = "goog.logi", .run = guid.googLogi },
    .{ .acts = "proj.make", .run = setup.projMake },
    .{ .acts = "bill.link", .run = guid.billLink },
    .{ .acts = "apis.enab", .run = setup.apisEnab },
    .{ .acts = "budg.make", .run = setup.budgMake },
    .{ .acts = "sacc.make", .run = setup.saccMake },
    .{ .acts = "imag.path", .run = ship.imagPath },
    .{ .acts = "serv.depl", .run = ship.servDepl },
    .{ .acts = "tick.wire", .run = ship.tickWire },
    .{ .acts = "fina.chec", .run = ship.finaChec },
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
