// =====================================================================
// Des: Runs the pretend Google Cloud as its own program, so the real ggc-run exe can be tried end to end on this machine with no real account. Prints the port and the token to use.
// Flo: start the mock on a free port > print the port and token > wait until the process is stopped
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: optional --bill-after N (billing shows up after N list calls)
// Out: stdout: port and token; serves until killed
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build && zig-out/bin/ggc-run-mock
// Exe: /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run/zig-out/bin/ggc-run-mock
// =====================================================================
const std = @import("std");
const mock = @import("te-mock.zig");

const CF = .{ .flagBill = "--bill-after", .sleepMs = 1000 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    const mk1 = try mock.Mock.star(io);
    var indx: usize = 1;
    while (indx + 1 < argv.len) : (indx += 1) {
        if (std.mem.eql(u8, argv[indx], CF.flagBill)) mk1.billAfter = std.fmt.parseInt(u32, argv[indx + 1], 10) catch 0;
    }
    var buf: [1024]u8 = undefined;
    var writ = std.Io.File.stdout().writerStreaming(io, &buf);
    try writ.interface.print("mock port {d}\ntoken {s}\n", .{ mk1.port, mock.toke });
    try writ.interface.flush();
    while (true) std.Io.sleep(io, .fromMilliseconds(CF.sleepMs), .awake) catch return;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
