// =====================================================================
// Des: The one thin place for things that differ per operating system - the home folder and typing a hidden passphrase
// Flo: read the home variable of this OS > switch terminal echo off > read one line > echo back on
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, environment map
// Out: home path or null ; typed line (no newline) or null at end of input
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const out = @import("out-text.zig");

const OS = builtin.os.tag;
const CF = .{ .line_size = 8192, .echo_flag = 0x0004 };

extern "kernel32" fn GetConsoleMode(handle: std.os.windows.HANDLE, mode: *u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(handle: std.os.windows.HANDLE, mode: u32) callconv(.winapi) c_int;

pub fn homePath(env: *const std.process.Environ.Map) ?[]const u8 {
    const keyz = if (comptime OS == .windows) "USERPROFILE" else "HOME";
    const v = env.get(keyz) orelse return null;
    return if (v.len == 0) null else v;
}

var line_buf: [CF.line_size]u8 = undefined;
var line_rd: ?std.Io.File.Reader = null;

// one shared reader: a second one would lose the bytes the first had buffered ----
pub fn lineRead(io: std.Io) ?[]const u8 {
    if (line_rd == null) line_rd = std.Io.File.stdin().readerStreaming(io, &line_buf);
    const raw = (line_rd.?.interface.takeDelimiter('\n') catch return null) orelse return null;
    return std.mem.trim(u8, raw, "\r\n");
}

pub fn isTerm(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn echoSet(on: bool) void {
    const file = std.Io.File.stdin();
    if (comptime OS == .windows) {
        var mode: u32 = 0;
        if (GetConsoleMode(file.handle, &mode) == 0) return;
        _ = SetConsoleMode(file.handle, if (on) mode | CF.echo_flag else mode & ~@as(u32, CF.echo_flag));
    } else {
        var t = std.posix.tcgetattr(file.handle) catch return;
        t.lflag.ECHO = on;
        std.posix.tcsetattr(file.handle, .NOW, t) catch return;
    }
}

// typed hidden on a terminal; a pipe (tests, scripts) is read as it is ----
pub fn hideRead(io: std.Io) ?[]const u8 {
    const term = isTerm(io);
    if (term) echoSet(false);
    defer if (term) {
        echoSet(true);
        out.err(io, "\n", .{});
    };
    return lineRead(io);
}

test "home comes from the right variable; an empty value is no home" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(homePath(&env) == null);
    try env.put(if (OS == .windows) "USERPROFILE" else "HOME", "");
    try std.testing.expect(homePath(&env) == null);
    try env.put(if (OS == .windows) "USERPROFILE" else "HOME", "/h/me");
    try std.testing.expectEqualStrings("/h/me", homePath(&env).?);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
