// =====================================================================
// Des: Appends one line per call, command or step to a local log so every action leaves a trail, with every known secret blacked out first
// Flo: register secrets > build one JSON line > redact known values and token shapes > append at the end of audit.jsonl
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: log file path ; kind, verb, target, code, ms, note per line
// Out: one JSON line appended ; redact() for any text that may reach the screen
// Run: not run directly - imported by app-ctx.zig, net-http.zig, git-run.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

const CF = .{ .hide_maxz = 32, .hide_minz = 6, .mask = "***", .tail_minz = 20 };
const SHAPES = [_][]const u8{ "ghp_", "gho_", "ghs_", "ghu_", "ghr_", "github_pat_" };

pub const Line = struct { when: i64, kind: []const u8, verb: []const u8, targ: []const u8, code: i64 = 0, msec: i64 = 0, note: []const u8 = "" };

pub const Audit = struct {
    a: std.mem.Allocator,
    path: []const u8 = "",
    hide: [CF.hide_maxz][]const u8 = undefined,
    hide_coun: usize = 0,
    lines: usize = 0,

    // values to black out everywhere; too-short values would shred normal text ----
    pub fn hideAdd(self: *Audit, secret: []const u8) void {
        if (secret.len < CF.hide_minz or self.hide_coun == CF.hide_maxz) return;
        for (self.hide[0..self.hide_coun]) |h| if (std.mem.eql(u8, h, secret)) return;
        self.hide[self.hide_coun] = self.a.dupe(u8, secret) catch return;
        self.hide_coun += 1;
    }

    pub fn redact(self: *const Audit, text: []const u8) []const u8 {
        var cur: []const u8 = text;
        for (self.hide[0..self.hide_coun]) |h| {
            if (std.mem.indexOf(u8, cur, h) == null) continue;
            cur = std.mem.replaceOwned(u8, self.a, cur, h, CF.mask) catch return CF.mask;
        }
        return shapeMask(self.a, cur);
    }

    pub fn add(self: *Audit, io: std.Io, line: Line) void {
        if (self.path.len == 0) return;
        var safe = line;
        safe.targ = self.redact(line.targ);
        safe.note = self.redact(line.note);
        const text = std.json.Stringify.valueAlloc(self.a, safe, .{}) catch return;
        const full = std.mem.concat(self.a, u8, &.{ text, "\n" }) catch return;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.path)) |d| cwd.createDirPath(io, d) catch return;
        // owner-only on POSIX; Windows keeps the profile folder's own access list ----
        const f = cwd.createFile(io, self.path, if (comptime @import("builtin").os.tag == .windows) .{ .truncate = false, .read = true } else .{ .truncate = false, .read = true, .permissions = .fromMode(0o600) }) catch return;
        defer f.close(io);
        const end = f.length(io) catch return;
        f.writePositionalAll(io, full, end) catch return;
        self.lines += 1;
    }
};

fn tokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// GitHub token shapes are masked even when the value was never registered ----
fn shapeMask(a: std.mem.Allocator, text: []const u8) []const u8 {
    var hit = false;
    for (SHAPES) |s| if (std.mem.indexOf(u8, text, s) != null) {
        hit = true;
    };
    if (!hit) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < text.len) {
        for (SHAPES) |s| {
            if (!std.mem.startsWith(u8, text[i..], s)) continue;
            var end = i + s.len;
            while (end < text.len and tokenChar(text[end])) end += 1;
            if (end - i - s.len < CF.tail_minz) continue;
            out.appendSlice(a, CF.mask) catch return CF.mask;
            i = end;
            continue :outer;
        }
        out.append(a, text[i]) catch return CF.mask;
        i += 1;
    }
    return out.items;
}

test "registered secrets and token shapes are masked; lines append; short values are not registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var au: Audit = .{ .a = a, .path = try std.fs.path.join(a, &.{ buf[0..n], "logs", "audit.jsonl" }) };
    au.hideAdd("hunter2-long-secret");
    au.hideAdd("abc");
    try std.testing.expectEqual(@as(usize, 1), au.hide_coun);
    try std.testing.expectEqualStrings("x *** y", au.redact("x hunter2-long-secret y"));
    try std.testing.expectEqualStrings("abc stays", au.redact("abc stays"));
    try std.testing.expectEqualStrings("t=*** end", au.redact("t=gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 end"));
    try std.testing.expectEqualStrings("prefix ghp_ only", au.redact("prefix ghp_ only"));
    au.add(io, .{ .when = 1, .kind = "http", .verb = "GET", .targ = "https://x/?t=hunter2-long-secret", .code = 200 });
    au.add(io, .{ .when = 2, .kind = "git", .verb = "push", .targ = "origin", .note = "gho_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345" });
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, au.path, a, .limited(4096));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, raw, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "gho_ABC") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"code\":200") != null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
