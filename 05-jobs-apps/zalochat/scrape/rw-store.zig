// Local store (the "Database" and "Content" plugs): per-cust folder, JSONL rows, atomic whole-file replace, advisory lock.
// Layout in df-store-layout.md. Swapping to SQLite/B2/Turso later = a new adapter with this same surface.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const shape = @import("rw-shape.zig");
const dedup = @import("rw-dedup.zig");
const ctx_mod = @import("co-ctx.zig");

pub const Stats = struct { added: u32 = 0, dup: u32 = 0, bad: u32 = 0 };
pub const day_ms: i64 = 86_400_000;

pub const Store = struct {
    io: Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    // test hook: stop after writing .part, before the rename (simulated crash)
    crash_before_rename: bool = false,

    pub fn init(io: Io, gpa: std.mem.Allocator, home: []const u8) Store {
        return .{ .io = io, .gpa = gpa, .home = home };
    }

    pub fn path(self: *const Store, a: std.mem.Allocator, cust: []const u8, sub: []const u8) ![]u8 {
        if (!ctx_mod.validId(cust)) return error.BadCustId;
        if (sub.len == 0) return std.fmt.allocPrint(a, "{s}/cust/{s}", .{ self.home, cust });
        return std.fmt.allocPrint(a, "{s}/cust/{s}/{s}", .{ self.home, cust, sub });
    }

    pub fn ensure(self: *const Store, cust: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try util.mkdirp(self.io, try self.path(a, cust, "files"));
        try util.mkdirp(self.io, try self.path(a, cust, "cache"));
    }

    // ---- lock: advisory file lock, released on close; a crash frees it ----
    pub const Lock = struct {
        f: Io.File,
        io: Io,
        pub fn release(self: Lock) void {
            self.f.close(self.io);
        }
    };
    pub fn lock(self: *const Store, cust: []const u8) !Lock {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const p = try self.path(arena.allocator(), cust, "lock");
        const f = try Io.Dir.cwd().createFile(self.io, p, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
        return .{ .f = f, .io = self.io };
    }

    // ---- rows ----
    // Append new rows; rows already present (cust+key+hash) are skipped. All-or-nothing: one atomic file replace.
    pub fn upsert(self: *Store, cust: []const u8, rows: []const shape.Row) !Stats {
        try self.ensure(cust);
        const lk = try self.lock(cust);
        defer lk.release();
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const p = try self.path(a, cust, "rows.jsonl");
        const old = util.readAll(a, self.io, p, 512 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => try a.dupe(u8, ""),
            else => return e,
        };
        var seen = dedup.Seen{ .arena = a };
        var st = Stats{};
        var it = std.mem.splitScalar(u8, old, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            const r = shape.parseRow(a, ln) catch {
                st.bad += 1;
                continue;
            };
            _ = try seen.add(r.cust_id, r.key, r.hash);
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, old);
        if (old.len > 0 and old[old.len - 1] != '\n') try out.append(a, '\n');
        for (rows) |r| {
            if (!std.mem.eql(u8, r.cust_id, cust)) return error.CustMismatch; // a row can only enter its own cust
            if (!try seen.add(r.cust_id, r.key, r.hash)) {
                st.dup += 1;
                continue;
            }
            try out.appendSlice(a, try shape.rowLine(a, r));
            try out.append(a, '\n');
            st.added += 1;
        }
        if (st.added == 0) return st;
        if (self.crash_before_rename) {
            const tmp = try std.fmt.allocPrint(a, "{s}.part", .{p});
            try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp, .data = out.items });
            return error.SimulatedCrash;
        }
        try util.writeAtomic(a, self.io, p, out.items);
        return st;
    }

    // rows after cursor (line index) - returns rows and the next cursor
    pub const Page = struct { rows: []shape.Row, next: usize };
    pub fn rowsSince(self: *const Store, a: std.mem.Allocator, cust: []const u8, cursor: usize, limit: usize) !Page {
        const p = try self.path(a, cust, "rows.jsonl");
        const txt = util.readAll(a, self.io, p, 512 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return .{ .rows = &.{}, .next = cursor },
            else => return e,
        };
        var list: std.ArrayList(shape.Row) = .empty;
        var idx: usize = 0;
        var it = std.mem.splitScalar(u8, txt, '\n');
        var next = cursor;
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            defer idx += 1;
            if (idx < cursor) continue;
            if (list.items.len >= limit) break;
            if (shape.parseRow(a, ln)) |r| try list.append(a, r) else |_| {}
            next = idx + 1;
        }
        return .{ .rows = list.items, .next = next };
    }

    // keys already stored (any version) for one kind: lets a resync skip work it already did
    pub fn knownKeys(self: *const Store, a: std.mem.Allocator, cust: []const u8, kind: []const u8) !std.StringHashMapUnmanaged(void) {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        const txt = util.readAll(a, self.io, try self.path(a, cust, "rows.jsonl"), 512 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return set,
            else => return e,
        };
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            const r = shape.parseRow(a, ln) catch continue;
            if (std.mem.eql(u8, r.kind, kind)) try set.put(a, r.key, {});
        }
        return set;
    }

    pub fn countRows(self: *const Store, cust: []const u8) !usize {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const pg = try self.rowsSince(arena.allocator(), cust, 0, std.math.maxInt(usize));
        return pg.rows.len;
    }

    // ---- cust file ----
    pub fn getCust(self: *const Store, a: std.mem.Allocator, cust: []const u8) !shape.Cust {
        const t = try util.readAll(a, self.io, try self.path(a, cust, "cust.json"), 1024 * 1024);
        const c = try shape.parseCust(a, t);
        if (!std.mem.eql(u8, c.cust_id, cust)) return error.CustMismatch;
        return c;
    }
    pub fn putCust(self: *const Store, a: std.mem.Allocator, c: shape.Cust) !void {
        try self.ensure(c.cust_id);
        const t = try std.json.Stringify.valueAlloc(a, c, .{});
        try util.writeAtomic(a, self.io, try self.path(a, c.cust_id, "cust.json"), t);
    }

    // ---- content plug: raw files ----
    pub fn putFile(self: *const Store, cust: []const u8, name: []const u8, bytes: []const u8) !void {
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return error.BadName;
        if (name.len == 0 or name[0] == '.') return error.BadName;
        try self.ensure(cust);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const p = try self.path(arena.allocator(), cust, try std.fmt.allocPrint(arena.allocator(), "files/{s}", .{name}));
        try util.writeAtomic(arena.allocator(), self.io, p, bytes);
    }

    // ---- append-only logs ----
    pub fn appendLog(self: *const Store, cust: []const u8, file: []const u8, line: []const u8) !void {
        try self.ensure(cust);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        try util.appendLine(self.io, try self.path(arena.allocator(), cust, file), line);
    }

    pub fn audit(self: *const Store, cust: []const u8, now_ms: i64, job: []const u8, url: []const u8, status: i64, note: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const A = struct { ts: i64, job: []const u8, url: []const u8, status: i64, note: []const u8 };
        const line = util.jsonStr(arena.allocator(), A{ .ts = now_ms, .job = job, .url = url, .status = status, .note = note }) catch return;
        self.appendLog(cust, "audit.jsonl", line) catch {};
    }

    // ---- daily fetch cap: one line per real request batch ----
    pub fn bumpFetches(self: *const Store, cust: []const u8, now_ms: i64, n: u32) !void {
        var b: [64]u8 = undefined;
        try self.appendLog(cust, "fetches.jsonl", try std.fmt.bufPrint(&b, "{d} {d}", .{ now_ms, n }));
    }
    pub fn fetchesToday(self: *const Store, cust: []const u8, now_ms: i64) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const txt = util.readAll(a, self.io, try self.path(a, cust, "fetches.jsonl"), 64 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        const today = @divFloor(now_ms, day_ms);
        var total: u32 = 0;
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |ln| {
            var f = std.mem.tokenizeScalar(u8, ln, ' ');
            const ts = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
            const n = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            if (@divFloor(ts, day_ms) == today) total +|= n;
        }
        return total;
    }
};

// ---- tests ----
fn tmpHome(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

fn mkRow(a: std.mem.Allocator, cust: []const u8, key: []const u8, body: []const u8) !shape.Row {
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    return shape.makeRow(a, cust, .public, key, "oa_page", 7, d);
}

test "store: same page twice = 1 row; changed page = new version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    var s = Store.init(std.testing.io, std.testing.allocator, try tmpHome(&tmp, &hb));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try mkRow(a, "demo", "https://zalo.me/x", "{\"t\":\"A\"}");
    const s1 = try s.upsert("demo", &.{r1});
    try std.testing.expectEqual(@as(u32, 1), s1.added);
    const s2 = try s.upsert("demo", &.{ r1, r1 });
    try std.testing.expectEqual(@as(u32, 0), s2.added);
    try std.testing.expectEqual(@as(u32, 2), s2.dup);
    try std.testing.expectEqual(@as(usize, 1), try s.countRows("demo"));
    const r2 = try mkRow(a, "demo", "https://zalo.me/x", "{\"t\":\"B\"}");
    _ = try s.upsert("demo", &.{r2});
    try std.testing.expectEqual(@as(usize, 2), try s.countRows("demo"));
}

test "store: crash mid-write leaves the old file; next write cleans up" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    var s = Store.init(std.testing.io, std.testing.allocator, try tmpHome(&tmp, &hb));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try s.upsert("demo", &.{try mkRow(a, "demo", "k1", "{\"t\":1}")});
    s.crash_before_rename = true;
    try std.testing.expectError(error.SimulatedCrash, s.upsert("demo", &.{try mkRow(a, "demo", "k2", "{\"t\":2}")}));
    try std.testing.expectEqual(@as(usize, 1), try s.countRows("demo")); // nothing from the failed write
    s.crash_before_rename = false;
    const st = try s.upsert("demo", &.{try mkRow(a, "demo", "k2", "{\"t\":2}")});
    try std.testing.expectEqual(@as(u32, 1), st.added);
    try std.testing.expectEqual(@as(usize, 2), try s.countRows("demo"));
}

test "store: a row can only enter its own cust; bad cust id refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    var s = Store.init(std.testing.io, std.testing.allocator, try tmpHome(&tmp, &hb));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.CustMismatch, s.upsert("demo", &.{try mkRow(a, "other", "k", "{\"t\":1}")}));
    try std.testing.expectError(error.BadCustId, s.upsert("../x", &.{}));
}

test "store: cursor paging and the daily fetch count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    var s = Store.init(std.testing.io, std.testing.allocator, try tmpHome(&tmp, &hb));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: [5]shape.Row = undefined;
    for (&rows, 0..) |*r, i| r.* = try mkRow(a, "demo", try std.fmt.allocPrint(a, "k{d}", .{i}), "{\"t\":1}");
    _ = try s.upsert("demo", &rows);
    const p1 = try s.rowsSince(a, "demo", 0, 2);
    try std.testing.expectEqual(@as(usize, 2), p1.rows.len);
    const p2 = try s.rowsSince(a, "demo", p1.next, 10);
    try std.testing.expectEqual(@as(usize, 3), p2.rows.len);
    const p3 = try s.rowsSince(a, "demo", p2.next, 10);
    try std.testing.expectEqual(@as(usize, 0), p3.rows.len);
    try s.bumpFetches("demo", 1_000, 3);
    try s.bumpFetches("demo", 2_000, 4);
    try s.bumpFetches("demo", 2 * day_ms, 9);
    try std.testing.expectEqual(@as(u32, 7), try s.fetchesToday("demo", 5_000));
    try std.testing.expectEqual(@as(u32, 0), try s.fetchesToday("nobody", 5_000));
}

test "store: second lock on the same cust is refused while held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    var s = Store.init(std.testing.io, std.testing.allocator, try tmpHome(&tmp, &hb));
    try s.ensure("demo");
    const l1 = try s.lock("demo");
    try std.testing.expect(std.meta.isError(s.lock("demo")));
    l1.release();
    const l2 = try s.lock("demo");
    l2.release();
}
