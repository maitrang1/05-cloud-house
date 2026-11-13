// =====================================================================
// Des: Reads the GitHub login and token from the `gh` program, so this app no longer depends on another app's vault for them
// Flo: run `gh <token args>` and `gh <login args>` > keep the output only when the program succeeded > hand both back (empty = unknown)
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Tool, program name (tool.ghcl), argument lists (ghcl.toke, ghcl.user from 00-config.json)
// Out: Ident{ token, login } - empty strings when gh is missing, logged out or answers nothing
// Run: not run directly - imported by main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const tool = @import("tool-exec.zig");

pub const Ident = struct { token: []const u8, login: []const u8 };

// one `gh` call; a missing program or a non-zero exit is "unknown", never an error ----
fn ask(gpa: std.mem.Allocator, tl: *tool.Tool, prog: []const u8, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return "";
    const argv = try gpa.alloc([]const u8, args.len + 1);
    argv[0] = prog;
    @memcpy(argv[1..], args);
    const res = tl.runz(argv, null) catch |erro| return if (erro == error.ToolMiss) "" else erro;
    if (!res.okay()) return "";
    return try gpa.dupe(u8, res.text());
}

pub fn read(gpa: std.mem.Allocator, tl: *tool.Tool, prog: []const u8, toke_args: []const []const u8, user_args: []const []const u8) !Ident {
    return .{ .token = try ask(gpa, tl, prog, toke_args), .login = try ask(gpa, tl, prog, user_args) };
}

test "a program that answers is read, one that fails or is missing gives empty strings" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const audi = @import("audit-log.zig");
    var logz = audi.Audi{ .io = std.testing.io, .path = "" };
    var pare = std.process.Environ.Map.init(gpa);
    if (std.c.getenv("PATH")) |pp| try pare.put("PATH", std.mem.span(pp));
    var tl = try tool.Tool.init(gpa, std.testing.io, &logz, &pare, 20);
    if (!tl.have("echo")) return error.SkipZigTest;
    const got = try read(gpa, &tl, "echo", &.{"gho_testvalue"}, &.{"someone"});
    try std.testing.expectEqualStrings("gho_testvalue", got.token);
    try std.testing.expectEqualStrings("someone", got.login);
    const none = try read(gpa, &tl, "zz-no-such-program-9f3k", &.{"x"}, &.{"y"});
    try std.testing.expectEqualStrings("", none.token);
    try std.testing.expectEqualStrings("", none.login);
    const off = try read(gpa, &tl, "echo", &.{}, &.{});
    try std.testing.expectEqualStrings("", off.token);
    if (tl.have("sh")) { // a failing program that still printed something must not be taken as an answer
        const fail = try read(gpa, &tl, "sh", &.{ "-c", "echo oops; exit 3" }, &.{ "-c", "echo oops; exit 3" });
        try std.testing.expectEqualStrings("", fail.token);
        try std.testing.expectEqualStrings("", fail.login);
    }
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
