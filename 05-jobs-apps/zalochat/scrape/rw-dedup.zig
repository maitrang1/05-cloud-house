// Idempotency: a row is identified by cust_id + key + hash. Same triple = same row, never stored twice.
const std = @import("std");

pub fn idem(alloc: std.mem.Allocator, cust: []const u8, key: []const u8, hash: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x1f{s}\x1f{s}", .{ cust, key, hash });
}

pub const Seen = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,
    arena: std.mem.Allocator,

    pub fn has(self: *Seen, cust: []const u8, key: []const u8, hash: []const u8) !bool {
        var buf: [1024]u8 = undefined;
        if (cust.len + key.len + hash.len + 2 <= buf.len) {
            const k = std.fmt.bufPrint(&buf, "{s}\x1f{s}\x1f{s}", .{ cust, key, hash }) catch unreachable;
            return self.set.contains(k);
        }
        return self.set.contains(try idem(self.arena, cust, key, hash));
    }
    // true when newly added
    pub fn add(self: *Seen, cust: []const u8, key: []const u8, hash: []const u8) !bool {
        const k = try idem(self.arena, cust, key, hash);
        const g = try self.set.getOrPut(self.arena, k);
        return !g.found_existing;
    }
};

test "seen set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Seen{ .arena = arena.allocator() };
    try std.testing.expect(try s.add("a", "k", "h"));
    try std.testing.expect(!(try s.add("a", "k", "h")));
    try std.testing.expect(try s.add("b", "k", "h")); // other cust = other row
    try std.testing.expect(try s.add("a", "k", "h2")); // changed content = new version
    try std.testing.expect(try s.has("a", "k", "h"));
    try std.testing.expect(!(try s.has("c", "k", "h")));
}
