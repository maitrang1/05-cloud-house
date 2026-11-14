// =====================================================================
// Des: Remembers which bundle this device last absorbed (its sha256), so `ship` can refuse to overwrite a newer bundle another device shipped
// Flo: read a one-line JSON file (missing = never synced) | write it owner-only, .part then rename
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, state file path, 64-character hex of the bundle file
// Out: hex text or null | StateErro
// Run: not run directly - imported by ship-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const apply = @import("bundle-apply.zig");

const CF = .{ .file_maxz = 4096, .hex_len = 64, .mode = 0o600 };

pub const StateErro = error{ Unreadable, BadFormat, WriteFail, OutOfMemory };

const Doc = struct { applied: []const u8 = "" };

pub fn hexOkay(h: []const u8) bool {
    if (h.len != CF.hex_len) return false;
    for (h) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

// null when the device never synced (no file) ----
pub fn read(io: std.Io, a: std.mem.Allocator, path: []const u8) StateErro!?[]const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| return if (e == error.FileNotFound) null else error.Unreadable;
    const doc = std.json.parseFromSliceLeaky(Doc, a, raw, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch return error.BadFormat;
    if (doc.applied.len == 0) return null;
    if (!hexOkay(doc.applied)) return error.BadFormat;
    return doc.applied;
}

pub fn write(io: std.Io, a: std.mem.Allocator, path: []const u8, hex: []const u8) StateErro!void {
    if (!hexOkay(hex)) return error.BadFormat;
    const text = std.fmt.allocPrint(a, "{{\"applied\":\"{s}\"}}\n", .{hex}) catch return error.OutOfMemory;
    apply.writeOwner(io, path, text, CF.mode, a) catch return error.WriteFail;
}

test "missing file means never synced; write then read; a damaged file is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(a, &.{ root, "d", "state.json" });
    try std.testing.expect((try read(io, a, path)) == null);
    const h = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try write(io, a, path, h);
    try std.testing.expectEqualStrings(h, (try read(io, a, path)).?);
    try std.testing.expectError(error.BadFormat, write(io, a, path, "short"));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"applied\":\"nothex\"}" });
    try std.testing.expectError(error.BadFormat, read(io, a, path));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"x\":1}" });
    try std.testing.expectError(error.BadFormat, read(io, a, path));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
