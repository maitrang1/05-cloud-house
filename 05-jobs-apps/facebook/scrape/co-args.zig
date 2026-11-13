// Tiny flag reader: `--name value` and bare `--flag`.
const std = @import("std");

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

test "flags" {
    const av = [_][]const u8{ "--cust", "a", "--dry-run", "--url", "u1", "--url", "u2" };
    try std.testing.expectEqualStrings("a", value(&av, "--cust").?);
    try std.testing.expect(has(&av, "--dry-run"));
    try std.testing.expect(value(&av, "--nope") == null);
    const us = try all(std.testing.allocator, &av, "--url");
    defer std.testing.allocator.free(us);
    try std.testing.expectEqual(@as(usize, 2), us.len);
}
