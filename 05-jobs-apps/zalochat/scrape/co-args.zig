// Tiny flag reader: `--name value` and bare `--flag`.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");

pub fn value(av: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < av.len) : (i += 1) if (std.mem.eql(u8, av[i], name)) return av[i + 1];
    return null;
}
pub fn has(av: []const []const u8, name: []const u8) bool {
    for (av) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}
// all values of a repeatable flag
pub fn all(a: std.mem.Allocator, av: []const []const u8, name: []const u8) ![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i + 1 < av.len) : (i += 1) if (std.mem.eql(u8, av[i], name)) try l.append(a, av[i + 1]);
    return l.toOwnedSlice(a);
}

// --cust ID, validated; prints a what/why/fix line and returns null on a problem
pub fn custArg(cx: *ctx_mod.Ctx, av: []const []const u8) ?[]const u8 {
    const c = value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: this works on one cust\nfix: add --cust ID\n", .{});
        return null;
    };
    if (!ctx_mod.validId(c)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ - (max 64)\nfix: use a safe id\n", .{});
        return null;
    }
    return c;
}

test "flags" {
    const av = [_][]const u8{ "--cust", "a", "--dry-run", "--url", "u1", "--url", "u2" };
    try std.testing.expectEqualStrings("a", value(&av, "--cust").?);
    try std.testing.expect(has(&av, "--dry-run"));
    try std.testing.expect(value(&av, "--nope") == null);
    const us = try all(std.testing.allocator, &av, "--url");
    defer std.testing.allocator.free(us);
    try std.testing.expectEqual(@as(usize, 2), us.len);
}
