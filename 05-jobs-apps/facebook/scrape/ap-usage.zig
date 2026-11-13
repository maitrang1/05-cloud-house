// Meta usage headers: X-App-Usage and X-Business-Use-Case-Usage. Highest percent wins. Slow at slow_pct, stop at stop_pct.
const std = @import("std");

pub const Verdict = enum { go, slow, stop };
pub const Usage = struct { pct: u32 = 0, regain_min: u32 = 0 };

const keys = [_][]const u8{ "call_count", "total_time", "total_cputime" };

fn walk(v: std.json.Value, u: *Usage) void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const val = e.value_ptr.*;
                const num: ?u32 = switch (val) {
                    .integer => |n| if (n < 0) 0 else @intCast(@min(n, 100000)),
                    .float => |f| if (f < 0) 0 else @intFromFloat(@min(f, 100000)),
                    else => null,
                };
                if (num) |n| {
                    for (keys) |k| {
                        if (std.mem.eql(u8, e.key_ptr.*, k)) u.pct = @max(u.pct, n);
                    }
                    if (std.mem.eql(u8, e.key_ptr.*, "estimated_time_to_regain_access")) u.regain_min = @max(u.regain_min, n);
                } else walk(val, u);
            }
        },
        .array => |arr| for (arr.items) |x| walk(x, u),
        else => {},
    }
}

// both headers are JSON text; a missing or broken header counts as 0 (never blocks a call on a parse slip)
pub fn parse(a: std.mem.Allocator, app_hdr: []const u8, buc_hdr: []const u8) Usage {
    var u = Usage{};
    for ([_][]const u8{ app_hdr, buc_hdr }) |h| {
        if (h.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, h, .{}) catch continue;
        walk(v, &u);
    }
    return u;
}

pub fn verdict(u: Usage, slow_pct: u32, stop_pct: u32) Verdict {
    if (u.pct >= stop_pct) return .stop;
    if (u.pct >= slow_pct) return .slow;
    return .go;
}

test "usage: app header, business header, verdicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(u32, 28), parse(a, "{\"call_count\":28,\"total_time\":25,\"total_cputime\":20}", "").pct);
    const b = parse(a, "", "{\"1234\":[{\"type\":\"pages\",\"call_count\":10,\"total_time\":85,\"total_cputime\":12,\"estimated_time_to_regain_access\":7}]}");
    try std.testing.expectEqual(@as(u32, 85), b.pct);
    try std.testing.expectEqual(@as(u32, 7), b.regain_min);
    try std.testing.expectEqual(@as(u32, 0), parse(a, "not json", "").pct);
    try std.testing.expectEqual(Verdict.go, verdict(.{ .pct = 79 }, 80, 95));
    try std.testing.expectEqual(Verdict.slow, verdict(.{ .pct = 85 }, 80, 95));
    try std.testing.expectEqual(Verdict.stop, verdict(.{ .pct = 96 }, 80, 95));
}
