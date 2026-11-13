// =====================================================================
// Des: Remembers what each app looked like the last time its test or build went green, so `--app-edit` can pick only the apps changed since then
// Flo: hash an app's publishable files by content > compare with the saved hash under a key (app|test, app|build, app|build:target) > a green run saves the new hash
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: work tree path, app folder, push rules (allo/deny/skip_dirs), extra skip globs, the record file
// Out: a 64-letter hex hash ; Seen{ get, put, save } ; a missing or damaged record means "edited"
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const rpush = @import("repo-push.zig");
const scan = @import("secret-scan.zig");

const CF = .{ .rec_maxz = 1024 * 1024, .part = ".part" };

pub const Hex = [64]u8;

fn skipDir(rules: conf.Push, name: []const u8) bool {
    for (rules.skip_dirs) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

// the app's files that count: what the mirror would copy, minus the extra skip globs (docs); sorted by path ----
fn files(io: std.Io, a: std.mem.Allocator, tree: []const u8, app: []const u8, rules: conf.Push, skip: []const []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, try std.fs.path.join(a, &.{ tree, app }), .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var w = try dir.walkSelectively(a);
    defer w.deinit();
    while (true) {
        const ent = (w.next(io) catch continue) orelse break;
        switch (ent.kind) {
            .directory => if (!skipDir(rules, ent.basename)) w.enter(io, ent) catch continue,
            .file => {
                const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ app, ent.path });
                std.mem.replaceScalar(u8, rel, '\\', '/');
                if (rpush.judge(rules, rel) != .take) continue;
                var skipped = false;
                for (skip) |g| if (scan.glob(g, rel)) {
                    skipped = true;
                };
                if (!skipped) try list.append(a, rel);
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return list.items;
}

// one SHA-256 over every counted file: its path, its size and its bytes; time stamps never count ----
pub fn hashApp(io: std.Io, a: std.mem.Allocator, tree: []const u8, app: []const u8, rules: conf.Push, skip: []const []const u8) !Hex {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (try files(io, a, tree, app, rules, skip)) |rel| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ tree, rel }), a, .limited(@as(usize, rules.file_maxz_kbyt) * 1024)) catch |e| switch (e) {
            error.StreamTooLong => "", // over the cap: the path still counts
            else => return e,
        };
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, data.len, .little);
        h.update(rel);
        h.update("\x00");
        h.update(&len);
        h.update(data);
    }
    var raw: [32]u8 = undefined;
    h.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

pub fn keyFor(a: std.mem.Allocator, name: []const u8, build: bool, target: ?[]const u8) ![]u8 {
    if (!build) return std.fmt.allocPrint(a, "{s}|test", .{name});
    return std.fmt.allocPrint(a, "{s}|build:{s}", .{ name, target orelse "native" });
}

pub const Seen = struct {
    a: std.mem.Allocator,
    path: []const u8,
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn get(self: *const Seen, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn put(self: *Seen, key: []const u8, hex: []const u8) !void {
        try self.map.put(self.a, try self.a.dupe(u8, key), try self.a.dupe(u8, hex));
    }

    // true when the app has no green record under this key, or its files changed since ----
    pub fn edited(self: *const Seen, key: []const u8, hex: []const u8) bool {
        const got = self.get(key) orelse return true;
        return !std.mem.eql(u8, got, hex);
    }

    // one `key<TAB>hash` line each, sorted, written next to the file then renamed over it; owner-only on POSIX ----
    pub fn save(self: *const Seen, io: std.Io) !void {
        var keys: std.ArrayList([]const u8) = .empty;
        var it = self.map.keyIterator();
        while (it.next()) |k| try keys.append(self.a, k.*);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        var text: std.ArrayList(u8) = .empty;
        for (keys.items) |k| try text.print(self.a, "{s}\t{s}\n", .{ k, self.map.get(k).? });
        const part = try std.mem.concat(self.a, u8, &.{ self.path, CF.part });
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.path)) |d| try cwd.createDirPath(io, d);
        {
            const f = try cwd.createFile(io, part, if (comptime @import("builtin").os.tag == .windows) .{} else .{ .permissions = .fromMode(0o600) });
            defer f.close(io);
            try f.writePositionalAll(io, text.items, 0);
        }
        try cwd.rename(part, cwd, self.path, io);
    }
};

// a missing or unreadable record is an empty one: every app then counts as edited, which is the safe side ----
pub fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) !Seen {
    var s: Seen = .{ .a = a, .path = try a.dupe(u8, path) };
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.rec_maxz)) catch return s;
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const hex = line[tab + 1 ..];
        if (tab == 0 or hex.len != 64) continue; // a damaged line is dropped: that app just counts as edited
        try s.put(line[0..tab], hex);
    }
    return s;
}

// ---- tests ----
const T_RULES: conf.Push = .{ .skip_dirs = &.{ "zig-out", ".zig-cache" }, .allo = &.{ "*.zig", "*.json", "*.10-documents/*" }, .deny = &.{"*.key"}, .file_maxz_kbyt = 1 };
const T_SKIP: []const []const u8 = &.{"*.10-documents/*"};

fn put(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(std.testing.io, d);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "hashApp: stable, content-driven; docs, skip folders and unlisted files never count; one byte or a new file changes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try put(tmp.dir, "v/alpha/main.zig", "fn main() {}");
    try put(tmp.dir, "v/alpha/cfg.json", "{}");
    try put(tmp.dir, "v/beta/main.zig", "other app");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const io = std.testing.io;
    const base = try hashApp(io, a, root, "v/alpha", T_RULES, T_SKIP);
    try std.testing.expectEqualSlices(u8, &base, &(try hashApp(io, a, root, "v/alpha", T_RULES, T_SKIP))); // stable
    // things that must not count
    try put(tmp.dir, "v/alpha/.10-documents/05-README.md", "docs"); // not allowlisted anyway
    try put(tmp.dir, "v/alpha/.10-documents/x.json", "{\"docs\":1}"); // allowlisted but a skip glob
    try put(tmp.dir, "v/alpha/zig-out/bin/exe.zig", "built");
    try put(tmp.dir, "v/alpha/notes.txt", "not listed");
    try put(tmp.dir, "v/alpha/secret.key", "denied");
    try put(tmp.dir, "v/beta/main.zig", "the other app changed");
    try std.testing.expectEqualSlices(u8, &base, &(try hashApp(io, a, root, "v/alpha", T_RULES, T_SKIP)));
    // things that must count: the same length with one byte different, then a longer file, then a new file
    try put(tmp.dir, "v/alpha/cfg.json", "[]");
    const same_len = try hashApp(io, a, root, "v/alpha", T_RULES, T_SKIP);
    try std.testing.expect(!std.mem.eql(u8, &base, &same_len));
    try put(tmp.dir, "v/alpha/main.zig", "fn main() { }");
    const edit = try hashApp(io, a, root, "v/alpha", T_RULES, T_SKIP);
    try std.testing.expect(!std.mem.eql(u8, &same_len, &edit));
    try put(tmp.dir, "v/alpha/extra.zig", "");
    try std.testing.expect(!std.mem.eql(u8, &edit, &(try hashApp(io, a, root, "v/alpha", T_RULES, T_SKIP))));
}

test "Seen: a green hash is remembered per key, any other key or a changed hash is edited, the record survives a save and load, damage means edited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(std.testing.io, &buf)]);
    const path = try std.fs.path.join(a, &.{ root, "sub", "seen.txt" });
    const h1 = "a" ** 64;
    const h2 = "b" ** 64;
    var s = try load(std.testing.io, a, path); // missing file: empty
    try std.testing.expect(s.edited("github|test", h1)); // never green = edited
    try s.put("github|test", h1);
    try std.testing.expect(!s.edited("github|test", h1));
    try std.testing.expect(s.edited("github|test", h2)); // files changed
    try std.testing.expect(s.edited("github|build:native", h1)); // test green says nothing about build
    try std.testing.expect(s.edited("github|build:x86_64-windows", h1));
    try s.put("github|build:x86_64-windows", h2);
    try s.save(std.testing.io);
    const again = try load(std.testing.io, a, path);
    try std.testing.expect(!again.edited("github|test", h1));
    try std.testing.expect(!again.edited("github|build:x86_64-windows", h2));
    try std.testing.expect(again.edited("github|build:x86_64-linux", h2));
    // a damaged line is dropped, the good one stays
    try put(tmp.dir, "sub/seen.txt", "garbage line\nshort\tabc\ngitlab|test\t" ++ h1 ++ "\n");
    const hurt = try load(std.testing.io, a, path);
    try std.testing.expect(hurt.edited("short", "abc"));
    try std.testing.expect(!hurt.edited("gitlab|test", h1));
    try std.testing.expect(hurt.edited("github|test", h1));
    try std.testing.expectEqualStrings("github|build:native", try keyFor(a, "github", true, null));
    try std.testing.expectEqualStrings("github|build:x86_64-windows", try keyFor(a, "github", true, "x86_64-windows"));
    try std.testing.expectEqualStrings("github|test", try keyFor(a, "github", false, null));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
