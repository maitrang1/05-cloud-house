// =====================================================================
// Des: Looks through the files about to be committed for key files, tokens and oversized files, so a secret never reaches GitHub history
// Flo: file list > skip listed paths > check the file name > check the size > read the head of the file for token shapes > findings
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: repo folder, relative file paths, Rules{ name globs, token marks, skip globs, size caps }
// Out: list of Find{ path, kind, rule } (arena-owned); empty = clean
// Run: not run directly - imported by github-repo.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

const CF = .{ .kilo = 1024, .mega = 1024 * 1024, .overlap = 512 };

pub const Mark = struct { pref: []const u8, tail: u32 = 0 };

pub const Rules = struct {
    name: []const []const u8 = &.{},
    mark: []const Mark = &.{},
    skip: []const []const u8 = &.{},
    wind_kbyt: u32 = 512,
    file_maxz_mbyt: u32 = 100,
};

pub const Kind = enum { name, mark, big, unread };

pub const Find = struct { path: []const u8, kind: Kind, rule: []const u8 };

// `*` matches any run of characters; one backtrack point, never exponential ----
pub fn glob(pat: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var back: usize = 0;
    while (t < text.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            back = t;
        } else if (p < pat.len and pat[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            back += 1;
            t = back;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn tokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

// a mark hits when its prefix is followed by at least `tail` token characters ----
pub fn markHit(text: []const u8, m: Mark) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, m.pref)) |at| {
        var end = at + m.pref.len;
        while (end < text.len and tokenChar(text[end])) end += 1;
        if (end - at - m.pref.len >= m.tail) return true;
        from = at + 1;
    }
    return false;
}

fn slashed(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const out = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

pub fn scan(io: std.Io, a: std.mem.Allocator, root: []const u8, paths: []const []const u8, rules: Rules) ![]Find {
    var out: std.ArrayList(Find) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const head_maxz: usize = @max(@as(usize, rules.wind_kbyt) * CF.kilo, CF.overlap * 2);
    const buf = try a.alloc(u8, head_maxz);
    files: for (paths) |raw| {
        const path = try slashed(a, raw);
        for (rules.skip) |s| if (glob(s, path)) continue :files;
        const base = std.fs.path.basenamePosix(path);
        for (rules.name) |n| if (glob(n, base)) {
            try out.append(a, .{ .path = path, .kind = .name, .rule = n });
            continue :files;
        };
        const st = dir.statFile(io, raw, .{}) catch {
            try out.append(a, .{ .path = path, .kind = .unread, .rule = "cannot read" });
            continue;
        };
        if (st.kind != .file) continue;
        if (st.size > @as(u64, rules.file_maxz_mbyt) * CF.mega) {
            try out.append(a, .{ .path = path, .kind = .big, .rule = "over the file size cap" });
            continue;
        }
        const f = dir.openFile(io, raw, .{}) catch {
            try out.append(a, .{ .path = path, .kind = .unread, .rule = "cannot read" });
            continue;
        };
        defer f.close(io);
        // the whole file, window by window; each window starts CF.overlap bytes before the last one ended, so a token on a boundary is whole in the next window ----
        var off: u64 = 0;
        while (true) {
            const n = f.readPositionalAll(io, buf, off) catch {
                try out.append(a, .{ .path = path, .kind = .unread, .rule = "cannot read" });
                continue :files;
            };
            for (rules.mark) |m| if (markHit(buf[0..n], m)) {
                try out.append(a, .{ .path = path, .kind = .mark, .rule = m.pref });
                continue :files;
            };
            if (n < buf.len) break;
            off += n - CF.overlap;
        }
    }
    return out.toOwnedSlice(a);
}

test "scan reads the whole file: a token far past the first window and one straddling a window edge are found" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tok = "ghp_" ++ "A" ** 36;
    const pad = try a.alloc(u8, 5000);
    @memset(pad, 'x');
    const far = try std.mem.concat(a, u8, &.{ pad, " ", tok, " end" });
    try tmp.dir.writeFile(io, .{ .sub_path = "far.txt", .data = far });
    const edge_at: usize = 1024 - 10; // the 1 KiB window ends inside the token
    const edge = try std.mem.concat(a, u8, &.{ pad[0..edge_at], tok, pad[0..300] });
    try tmp.dir.writeFile(io, .{ .sub_path = "edge.txt", .data = edge });
    try tmp.dir.writeFile(io, .{ .sub_path = "clean.txt", .data = pad });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const rules: Rules = .{ .mark = &.{.{ .pref = "ghp_", .tail = 30 }}, .wind_kbyt = 1 };
    const got = try scan(io, a, root, &.{ "far.txt", "edge.txt", "clean.txt" }, rules);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("far.txt", got[0].path);
    try std.testing.expectEqualStrings("edge.txt", got[1].path);
}

test "glob: stars, exact names, no runaway on many stars" {
    try std.testing.expect(glob("*.pem", "server.pem"));
    try std.testing.expect(glob(".env", ".env"));
    try std.testing.expect(glob(".env.*", ".env.prod"));
    try std.testing.expect(!glob(".env", ".envrc"));
    try std.testing.expect(!glob("*.pem", "pem"));
    try std.testing.expect(glob("docs/*", "docs/a/b.md"));
    try std.testing.expect(glob("*", ""));
    try std.testing.expect(!glob("*a*a*a*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "mark needs the tail; a bare prefix in prose is not a hit" {
    try std.testing.expect(markHit("token = ghp_" ++ "A" ** 36, .{ .pref = "ghp_", .tail = 30 }));
    try std.testing.expect(!markHit("the ghp_ prefix means a token", .{ .pref = "ghp_", .tail = 30 }));
    try std.testing.expect(markHit("x ghp_ y ghp_" ++ "b" ** 30, .{ .pref = "ghp_", .tail = 30 }));
    try std.testing.expect(markHit("END PRIVATE KEY-----", .{ .pref = "PRIVATE KEY-----", .tail = 0 }));
}

test "scan finds a key file, a token and a big file; skip list and clean files pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "clean.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/server.pem", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "leak.md", .data = "t: gho_" ++ "Z" ** 36 });
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.md", .data = "t: gho_" ++ "Z" ** 36 });
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = "0123456789" ** 200 });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const rules: Rules = .{ .name = &.{"*.pem"}, .mark = &.{.{ .pref = "gho_", .tail = 30 }}, .skip = &.{"fixture.*"}, .wind_kbyt = 1, .file_maxz_mbyt = 0 };
    const got = try scan(io, a, buf[0..n], &.{ "clean.txt", "sub/server.pem", "leak.md", "fixture.md", "gone.txt" }, rules);
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqual(Kind.big, got[0].kind);
    try std.testing.expectEqual(Kind.name, got[1].kind);
    try std.testing.expectEqualStrings("sub/server.pem", got[1].path);
    try std.testing.expectEqual(Kind.big, got[2].kind);
    try std.testing.expectEqual(Kind.unread, got[3].kind);
    var loose = rules;
    loose.file_maxz_mbyt = 1;
    const two = try scan(io, a, buf[0..n], &.{ "clean.txt", "leak.md", "big.bin" }, loose);
    try std.testing.expectEqual(@as(usize, 1), two.len);
    try std.testing.expectEqual(Kind.mark, two[0].kind);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
