// =====================================================================
// Des: Puts bundle files back on disk: compares with what is there, saves a different local file to the trash first, writes owner-only, never deletes
// Flo: plan (new / same / differs per file) > for differs copy the old file to the trash folder > write .part > rename over the target
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: repo folder, items, trash folder, time, file mode
// Out: Row list (plan) | Counts (apply) | ApplyErro
// Run: not run directly - imported by bundle-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const arc = @import("bundle-archive.zig");
const gm = @import("glob-match.zig");

const CF = .{ .old_maxz = 256 * 1024 * 1024, .part = ".part" };

pub const State = enum { new, same, differs };
pub const Row = struct { rel: []const u8, state: State, seed: bool = false };
pub const Counts = struct { written: u32 = 0, same: u32 = 0, replaced: u32 = 0, kept: u32 = 0 };
pub const ApplyErro = error{ WriteFail, UnsafePath, LinkInTheWay, OutOfMemory };

// a seed-only file (a session or a token a program refreshes by itself) is written when it is missing here and never compared or replaced after that ----
// `reseed`: seed-only files are compared and replaced like any other file ----
pub fn plan(io: std.Io, a: std.mem.Allocator, repo: []const u8, items: []const arc.Item, seed_only: []const []const u8, reseed: bool) ApplyErro![]Row {
    const cwd = std.Io.Dir.cwd();
    const rows = try a.alloc(Row, items.len);
    for (items, rows) |it, *row| {
        if (!arc.safePath(it.rel)) return error.UnsafePath;
        const path = std.fs.path.join(a, &.{ repo, it.rel }) catch return error.OutOfMemory;
        row.rel = it.rel;
        row.seed = gm.hitAny(seed_only, it.rel);
        row.state = blk: {
            cwd.access(io, path, .{}) catch break :blk .new;
            if (row.seed and !reseed) break :blk .same;
            const old = cwd.readFileAlloc(io, path, a, .limited(it.data.len + 1)) catch break :blk .differs;
            break :blk if (std.mem.eql(u8, old, it.data)) .same else .differs;
        };
    }
    return rows;
}

// yyMMdd_HHmmss from epoch seconds: the folder name of one trash batch ----
pub fn stampOf(a: std.mem.Allocator, secs: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const ymd = es.getEpochDay().calculateYearDay();
    const md = ymd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>2}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{ @as(u32, ymd.year) % 100, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

// owner-only on POSIX; Windows keeps the profile folder's own access list ----
pub fn writeOwner(io: std.Io, path: []const u8, data: []const u8, mode: u32, a: std.mem.Allocator) ApplyErro!void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch return error.WriteFail;
    const part = std.mem.concat(a, u8, &.{ path, CF.part }) catch return error.OutOfMemory;
    {
        const f = cwd.createFile(io, part, if (comptime builtin.os.tag == .windows) .{} else .{ .permissions = .fromMode(@intCast(mode)) }) catch return error.WriteFail;
        defer f.close(io);
        f.writePositionalAll(io, data, 0) catch return error.WriteFail;
    }
    cwd.rename(part, cwd, path, io) catch return error.WriteFail;
}

pub fn apply(io: std.Io, a: std.mem.Allocator, repo: []const u8, items: []const arc.Item, rows: []const Row, trash_root: []const u8, now_secs: i64, file_mode: u32, replace: bool, reseed: bool) ApplyErro!Counts {
    const cwd = std.Io.Dir.cwd();
    var c: Counts = .{};
    const batch = std.fs.path.join(a, &.{ trash_root, stampOf(a, now_secs) catch return error.OutOfMemory }) catch return error.OutOfMemory;
    for (items, rows) |it, row| {
        if (row.state == .same) {
            c.same += 1;
            continue;
        }
        // a local file that differs stays as it is unless the caller asked to replace it ----
        if (row.state == .differs and !(replace or (reseed and row.seed))) {
            c.kept += 1;
            continue;
        }
        const path = std.fs.path.join(a, &.{ repo, it.rel }) catch return error.OutOfMemory;
        if (row.state == .differs) {
            // a link in the way could send the write outside the repo: refuse ----
            const st = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch return error.WriteFail;
            if (st.kind != .file) return error.LinkInTheWay;
            const old = cwd.readFileAlloc(io, path, a, .limited(CF.old_maxz)) catch return error.WriteFail;
            const kept = std.fs.path.join(a, &.{ batch, it.rel }) catch return error.OutOfMemory;
            try writeOwner(io, kept, old, file_mode, a);
            c.replaced += 1;
        } else c.written += 1;
        try writeOwner(io, path, it.data, file_mode, a);
    }
    return c;
}

test "plan finds new, same and differs; apply saves the old file first and never loses it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = try a.dupe(u8, buf[0..n]);
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    const trash = try std.fs.path.join(a, &.{ root, "trash" });
    const items = [_]arc.Item{ .{ .rel = "x/.secrets/a.json", .data = "NEW-A" }, .{ .rel = "x/.secrets/b.json", .data = "BBB" }, .{ .rel = "c.txt", .data = "CCC" } };
    var rows = try plan(io, a, repo, &items, &.{}, false);
    for (rows) |r| try std.testing.expectEqual(State.new, r.state);
    var cnt = try apply(io, a, repo, &items, rows, trash, 1_800_000_000, 0o600, true, false);
    try std.testing.expectEqual(@as(u32, 3), cnt.written);
    rows = try plan(io, a, repo, &items, &.{}, false);
    for (rows) |r| try std.testing.expectEqual(State.same, r.state);
    // a local file now differs
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ repo, "x/.secrets/a.json" }), .data = "LOCAL-EDIT" });
    rows = try plan(io, a, repo, &items, &.{}, false);
    try std.testing.expectEqual(State.differs, rows[0].state);
    try std.testing.expectEqual(State.same, rows[1].state);
    cnt = try apply(io, a, repo, &items, rows, trash, 1_800_000_000, 0o600, true, false);
    try std.testing.expectEqual(@as(u32, 1), cnt.replaced);
    try std.testing.expectEqual(@as(u32, 2), cnt.same);
    const now_a = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ repo, "x/.secrets/a.json" }), a, .limited(100));
    try std.testing.expectEqualStrings("NEW-A", now_a);
    const stamp = try stampOf(a, 1_800_000_000);
    const kept = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ trash, stamp, "x/.secrets/a.json" }), a, .limited(100));
    try std.testing.expectEqualStrings("LOCAL-EDIT", kept);
    // keep mode: a differing local file is left alone and counted
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ repo, "c.txt" }), .data = "MY-EDIT" });
    rows = try plan(io, a, repo, &items, &.{}, false);
    cnt = try apply(io, a, repo, &items, rows, trash, 1_800_000_001, 0o600, false, false);
    try std.testing.expectEqual(@as(u32, 1), cnt.kept);
    try std.testing.expectEqual(@as(u32, 0), cnt.replaced);
    const mine = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ repo, "c.txt" }), a, .limited(100));
    try std.testing.expectEqualStrings("MY-EDIT", mine);
}

test "a seed-only file is written when missing and left alone when present, even if it differs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    const items = [_]arc.Item{ .{ .rel = "x/gg-token.json", .data = "T-OLD" }, .{ .rel = "x/key.json", .data = "KEY" } };
    const seed = [_][]const u8{"*token.json"};
    var rows = try plan(io, a, repo, &items, &seed, false);
    try std.testing.expectEqual(State.new, rows[0].state);
    _ = try apply(io, a, repo, &items, rows, root, 1_800_000_000, 0o600, true, false);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ repo, "x/gg-token.json" }), .data = "T-REFRESHED" });
    rows = try plan(io, a, repo, &items, &seed, false);
    try std.testing.expectEqual(State.same, rows[0].state);
    _ = try apply(io, a, repo, &items, rows, root, 1_800_000_000, 0o600, true, false);
    try std.testing.expectEqualStrings("T-REFRESHED", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ repo, "x/gg-token.json" }), a, .limited(100)));
}

test "reseed compares and replaces seed-only files too, with the old copy in the trash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    const trash = try std.fs.path.join(a, &.{ root, "trash" });
    const items = [_]arc.Item{.{ .rel = "x/gg-token.json", .data = "T-BUNDLE" }};
    const seed = [_][]const u8{"*token.json"};
    _ = try apply(io, a, repo, &items, try plan(io, a, repo, &items, &seed, false), trash, 1_800_000_000, 0o600, false, false);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ repo, "x/gg-token.json" }), .data = "T-MINE" });
    // without reseed the file is "same" and untouched
    var rows = try plan(io, a, repo, &items, &seed, false);
    try std.testing.expectEqual(State.same, rows[0].state);
    // with reseed it differs: kept unless replace or reseed-on-a-seed-file; reseed takes it
    rows = try plan(io, a, repo, &items, &seed, true);
    try std.testing.expectEqual(State.differs, rows[0].state);
    try std.testing.expect(rows[0].seed);
    var cnt = try apply(io, a, repo, &items, rows, trash, 1_800_000_000, 0o600, false, false);
    try std.testing.expectEqual(@as(u32, 1), cnt.kept);
    cnt = try apply(io, a, repo, &items, rows, trash, 1_800_000_000, 0o600, false, true);
    try std.testing.expectEqual(@as(u32, 1), cnt.replaced);
    try std.testing.expectEqualStrings("T-BUNDLE", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ repo, "x/gg-token.json" }), a, .limited(100)));
    const old = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ trash, try stampOf(a, 1_800_000_000), "x/gg-token.json" }), a, .limited(100));
    try std.testing.expectEqualStrings("T-MINE", old);
}

test "a path that climbs out of the repo is refused before anything is written" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]arc.Item{.{ .rel = "../evil", .data = "x" }};
    try std.testing.expectError(error.UnsafePath, plan(std.testing.io, a, "/tmp/none", &bad, &.{}, false));
}

test "the trash batch name is yyMMdd_HHmmss" {
    const a = std.testing.allocator;
    const s = try stampOf(a, 0);
    defer a.free(s);
    try std.testing.expectEqualStrings("700101_000000", s);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
