// Usage ledger: one entry per OK run (pages + vendor credits from the vendors' own headers). A failed run writes nothing.
const std = @import("std");
const store_mod = @import("rw-store.zig");
const util = @import("co-util.zig");
const quota = @import("ve-quota.zig");

pub const Totals = struct { runs: u32 = 0, pages: u64 = 0, credits: u64 = 0 };

pub fn record(st: *const store_mod.Store, cust: []const u8, now: i64, job: []const u8, pages: u32, credits: u32) !void {
    var b: [160]u8 = undefined;
    const ln = try std.fmt.bufPrint(&b, "{d} {s} {d} {d}", .{ now, job, pages, credits });
    try st.appendLog(cust, "usage.log", ln);
}

pub fn month(st: *const store_mod.Store, cust: []const u8, now: i64) !Totals {
    var arena = std.heap.ArenaAllocator.init(st.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const txt = util.readAll(a, st.io, try st.path(a, cust, "usage.log"), 64 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    var t = Totals{};
    const ym = quota.ymOf(now);
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |ln| {
        var f = std.mem.tokenizeScalar(u8, ln, ' ');
        const ts = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
        _ = f.next() orelse continue;
        const p = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const c = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        if (quota.ymOf(ts) != ym) continue;
        t.runs += 1;
        t.pages += p;
        t.credits += c;
    }
    return t;
}

test "meter sums the month; other cust unaffected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const st = store_mod.Store.init(std.testing.io, std.testing.allocator, try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path}));
    const now: i64 = 1_794_000_000_000;
    try record(&st, "a", now, "scan", 3, 5);
    try record(&st, "a", now + 1000, "scan", 2, 0);
    try record(&st, "a", now - 40 * 86_400_000, "scan", 9, 9);
    const t = try month(&st, "a", now);
    try std.testing.expectEqual(@as(u32, 2), t.runs);
    try std.testing.expectEqual(@as(u64, 5), t.pages);
    try std.testing.expectEqual(@as(u64, 5), t.credits);
    try std.testing.expectEqual(@as(u32, 0), (try month(&st, "b", now)).runs);
}
