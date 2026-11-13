// =====================================================================
// Des: The one thin place for things that differ per operating system - opening a web page, filling the clipboard, typing a hidden value, reading a typed line
// Flo: pick the tool for this OS at compile time > spawn it or switch the terminal echo > hand back a plain yes/no or the typed text
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, url or text ; nothing else in the app may branch on the OS
// Out: bool for browser / clipboard ; typed line (no newline) or null at end of input
// Run: not run directly - imported by app-ctx.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const out = @import("out-text.zig");

const OS = builtin.os.tag;
const CF = .{ .line_size = 8192, .osc5_maxz = 4096, .echo_flag = 0x0004, .tool_maxz = 8 };

// clipboard tools per OS, first one that starts wins ----
const CLIP_LINU = [_][]const []const u8{ &.{"wl-copy"}, &.{ "xclip", "-selection", "clipboard" }, &.{ "xsel", "--clipboard", "--input" } };
const CLIP_MACO = [_][]const []const u8{&.{"pbcopy"}};
const CLIP_WIND = [_][]const []const u8{&.{"clip"}};

extern "kernel32" fn GetConsoleMode(handle: std.os.windows.HANDLE, mode: *u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(handle: std.os.windows.HANDLE, mode: u32) callconv(.winapi) c_int;

pub fn osName() []const u8 {
    return @tagName(OS);
}

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
    return std.mem.trim(u8, raw, " \r\t");
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

fn spawnQuiet(io: std.Io, argv: []const []const u8, feed: ?[]const u8, stay: bool) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = if (feed != null) .pipe else .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    var okay = true;
    if (feed) |text| {
        okay = if (child.stdin.?.writeStreamingAll(io, text)) true else |_| false;
        child.stdin.?.close(io);
        child.stdin = null;
    }
    // a real page opener may stay alive with the browser: never wait on it ----
    if (!stay) return okay;
    const term = child.wait(io) catch return false;
    return okay and term == .exited and term.exited == 0;
}

fn withArg(buf: [][]const u8, tool: []const []const u8, arg: []const u8) ?[]const []const u8 {
    if (tool.len + 1 > buf.len) return null;
    @memcpy(buf[0..tool.len], tool);
    buf[tool.len] = arg;
    return buf[0 .. tool.len + 1];
}

// `tool` replaces the OS opener (tests, odd desktops): it gets the URL as its last argument ----
pub fn browOpen(io: std.Io, url: []const u8, tool: []const []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://127.0.0.1:")) return false;
    if (tool.len > 0) {
        var buf: [CF.tool_maxz][]const u8 = undefined;
        return spawnQuiet(io, withArg(&buf, tool, url) orelse return false, null, true);
    }
    const argv: []const []const u8 = switch (OS) {
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    return spawnQuiet(io, argv, null, false);
}

// terminal clipboard escape: works over SSH and in most modern terminals ----
fn osc5Copy(io: std.Io, text: []const u8) bool {
    if (text.len > CF.osc5_maxz or !(std.Io.File.stderr().isTty(io) catch false)) return false;
    var enc: [std.base64.standard.Encoder.calcSize(CF.osc5_maxz)]u8 = undefined;
    defer std.crypto.secureZero(u8, &enc);
    const quiet = out.mute;
    out.mute = false;
    defer out.mute = quiet;
    out.err(io, "\x1b]52;c;{s}\x07", .{std.base64.standard.Encoder.encode(&enc, text)});
    return true;
}

// `tool` replaces the OS clipboard tool: it gets the text on its stdin ----
pub fn clipCopy(io: std.Io, text: []const u8, osc5: bool, tool: []const []const u8) bool {
    if (tool.len > 0) return spawnQuiet(io, tool, text, true);
    const tools: []const []const []const u8 = switch (OS) {
        .windows => &CLIP_WIND,
        .macos => &CLIP_MACO,
        else => &CLIP_LINU,
    };
    for (tools) |argv| if (spawnQuiet(io, argv, text, true)) return true;
    return osc5 and osc5Copy(io, text);
}

test "home comes from the right variable; an empty value is no home; only web links open" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(homePath(&env) == null);
    try env.put(if (OS == .windows) "USERPROFILE" else "HOME", "");
    try std.testing.expect(homePath(&env) == null);
    try env.put(if (OS == .windows) "USERPROFILE" else "HOME", "/h/me");
    try std.testing.expectEqualStrings("/h/me", homePath(&env).?);
    try std.testing.expect(!browOpen(std.testing.io, "file:///etc/passwd", &.{}));
    try std.testing.expect(!browOpen(std.testing.io, "http://example.com", &.{}));
    try std.testing.expect(osName().len > 0);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
