// =====================================================================
// Des: Runs the pretend Render as its own program, so the built exe can be tested end to end from a shell. Test tool only, never shipped.
// Flo: read port > start the mock > print the port > sleep until killed
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv[1] = port (0 = pick one), argv[2] = cold pings before 200 (default 0)
// Out: stdout "mock listening <port>"
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build mock
// Exe: /home/mai_trang/05-cloud-house/10-vend-apps/render/zig-out/bin/render-mock
// =====================================================================
const std = @import("std");
const mock = @import("te-mock.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const port: u16 = if (args.next()) |text| std.fmt.parseInt(u16, text, 10) catch 0 else 0;
    const cold: u32 = if (args.next()) |text| std.fmt.parseInt(u32, text, 10) catch 0 else 0;
    const serv = try mock.Mock.star(io, port);
    serv.coldNeed = cold;
    var buff: [128]u8 = undefined;
    var writ = std.Io.File.stdout().writerStreaming(io, &buff);
    try writ.interface.print("mock listening {d}\n", .{serv.port});
    try writ.interface.flush();
    while (true) std.Io.sleep(io, .fromSeconds(3600), .awake) catch {};
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
