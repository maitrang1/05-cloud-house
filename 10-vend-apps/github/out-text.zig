// =====================================================================
// Des: Prints results to the screen and problems to the error stream, and stays silent inside unit tests so the test runner never hangs
// Flo: format text > write to stdout or stderr > flush
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, format string, arguments
// Out: text on stdout (say) or stderr (err, fail)
// Run: not run directly - imported by every module that prints
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");

const CF = .{ .buff_size = 4096 };

// stdout is the test runner's own channel: never print under test ----
pub var mute: bool = builtin.is_test;

pub fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (mute) return;
    var buf: [CF.buff_size]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

pub fn err(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    if (mute) return;
    var buf: [CF.buff_size]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

// every error says what, why and the fix, one line each ----
pub fn fail(io: std.Io, what: []const u8, why: []const u8, fix: []const u8) void {
    err(io, "what: {s}\nwhy:  {s}\nfix:  {s}\n", .{ what, why, fix });
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
