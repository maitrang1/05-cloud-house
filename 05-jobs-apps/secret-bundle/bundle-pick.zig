// =====================================================================
// Des: Finds the secret files to put in the bundle, by the rules in config: named folders, named file patterns, with browser profiles, caches, big files and skip folders left out
// Flo: walk the repo (no symlinks) > skip folders by name or by marker file > keep files inside a picked folder or matching a pattern > size caps > sorted list
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: repo folder, Pick rules, the bundle's own repo path (never picked)
// Out: Picked (sorted items, skip counts, byte total) | PickErro
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const gm = @import("glob-match.zig");

const CF = .{ .kilo = 1024, .mega = 1024 * 1024 };

pub const Item = struct { rel: []const u8, data: []const u8 };
pub const Skips = struct { big: u32 = 0, profile: u32 = 0, glob: u32 = 0, other: u32 = 0 };
pub const Picked = struct { items: []Item, skips: Skips, bytes: u64 };
pub const PickErro = error{ TooMuch, NoRepo, OutOfMemory };

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

// a file is inside a picked folder when any folder name on its path is listed ----
fn inDirs(dirs: []const []const u8, rel: []const u8) bool {
    const dir = std.fs.path.dirname(rel) orelse return false;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |part| if (has(dirs, part)) return true;
    return false;
}

// a folder holding one of the marker files is a browser profile: its files are never picked ----
fn hasMarker(io: std.Io, a: std.mem.Allocator, repo: []const u8, rel: []const u8, markers: []const []const u8) bool {
    for (markers) |m| {
        const p = std.fs.path.join(a, &.{ repo, rel, m }) catch return false;
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| return true else |_| {}
    }
    return false;
}

fn byRel(_: void, x: Item, y: Item) bool {
    return std.mem.lessThan(u8, x.rel, y.rel);
}

pub fn collect(io: std.Io, a: std.mem.Allocator, repo: []const u8, pick: conf.Pick, own_rel: []const u8) PickErro!Picked {
    var skips: Skips = .{};
    var items: std.ArrayList(Item) = .empty;
    var bytes: u64 = 0;
    const cap: u64 = @as(u64, pick.file_maxz_kbyt) * CF.kilo;
    const total_cap: u64 = @as(u64, pick.total_maxz_mbyt) * CF.mega;
    var src = std.Io.Dir.cwd().openDir(io, repo, .{ .iterate = true, .follow_symlinks = false }) catch return error.NoRepo;
    defer src.close(io);
    var w = src.walkSelectively(a) catch return error.OutOfMemory;
    defer w.deinit();
    while (true) {
        const ent = (w.next(io) catch continue) orelse break;
        switch (ent.kind) {
            .directory => {
                if (has(pick.skip_dirs, ent.basename)) continue;
                if (hasMarker(io, a, repo, ent.path, pick.skip_markers)) {
                    skips.profile += 1;
                    continue;
                }
                w.enter(io, ent) catch continue;
            },
            .file => {
                const rel = try a.dupe(u8, ent.path);
                std.mem.replaceScalar(u8, rel, '\\', '/');
                if (std.mem.eql(u8, rel, own_rel)) continue;
                if (!inDirs(pick.dirs, rel) and !gm.hitAny(pick.files, rel)) continue;
                if (gm.hitAny(pick.skip, rel)) {
                    skips.glob += 1;
                    continue;
                }
                const st = ent.dir.statFile(io, ent.basename, .{ .follow_symlinks = false }) catch {
                    skips.other += 1;
                    continue;
                };
                if (st.size > cap) {
                    skips.big += 1;
                    continue;
                }
                bytes += st.size;
                if (bytes > total_cap) return error.TooMuch;
                const data = ent.dir.readFileAlloc(io, ent.basename, a, .limited(cap + 1)) catch {
                    skips.other += 1;
                    bytes -= st.size;
                    continue;
                };
                try items.append(a, .{ .rel = rel, .data = data });
            },
            else => {},
        }
    }
    std.mem.sort(Item, items.items, {}, byRel);
    return .{ .items = items.items, .skips = skips, .bytes = bytes };
}

fn put(dir: std.Io.Dir, io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

test "picks by folder name and pattern; leaves profiles, caches, big files, skip folders and the bundle itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, io, "app/.secrets/a.json", "AAA");
    try put(tmp.dir, io, "app/.secrets/deep/er/b.txt", "BBB");
    try put(tmp.dir, io, "app/gg-token.json", "TTT");
    try put(tmp.dir, io, "app/plain.txt", "no");
    try put(tmp.dir, io, "app/.secrets/me-profile/Local State", "{}");
    try put(tmp.dir, io, "app/.secrets/me-profile/Cache/x", "XXX");
    try put(tmp.dir, io, "app/.secrets/big.bin", "B" ** 2048);
    try put(tmp.dir, io, "zig-out/.secrets/z.json", "ZZZ");
    try put(tmp.dir, io, "app/.secrets/skipme.log", "LOG");
    try put(tmp.dir, io, "app/.secrets/uniq/own.enc", "OWN");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const repo = try a.dupe(u8, buf[0..n]);
    var rules: conf.Pick = .{};
    rules.file_maxz_kbyt = 1;
    rules.skip = &.{"*.log"};
    const got = try collect(io, a, repo, rules, "app/.secrets/uniq/own.enc");
    const want = [_][]const u8{ "app/.secrets/a.json", "app/.secrets/deep/er/b.txt", "app/gg-token.json" };
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g.rel);
    try std.testing.expectEqualStrings("AAA", got.items[0].data);
    try std.testing.expectEqual(@as(u32, 1), got.skips.profile);
    try std.testing.expectEqual(@as(u32, 1), got.skips.big);
    try std.testing.expectEqual(@as(u32, 1), got.skips.glob);
    try std.testing.expectEqual(@as(u64, 9), got.bytes);
}

test "a total over the cap is refused; a missing repo is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const blob = try a.alloc(u8, 700 * 1024);
    @memset(blob, 'A');
    try put(tmp.dir, io, "x/.secrets/a", blob);
    try put(tmp.dir, io, "x/.secrets/b", blob);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const repo = try a.dupe(u8, buf[0..n]);
    var rules: conf.Pick = .{};
    rules.total_maxz_mbyt = 1;
    rules.file_maxz_kbyt = 800;
    try std.testing.expectError(error.TooMuch, collect(io, a, repo, rules, "none"));
    rules.total_maxz_mbyt = 2;
    const ok = try collect(io, a, repo, rules, "none");
    try std.testing.expectEqual(@as(usize, 2), ok.items.len);
    try std.testing.expectError(error.NoRepo, collect(io, a, "/no/such/repo/anywhere", rules, "none"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
