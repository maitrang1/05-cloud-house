// Vendor credit ledger (ops level, one file): stop at stop_pct of the monthly budget. Header-reported cost overrides the default.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const shape = @import("rw-shape.zig");

// year*100+month from unix ms (civil-from-days)
pub fn ymOf(ms: i64) u32 {
    const z = @divFloor(ms, 86_400_000) + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const yy: i64 = if (m <= 2) y + 1 else y;
    return @intCast(yy * 100 + m);
}

pub const Quota = struct {
    io: Io,
    gpa: std.mem.Allocator,
    home: []const u8,

    fn file(self: *const Quota, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}/vendors/use.log", .{self.home});
    }

    pub fn used(self: *const Quota, vendor: []const u8, ym: u32) !u64 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const txt = util.readAll(a, self.io, try self.file(a), 64 * 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        var total: u64 = 0;
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |ln| {
            var f = std.mem.tokenizeScalar(u8, ln, ' ');
            const ts = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
            const v = f.next() orelse continue;
            _ = f.next() orelse continue; // cust
            const c = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            if (std.mem.eql(u8, v, vendor) and ymOf(ts) == ym) total += c;
        }
        return total;
    }

    // budget 0 = no cap. Otherwise refuse once used >= budget * stop_pct / 100.
    pub fn allow(self: *const Quota, d: shape.VendorDef, stop_pct: u32, now: i64) !bool {
        if (d.budget == 0) return true;
        const limit: u64 = @as(u64, d.budget) * stop_pct / 100;
        return (try self.used(d.id, ymOf(now))) < limit;
    }

    pub fn record(self: *const Quota, vendor: []const u8, cust: []const u8, credits: u32, now: i64) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try util.mkdirp(self.io, try std.fmt.allocPrint(a, "{s}/vendors", .{self.home}));
        try util.appendLine(self.io, try self.file(a), try std.fmt.allocPrint(a, "{d} {s} {s} {d}", .{ now, vendor, cust, credits }));
    }
};

test "ym from ms" {
    try std.testing.expectEqual(@as(u32, 197001), ymOf(0));
    try std.testing.expectEqual(@as(u32, 202611), ymOf(1_794_000_000_000)); // 2026-11-06
    try std.testing.expectEqual(@as(u32, 202403), ymOf(1_709_251_200_000)); // 2024-03-01 00:00 UTC
}

test "pool of 10 stops at 8; month rollover resets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const q = Quota{ .io = std.testing.io, .gpa = std.testing.allocator, .home = home };
    const d = shape.VendorDef{ .id = "v", .base = "https://x/", .auth = .query, .key_env = "K", .budget = 10 };
    const now: i64 = 1_794_000_000_000;
    var n: u32 = 0;
    while (try q.allow(d, 80, now)) : (n += 1) try q.record("v", "demo", 1, now);
    try std.testing.expectEqual(@as(u32, 8), n);
    try std.testing.expect(!(try q.allow(d, 80, now)));
    // next month: fresh
    try std.testing.expect(try q.allow(d, 80, now + 40 * 86_400_000));
    // other vendor unaffected; budget 0 = unlimited
    const d2 = shape.VendorDef{ .id = "w", .base = "https://x/", .auth = .query, .key_env = "K", .budget = 0 };
    try std.testing.expect(try q.allow(d2, 80, now));
}
