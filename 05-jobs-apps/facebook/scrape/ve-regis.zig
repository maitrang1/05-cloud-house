// Vendor registry: vendors are DATA rows (df-scrape-vendors.json), never code.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const shape = @import("rw-shape.zig");

pub const Registry = struct {
    defs: []const shape.VendorDef,

    pub fn find(self: Registry, id: []const u8) ?shape.VendorDef {
        for (self.defs) |d| if (std.mem.eql(u8, d.id, id)) return d;
        return null;
    }
    // vendors in the configured order; ids not in the file are skipped, `on:false` skipped
    pub fn ladder(self: Registry, a: std.mem.Allocator, order: []const []const u8) ![]shape.VendorDef {
        var l: std.ArrayList(shape.VendorDef) = .empty;
        for (order) |id| if (self.find(id)) |d| if (d.on) try l.append(a, d);
        return l.toOwnedSlice(a);
    }
};

pub fn load(a: std.mem.Allocator, io: Io, path: []const u8, mock: bool) !Registry {
    const t = try util.readAll(a, io, path, 256 * 1024);
    const f = try shape.parseVendors(a, t, mock);
    return .{ .defs = f.vendors };
}

// API key from the env var NAMED in the registry; empty = missing
pub fn keyOf(env: *const std.process.Environ.Map, d: shape.VendorDef) ?[]const u8 {
    const v = env.get(d.key_env) orelse return null;
    return if (v.len == 0) null else v;
}

test "registry loads the shipped file and finds vendors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try load(arena.allocator(), std.testing.io, "df-scrape-vendors.json", false);
    try std.testing.expect(r.find("scrapecreators") != null);
    try std.testing.expect(r.find("nope") == null);
    const lad = try r.ladder(arena.allocator(), &.{ "scrapecreators", "ghost", "apify", "brightdata" });
    try std.testing.expectEqual(@as(usize, 2), lad.len);
}
