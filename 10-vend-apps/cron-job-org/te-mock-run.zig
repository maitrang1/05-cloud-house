// =====================================================================
// Des: Runs the pretend cron-job.org as a program, for the guide run and manual checks. Prints its port, the fake API key and the tick URL, then waits.
// Flo: start the mock on a spare port > print port, key, tick url > sleep until killed
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: three lines on stdout
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build && zig-out/bin/cronjoborg-mock
// Exe: /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org/zig-out/bin/cronjoborg-mock
// =====================================================================
const std = @import("std");
const mock = @import("te-mock.zig");

const CF = .{ .sleepMs = 1000 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const mk1 = try mock.Mock.star(io);
    const urlz = try mk1.tickUrl(init.arena.allocator());
    var buf: [1024]u8 = undefined;
    var writ = std.Io.File.stdout().writerStreaming(io, &buf);
    try writ.interface.print("mock port {d}\nkey {s}\ntick {s}\n", .{ mk1.port, mock.keyz, urlz });
    try writ.interface.flush();
    while (true) std.Io.sleep(io, .fromMilliseconds(CF.sleepMs), .awake) catch return;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
