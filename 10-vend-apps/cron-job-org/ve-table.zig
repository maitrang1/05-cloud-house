// =====================================================================
// Des: The one table that maps a step's action name in the step data to the function that does it.
// Flo: name in df-steps.json > function pointer
// Inp: none
// Out: table of Entry
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const engi = @import("co-engine.zig");
const guid = @import("ve-guid.zig");
const job = @import("ve-job.zig");

pub const table = [_]engi.Entry{
    .{ .acts = "pref.chec", .run = guid.prefChec },
    .{ .acts = "acco.sign", .run = guid.accoSign },
    .{ .acts = "keyz.make", .run = guid.keyzMake },
    .{ .acts = "tick.reso", .run = job.tickReso },
    .{ .acts = "job.sync", .run = job.jobSync },
    .{ .acts = "job.veri", .run = job.jobVeri },
    .{ .acts = "fina.chec", .run = job.finaChec },
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
