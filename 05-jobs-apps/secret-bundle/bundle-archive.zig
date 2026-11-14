// =====================================================================
// Des: Packs the picked files into one block of bytes and unpacks it again, refusing any path that could leave the repo
// Flo: magic + count > per file: path length, path, size, bytes > decode checks every bound and every path before anything is written
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: items (relative path with '/', bytes) | the plain bytes of a bundle
// Out: encoded bytes | items | ArcErro
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const pick = @import("bundle-pick.zig");

pub const Item = pick.Item;
pub const MAGIC = "CHBA1";
const CF = .{ .path_maxz = 1024, .count_maxz = 100000 };

pub const ArcErro = error{ BadArchive, UnsafePath, OutOfMemory };

// a path from a bundle must stay inside the repo: relative, '/' only, no '.', '..', empty parts, drive letters or NUL ----
pub fn safePath(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > CF.path_maxz or rel[0] == '/') return false;
    if (std.mem.indexOfAny(u8, rel, "\\:\x00") != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn encode(a: std.mem.Allocator, items: []const Item) ArcErro![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, MAGIC);
    var n4: [4]u8 = undefined;
    std.mem.writeInt(u32, &n4, @intCast(items.len), .little);
    try out.appendSlice(a, &n4);
    for (items) |it| {
        if (!safePath(it.rel)) return error.UnsafePath;
        var n2: [2]u8 = undefined;
        std.mem.writeInt(u16, &n2, @intCast(it.rel.len), .little);
        try out.appendSlice(a, &n2);
        try out.appendSlice(a, it.rel);
        var n8: [8]u8 = undefined;
        std.mem.writeInt(u64, &n8, it.data.len, .little);
        try out.appendSlice(a, &n8);
        try out.appendSlice(a, it.data);
    }
    return out.toOwnedSlice(a);
}

// the returned items point into `plain`: keep it alive ----
pub fn decode(a: std.mem.Allocator, plain: []const u8) ArcErro![]Item {
    if (plain.len < MAGIC.len + 4 or !std.mem.startsWith(u8, plain, MAGIC)) return error.BadArchive;
    const count = std.mem.readInt(u32, plain[MAGIC.len..][0..4], .little);
    if (count > CF.count_maxz) return error.BadArchive;
    var at: usize = MAGIC.len + 4;
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(a);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (at + 2 > plain.len) return error.BadArchive;
        const plen = std.mem.readInt(u16, plain[at..][0..2], .little);
        at += 2;
        if (at + plen + 8 > plain.len) return error.BadArchive;
        const rel = plain[at .. at + plen];
        at += plen;
        const size = std.mem.readInt(u64, plain[at..][0..8], .little);
        at += 8;
        if (size > plain.len - at) return error.BadArchive;
        if (!safePath(rel)) return error.UnsafePath;
        if ((seen.getOrPut(a, rel) catch return error.OutOfMemory).found_existing) return error.BadArchive;
        try items.append(a, .{ .rel = rel, .data = plain[at .. at + @as(usize, @intCast(size))] });
        at += @as(usize, @intCast(size));
    }
    if (at != plain.len) return error.BadArchive;
    return items.toOwnedSlice(a);
}

test "round trip keeps names and bytes, also empty files and an empty list" {
    const a = std.testing.allocator;
    const items = [_]Item{ .{ .rel = "a/.secrets/x.json", .data = "{\"k\":1}" }, .{ .rel = "b", .data = "" } };
    const enc = try encode(a, &items);
    defer a.free(enc);
    const back = try decode(a, enc);
    defer a.free(back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("a/.secrets/x.json", back[0].rel);
    try std.testing.expectEqualStrings("{\"k\":1}", back[0].data);
    try std.testing.expectEqual(@as(usize, 0), back[1].data.len);
    const none = try encode(a, &.{});
    defer a.free(none);
    const zero = try decode(a, none);
    defer a.free(zero);
    try std.testing.expectEqual(@as(usize, 0), zero.len);
}

test "unsafe paths are refused both ways" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "/abs", "../up", "a/../b", "a//b", "./a", "a\\b", "c:x", "a/b/", "a\x00b" }) |bad| {
        try std.testing.expect(!safePath(bad));
        try std.testing.expectError(error.UnsafePath, encode(a, &.{.{ .rel = bad, .data = "x" }}));
    }
    try std.testing.expect(safePath("a/.secrets/x.json"));
    // a hand-made archive with a bad path is refused on decode
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try raw.appendSlice(a, MAGIC);
    try raw.appendSlice(a, &.{ 1, 0, 0, 0, 5, 0 });
    try raw.appendSlice(a, "../x\x00");
    try raw.appendSlice(a, &.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expectError(error.UnsafePath, decode(a, raw.items));
}

test "damaged archives are refused: short, wrong magic, size past the end, trailing bytes, duplicates" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadArchive, decode(a, "CHBA1"));
    try std.testing.expectError(error.BadArchive, decode(a, "XXXXX\x00\x00\x00\x00"));
    const enc = try encode(a, &.{.{ .rel = "a", .data = "hello" }});
    defer a.free(enc);
    try std.testing.expectError(error.BadArchive, decode(a, enc[0 .. enc.len - 1]));
    const longer = try std.mem.concat(a, u8, &.{ enc, "x" });
    defer a.free(longer);
    try std.testing.expectError(error.BadArchive, decode(a, longer));
    const twin = try encode(a, &.{ .{ .rel = "a", .data = "1" }, .{ .rel = "a", .data = "2" } });
    defer a.free(twin);
    try std.testing.expectError(error.BadArchive, decode(a, twin));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
