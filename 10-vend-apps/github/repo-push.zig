// =====================================================================
// Des: One-way mirror: the working tree always wins. Copies allowlisted files into the repo folder (overwrite) and moves files that no longer exist at the source to the trash folder, never deleting
// Flo: walk source (skip folders) > must match allo > must not match deny > size cap > overwrite if different > walk the repo folder > move unseen files (not in keep) to the trash
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: source folder, repo folder, config push rules, live flag, clock
// Out: Report{ copied, same, denied, big, other, moved } - nothing is ever deleted
// Run: not run directly - imported by root-main.zig (`github push --from <dir> --root <dir> [--live]`)
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const scan = @import("secret-scan.zig");

const CF = .{ .kilo = 1024 };

pub const Report = struct { copied: u32 = 0, same: u32 = 0, denied: u32 = 0, big: u32 = 0, other: u32 = 0, moved: u32 = 0 };

fn skipDir(rules: conf.Push, name: []const u8) bool {
    for (rules.skip_dirs) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

fn hit(list: []const []const u8, path: []const u8) bool {
    for (list) |p| if (scan.glob(p, path)) return true;
    return false;
}

// the one decision: allowlist first, then the denylist, so a deny always wins ----
pub const Verdict = enum { take, other, denied };

pub fn judge(rules: conf.Push, rel: []const u8) Verdict {
    if (!hit(rules.allo, rel)) return .other;
    if (hit(rules.deny, rel)) return .denied;
    return .take;
}

fn slashed(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

// the real path when the folder exists, else the text as given without trailing separators ----
pub fn norm(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch return std.mem.trimEnd(u8, path, "/\\");
    return std.mem.trimEnd(u8, real, "/\\");
}

// true when `inner` is `outer` or sits below it ----
pub fn inside(inner: []const u8, outer: []const u8) bool {
    if (!std.mem.startsWith(u8, inner, outer)) return false;
    return inner.len == outer.len or inner[outer.len] == '/' or inner[outer.len] == '\\';
}

// walk the source; copy changed files; count what the repo folder holds that the source no longer has ----
pub fn push(io: std.Io, a: std.mem.Allocator, rules: conf.Push, from: []const u8, to: []const u8, live: bool, now_secs: i64, say: *const fn (std.Io, []const u8) void) !Report {
    var rep: Report = .{};
    // a mirror onto itself, or into its own source, would move the work tree's files away: refuse before anything runs ----
    const from_real = try norm(io, a, from);
    const to_real = try norm(io, a, to);
    if (inside(from_real, to_real) or inside(to_real, from_real)) return error.RootsOverlap;
    if (rules.trash.len > 0) {
        const trash_real = try norm(io, a, rules.trash);
        if (inside(trash_real, to_real) or inside(to_real, trash_real)) return error.TrashOverlap;
    }
    const cwd = std.Io.Dir.cwd();
    var src = try cwd.openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
    defer src.close(io);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const cap: u64 = @as(u64, rules.file_maxz_kbyt) * CF.kilo;
    var w = try src.walkSelectively(a);
    defer w.deinit();
    while (true) {
        const ent = (w.next(io) catch continue) orelse break;
        switch (ent.kind) {
            .directory => if (!skipDir(rules, ent.basename)) w.enter(io, ent) catch continue,
            .file => {
                const rel = try slashed(a, ent.path);
                switch (judge(rules, rel)) {
                    .other => {
                        rep.other += 1;
                        continue;
                    },
                    .denied => {
                        rep.denied += 1;
                        say(io, try std.fmt.allocPrint(a, "denied {s}\n", .{rel}));
                        continue;
                    },
                    .take => {},
                }
                const st = ent.dir.statFile(io, ent.basename, .{ .follow_symlinks = false }) catch continue;
                if (st.size > cap) {
                    rep.big += 1;
                    say(io, try std.fmt.allocPrint(a, "too big {s}\n", .{rel}));
                    continue;
                }
                try seen.put(a, rel, {});
                const data = ent.dir.readFileAlloc(io, ent.basename, a, .limited(cap + 1)) catch continue;
                const dest = try std.fs.path.join(a, &.{ to, rel });
                const old = cwd.readFileAlloc(io, dest, a, .limited(cap + 1)) catch null;
                if (old != null and std.mem.eql(u8, old.?, data)) {
                    rep.same += 1;
                    continue;
                }
                rep.copied += 1;
                say(io, try std.fmt.allocPrint(a, "{s} {s}\n", .{ if (live) "copy" else "would copy", rel }));
                if (!live) continue;
                if (std.fs.path.dirname(dest)) |d| try cwd.createDirPath(io, d);
                const part = try std.mem.concat(a, u8, &.{ dest, ".part" });
                try cwd.writeFile(io, .{ .sub_path = part, .data = data });
                try std.Io.Dir.rename(cwd, part, cwd, dest, io);
            },
            else => {},
        }
    }
    rep.moved = try moveGone(io, a, rules, to, live, now_secs, &seen, say);
    return rep;
}

// a plain rename when both folders share a disk; across disks (rename refuses) copy, check the size, then remove the source: the same thing `mv` does ----
fn moveFile(io: std.Io, a: std.mem.Allocator, cwd: std.Io.Dir, src: []const u8, dest: []const u8) !void {
    cwd.rename(src, cwd, dest, io) catch return moveByCopy(io, a, cwd, src, dest);
}

fn moveByCopy(io: std.Io, a: std.mem.Allocator, cwd: std.Io.Dir, src: []const u8, dest: []const u8) !void {
    const part = try std.mem.concat(a, u8, &.{ dest, ".part" });
    var total: u64 = 0;
    {
        var in = try cwd.openFile(io, src, .{});
        defer in.close(io);
        const out = try cwd.createFile(io, part, .{});
        defer out.close(io);
        const buf = try a.alloc(u8, 64 * CF.kilo);
        while (true) {
            const n = try in.readPositionalAll(io, buf, total);
            if (n == 0) break;
            try out.writePositionalAll(io, buf[0..n], total);
            total += n;
            if (n < buf.len) break;
        }
    }
    const st = try cwd.statFile(io, part, .{});
    if (st.size != total) return error.CopyShort;
    try std.Io.Dir.rename(cwd, part, cwd, dest, io);
    try cwd.deleteFile(io, src);
}

// _yyMMdd_HHmmss from epoch seconds (name clash suffix, as the trash rule says)
fn stamp(a: std.mem.Allocator, secs: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const ymd = es.getEpochDay().calculateYearDay();
    const md = ymd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "_{d:0>2}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{ @as(u32, ymd.year) % 100, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}

// files the repo folder holds that the source no longer has: moved to the trash folder, same relative path ----
fn moveGone(io: std.Io, a: std.mem.Allocator, rules: conf.Push, to: []const u8, live: bool, now_secs: i64, seen: *std.StringHashMapUnmanaged(void), say: *const fn (std.Io, []const u8) void) !u32 {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, to, .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer dir.close(io);
    var gone: std.ArrayList([]const u8) = .empty;
    var w = try dir.walkSelectively(a);
    defer w.deinit();
    while (true) {
        const ent = (w.next(io) catch continue) orelse break;
        switch (ent.kind) {
            .directory => if (!skipDir(rules, ent.basename)) w.enter(io, ent) catch continue,
            .file => {
                const rel = try slashed(a, ent.path);
                if (seen.contains(rel) or hit(rules.keep, rel)) continue;
                try gone.append(a, rel);
            },
            else => {},
        }
    }
    if (gone.items.len == 0) return 0;
    if (rules.trash.len == 0) return error.NoTrashFolder;
    for (gone.items) |rel| {
        say(io, try std.fmt.allocPrint(a, "{s} {s}\n", .{ if (live) "move out" else "would move out", rel }));
        if (!live) continue;
        try trashFile(io, a, rules.trash, to, rel, now_secs);
    }
    return @intCast(gone.items.len);
}

// move one file of the repo folder into the trash folder, same relative path; a name clash keeps both with a time suffix ----
pub fn trashFile(io: std.Io, a: std.mem.Allocator, trash: []const u8, to: []const u8, rel: []const u8, now_secs: i64) !void {
    const cwd = std.Io.Dir.cwd();
    const src = try std.fs.path.join(a, &.{ to, rel });
    var dest = try std.fs.path.join(a, &.{ trash, rel });
    if (cwd.access(io, dest, .{})) |_| {
        dest = try std.mem.concat(a, u8, &.{ dest, try stamp(a, now_secs) });
    } else |_| {}
    if (std.fs.path.dirname(dest)) |d| try cwd.createDirPath(io, d);
    try moveFile(io, a, cwd, src, dest);
}

fn quiet(_: std.Io, _: []const u8) void {}

const T_RULES: conf.Push = .{
    .skip_dirs = &.{ "zig-out", ".10-docs" },
    .allo = &.{ "*.zig", "*.key", "*.10-documents/*" },
    .deny = &.{"*.key"},
    .file_maxz_kbyt = 1,
};

test "judge: allowlist gates, deny wins, anything unlisted is left out" {
    try std.testing.expectEqual(Verdict.take, judge(T_RULES, "app/main.zig"));
    try std.testing.expectEqual(Verdict.take, judge(T_RULES, ".10-documents/05-README.md"));
    try std.testing.expectEqual(Verdict.other, judge(T_RULES, "app/notes.txt"));
    try std.testing.expectEqual(Verdict.denied, judge(.{ .allo = &.{"*"}, .deny = &.{"*.key"} }, "a/server.key"));
    try std.testing.expectEqual(Verdict.other, judge(.{}, "main.zig"));
}

test "judge: root LICENSE and README.md are taken, same names deeper are not" {
    const r: conf.Push = .{ .allo = &.{ "LICENSE", "README.md" } };
    try std.testing.expectEqual(Verdict.take, judge(r, "LICENSE"));
    try std.testing.expectEqual(Verdict.take, judge(r, "README.md"));
    try std.testing.expectEqual(Verdict.other, judge(r, "app/README.md"));
}

fn put(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(std.testing.io, d);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "moveByCopy: the cross-disk path copies every byte of a multi-chunk file, then the source is gone" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try a.alloc(u8, 150 * 1024 + 7);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);
    try tmp.dir.writeFile(io, .{ .sub_path = "from.bin", .data = data });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const src = try std.fs.path.join(a, &.{ base, "from.bin" });
    const dest = try std.fs.path.join(a, &.{ base, "to.bin" });
    try moveByCopy(io, a, std.Io.Dir.cwd(), src, dest);
    const got = try tmp.dir.readFileAlloc(io, "to.bin", a, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, data, got);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "from.bin", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "to.bin.part", .{}));
}

test "push refuses a source and repo folder that overlap, and a trash folder inside the repo folder" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "tree/app/main.zig", "x");
    try put(tmp.dir, "copy/keep.zig", "y");
    const tree = try tmp.dir.realPathFileAlloc(io, "tree", a);
    const copy = try tmp.dir.realPathFileAlloc(io, "copy", a);
    const inner = try std.fs.path.join(a, &.{ tree, "app" });
    var rules = T_RULES;
    rules.trash = try std.fs.path.join(a, &.{ copy, "trash" });
    try std.testing.expectError(error.RootsOverlap, push(io, a, rules, tree, tree, true, 0, &quiet));
    try std.testing.expectError(error.RootsOverlap, push(io, a, rules, tree, inner, true, 0, &quiet));
    try std.testing.expectError(error.RootsOverlap, push(io, a, rules, inner, tree, true, 0, &quiet));
    try std.testing.expectError(error.TrashOverlap, push(io, a, rules, tree, copy, true, 0, &quiet));
    rules.trash = try std.fs.path.join(a, &.{ tree, "elsewhere" });
    _ = try push(io, a, rules, tree, copy, false, 0, &quiet); // separate folders: fine
    try tmp.dir.access(io, "tree/app/main.zig", .{}); // nothing of the work tree was touched
}

test "push: overwrites changed files, skips folders, dry-run writes nothing, second run is idempotent, gone files move to the trash" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src = std.testing.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = std.testing.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    var bin = std.testing.tmpDir(.{ .iterate = true });
    defer bin.cleanup();
    try put(src.dir, "app/main.zig", "pub fn main() void {}");
    try put(src.dir, "app/secret.key", "nope");
    try put(src.dir, "app/notes.txt", "x");
    try put(src.dir, "app/zig-out/bin/x.zig", "built");
    try put(src.dir, ".10-docs/plan.zig", "private");
    try put(src.dir, ".10-documents/05-README.md", "# hi");
    try put(src.dir, "app/big.zig", "z" ** 2048);
    try put(dst.dir, "gone/old.zig", "removed upstream");
    try put(dst.dir, "app/main.zig", "OLD CONTENT edited in the copy");
    try put(dst.dir, "app/secret.key", "leaked earlier");
    try put(dst.dir, ".gitignore", "kept");
    try put(dst.dir, ".git/HEAD", "untouched");
    const from = try src.dir.realPathFileAlloc(io, ".", a);
    const to = try dst.dir.realPathFileAlloc(io, ".", a);
    var rules = T_RULES;
    rules.skip_dirs = &.{ "zig-out", ".10-docs", ".git" };
    rules.keep = &.{".gitignore"};
    rules.trash = try bin.dir.realPathFileAlloc(io, ".", a);

    const dry = try push(io, a, rules, from, to, false, 0, &quiet);
    try std.testing.expectEqual(@as(u32, 2), dry.copied);
    try std.testing.expectEqual(@as(u32, 1), dry.big);
    try std.testing.expectEqual(@as(u32, 1), dry.denied);
    try std.testing.expectEqual(@as(u32, 2), dry.moved);
    try dst.dir.access(io, "gone/old.zig", .{});
    try bin.dir.access(io, ".", .{});
    try std.testing.expectError(error.FileNotFound, bin.dir.access(io, "gone/old.zig", .{}));

    const live = try push(io, a, rules, from, to, true, 0, &quiet);
    try std.testing.expectEqual(@as(u32, 2), live.copied);
    try std.testing.expectEqual(@as(u32, 2), live.moved);
    const fresh = try dst.dir.readFileAlloc(io, "app/main.zig", a, .limited(1024));
    try std.testing.expectEqualStrings("pub fn main() void {}", fresh);
    try dst.dir.access(io, ".10-documents/05-README.md", .{});
    for ([_][]const u8{ "app/notes.txt", "app/zig-out/bin/x.zig", ".10-docs/plan.zig", "app/big.zig", "gone/old.zig", "app/secret.key" }) |gone| try std.testing.expectError(error.FileNotFound, dst.dir.access(io, gone, .{}));
    try dst.dir.access(io, ".gitignore", .{});
    try dst.dir.access(io, ".git/HEAD", .{});
    try bin.dir.access(io, "gone/old.zig", .{});
    try bin.dir.access(io, "app/secret.key", .{});

    const again = try push(io, a, rules, from, to, true, 0, &quiet);
    try std.testing.expectEqual(@as(u32, 0), again.copied);
    try std.testing.expectEqual(@as(u32, 0), again.moved);
    try std.testing.expectEqual(@as(u32, 2), again.same);

    // a second file with the same trash path gets a time suffix instead of replacing the first
    try put(dst.dir, "gone/old.zig", "second");
    const clash = try push(io, a, rules, from, to, true, 1_700_000_000, &quiet);
    try std.testing.expectEqual(@as(u32, 1), clash.moved);
    try bin.dir.access(io, "gone/old.zig_231114_221320", .{});
    const first = try bin.dir.readFileAlloc(io, "gone/old.zig", a, .limited(64));
    try std.testing.expectEqualStrings("removed upstream", first);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
