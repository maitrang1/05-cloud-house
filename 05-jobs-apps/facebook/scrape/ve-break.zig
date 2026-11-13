// Circuit breaker + dead-key switch per vendor, persisted so scheduled runs share it. State file: "<fails> <opened_ms> <dead 0|1>".
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");

const State = struct { fails: u32 = 0, opened_ms: i64 = 0, dead: bool = false };

pub const Breaker = struct {
    io: Io,
    gpa: std.mem.Allocator,
    home: []const u8,

    fn path(self: *const Breaker, a: std.mem.Allocator, v: []const u8) ![]u8 {
        for (v) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.BadVendorId;
        return std.fmt.allocPrint(a, "{s}/vendors/state-{s}.txt", .{ self.home, v });
    }
    fn load(self: *const Breaker, a: std.mem.Allocator, v: []const u8) !State {
        const t = util.readAll(a, self.io, try self.path(a, v), 1024) catch |e| switch (e) {
            error.FileNotFound => return .{},
            else => return e,
        };
        var f = std.mem.tokenizeAny(u8, t, " \n");
        const fails = std.fmt.parseInt(u32, f.next() orelse return .{}, 10) catch return .{};
        const op = std.fmt.parseInt(i64, f.next() orelse return .{}, 10) catch return .{};
        const dead = std.mem.eql(u8, f.next() orelse "0", "1");
        return .{ .fails = fails, .opened_ms = op, .dead = dead };
    }
    fn save(self: *const Breaker, a: std.mem.Allocator, v: []const u8, s: State) !void {
        try util.mkdirp(self.io, try std.fmt.allocPrint(a, "{s}/vendors", .{self.home}));
        const t = try std.fmt.allocPrint(a, "{d} {d} {d}\n", .{ s.fails, s.opened_ms, @as(u8, if (s.dead) 1 else 0) });
        try util.writeAtomic(a, self.io, try self.path(a, v), t);
    }

    pub fn isDead(self: *const Breaker, v: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        return (try self.load(arena.allocator(), v)).dead;
    }
    // open = recent consecutive failures >= max and still inside the cool-down
    pub fn isOpen(self: *const Breaker, v: []const u8, now: i64, max_fails: u32, cool_s: u32) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const s = try self.load(arena.allocator(), v);
        if (s.fails < max_fails) return false;
        return now - s.opened_ms < @as(i64, cool_s) * 1000;
    }
    pub fn fail(self: *const Breaker, v: []const u8, now: i64) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var s = try self.load(a, v);
        s.fails +|= 1;
        s.opened_ms = now;
        try self.save(a, v, s);
    }
    pub fn ok(self: *const Breaker, v: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var s = try self.load(a, v);
        if (s.fails == 0) return;
        s.fails = 0;
        try self.save(a, v, s);
    }
    // a rejected key (401/403 from the vendor) switches the vendor off until an operator revives it
    pub fn kill(self: *const Breaker, v: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var s = try self.load(a, v);
        s.dead = true;
        try self.save(a, v, s);
    }
    pub fn revive(self: *const Breaker, v: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        try self.save(arena.allocator(), v, .{});
    }
};

test "breaker opens after N fails, cools down, resets on ok; dead sticks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const b = Breaker{ .io = std.testing.io, .gpa = std.testing.allocator, .home = home };
    try std.testing.expect(!(try b.isOpen("v", 1000, 3, 60)));
    try b.fail("v", 1000);
    try b.fail("v", 1000);
    try std.testing.expect(!(try b.isOpen("v", 1000, 3, 60)));
    try b.fail("v", 1000);
    try std.testing.expect(try b.isOpen("v", 2000, 3, 60));
    try std.testing.expect(!(try b.isOpen("v", 1000 + 61_000, 3, 60))); // cooled
    try b.ok("v");
    try std.testing.expect(!(try b.isOpen("v", 2000, 3, 60)));
    try std.testing.expect(!(try b.isDead("v")));
    try b.kill("v");
    try std.testing.expect(try b.isDead("v"));
    try b.revive("v");
    try std.testing.expect(!(try b.isDead("v")));
    try std.testing.expectError(error.BadVendorId, b.kill("../x"));
}
