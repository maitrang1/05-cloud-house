// =====================================================================
// Des: Reads and writes the optional local passphrase file, and refuses to use it when other users could read it
// Flo: stat (owner-only?) > read > trim the line end > text | write .part with mode 0600 > rename
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, file path, passphrase
// Out: passphrase text | PassErro
// Run: not run directly - imported by bundle-flow.zig and root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");

const CF = .{ .file_maxz = 4096, .part = ".part", .mode = 0o600, .group_other = 0o077 };

pub const PassErro = error{ Missing, TooOpen, Unreadable, Empty, WriteFail, OutOfMemory };

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// POSIX: no group or other bits. Windows keeps the profile folder's own access list, so it passes ----
fn ownerOnly(st: std.Io.File.Stat) bool {
    if (comptime builtin.os.tag == .windows) return true;
    return st.permissions.toMode() & CF.group_other == 0;
}

pub fn read(io: std.Io, a: std.mem.Allocator, path: []const u8) PassErro![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch |e| return if (e == error.FileNotFound) error.Missing else error.Unreadable;
    if (!ownerOnly(st)) return error.TooOpen;
    const raw = cwd.readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch return error.Unreadable;
    const text = std.mem.trimEnd(u8, raw, "\r\n");
    if (text.len == 0) return error.Empty;
    return text;
}

pub fn write(io: std.Io, a: std.mem.Allocator, path: []const u8, pass: []const u8) PassErro!void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch return error.WriteFail;
    const part = std.mem.concat(a, u8, &.{ path, CF.part }) catch return error.OutOfMemory;
    {
        const f = cwd.createFile(io, part, if (comptime builtin.os.tag == .windows) .{} else .{ .permissions = .fromMode(CF.mode) }) catch return error.WriteFail;
        defer f.close(io);
        const line = std.mem.concat(a, u8, &.{ pass, "\n" }) catch return error.OutOfMemory;
        f.writePositionalAll(io, line, 0) catch return error.WriteFail;
    }
    cwd.rename(part, cwd, path, io) catch return error.WriteFail;
}

fn tmpPath(a: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return std.fs.path.join(a, &.{ buf[0..n], name });
}

test "write then read: the line end is trimmed, the file is owner-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(a, io, &tmp, "k/vault.pass");
    try std.testing.expect(!exists(io, path));
    try std.testing.expectError(error.Missing, read(io, a, path));
    try write(io, a, path, "pass with spaces  ");
    try std.testing.expect(exists(io, path));
    try std.testing.expectEqualStrings("pass with spaces  ", try read(io, a, path));
    if (builtin.os.tag != .windows) {
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    }
}

test "a file others can read is refused; an empty file is refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const open = try tmpPath(a, io, &tmp, "open.pass");
    {
        const f = try std.Io.Dir.cwd().createFile(io, open, .{ .permissions = .fromMode(0o644) });
        defer f.close(io);
        try f.writePositionalAll(io, "secret\n", 0);
    }
    // a umask can only remove bits: force the mode we want to test
    try std.Io.Dir.cwd().setFilePermissions(io, open, .fromMode(0o644), .{});
    try std.testing.expectError(error.TooOpen, read(io, a, open));
    const empty = try tmpPath(a, io, &tmp, "empty.pass");
    try write(io, a, empty, "");
    try std.testing.expectError(error.Empty, read(io, a, empty));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
