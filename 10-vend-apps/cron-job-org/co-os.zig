// =====================================================================
// Des: The one thin layer for things that differ per operating system: opening a web page, filling the clipboard, finding the home folder, printing lines.
// Flo: ask > pick the branch for this OS > call the system tool > report ok or not
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: a url, a text, or an on/off flag
// Out: true/false, or the home folder path
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");

const CF = .{ .openLinu = "xdg-open", .openMacz = "open", .openWind = "rundll32", .openWindArgz = "url.dll,FileProtocolHandler", .clipMacz = "pbcopy", .clipWind = "clip", .clipWayl = "wl-copy", .clipXorg = "xclip", .toolSecs = 10, .echoBitz = 0x4, .stdiHand = 0xFFFFFFF6 };

const isWind = builtin.os.tag == .windows;

// Win32 console calls, only linked on Windows
const wind = if (isWind) struct {
    extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(h: ?*anyopaque, m: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(h: ?*anyopaque, m: u32) callconv(.winapi) c_int;
} else struct {};

// name of this OS for the preflight line
pub fn nameOsys() []const u8 {
    return @tagName(builtin.os.tag);
}

// the process environment as a map (the one per-OS branch)
pub fn environ(gpa: std.mem.Allocator) !std.process.Environ.Map {
    const envr: std.process.Environ = if (builtin.os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return envr.createMap(gpa);
}

// home folder from the environment
pub fn homeFind(envz: *const std.process.Environ.Map) ?[]const u8 {
    return envz.get("HOME") orelse envz.get("USERPROFILE");
}

// open a page in the default browser
pub fn urlzOpen(io: std.Io, gpa: std.mem.Allocator, urlz: []const u8) bool {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ CF.openWind, CF.openWindArgz, urlz },
        .macos => &.{ CF.openMacz, urlz },
        else => &.{ CF.openLinu, urlz },
    };
    const resu = std.process.run(gpa, io, .{ .argv = argv, .timeout = .{ .duration = .{ .raw = .fromSeconds(CF.toolSecs), .clock = .awake } } }) catch return false;
    return resu.term == .exited and resu.term.exited == 0;
}

// pipe text into one clipboard tool
fn clipPipe(io: std.Io, argv: []const []const u8, text: []const u8) bool {
    var chil = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const sent = if (chil.stdin.?.writeStreamingAll(io, text)) true else |_| false;
    chil.stdin.?.close(io);
    chil.stdin = null;
    const term = chil.wait(io) catch return false;
    return sent and term == .exited and term.exited == 0;
}

// put text on the clipboard, first tool that works
pub fn clipSetz(io: std.Io, text: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows => clipPipe(io, &.{CF.clipWind}, text),
        .macos => clipPipe(io, &.{CF.clipMacz}, text),
        else => clipPipe(io, &.{CF.clipWayl}, text) or clipPipe(io, &.{ CF.clipXorg, "-selection", "clipboard" }, text),
    };
}

// turn terminal echo on or off (hidden typing)
pub fn echoSetz(onzz: bool) bool {
    if (isWind) {
        const hand = wind.GetStdHandle(CF.stdiHand);
        var mode: u32 = 0;
        if (wind.GetConsoleMode(hand, &mode) == 0) return false;
        const next = if (onzz) mode | CF.echoBitz else mode & ~@as(u32, CF.echoBitz);
        return wind.SetConsoleMode(hand, next) != 0;
    } else {
        var term = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return false;
        term.lflag.ECHO = onzz;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, term) catch return false;
        return true;
    }
}

// user-facing line to stdout; a test build never touches real stdout —
// the build runner's own --listen=- protocol owns that fd during `zig build test`,
// and a raw write there corrupts its framing and deadlocks the test driver
pub fn outz(io: std.Io, comptime fmtz: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    var buff: [4096]u8 = undefined;
    var writ = std.Io.File.stdout().writerStreaming(io, &buff);
    writ.interface.print(fmtz, args) catch return;
    writ.interface.flush() catch return;
}

// error line to stderr; same test guard as outz
pub fn errz(comptime fmtz: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmtz, args);
}

test "os name and home lookup" {
    try std.testing.expect(nameOsys().len > 0);
    var mapz = std.process.Environ.Map.init(std.testing.allocator);
    defer mapz.deinit();
    try std.testing.expect(homeFind(&mapz) == null);
    try mapz.put("USERPROFILE", "C:\\u");
    try std.testing.expectEqualStrings("C:\\u", homeFind(&mapz).?);
    try mapz.put("HOME", "/h");
    try std.testing.expectEqualStrings("/h", homeFind(&mapz).?);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
