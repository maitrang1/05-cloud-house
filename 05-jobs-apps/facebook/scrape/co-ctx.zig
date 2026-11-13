// App context: io, allocators, config, home dir, env. One place for per-cust paths (every path carries cust_id).
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");
const util = @import("co-util.zig");
const guard = @import("co-guard.zig");
const regis = @import("ve-regis.zig");

pub const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator, // process-lifetime (config strings)
    env: *std.process.Environ.Map,
    cfg: cfg_mod.Config,
    home: []const u8,
    exe_dir: []const u8 = "",
    cfg_dir: []const u8 = ".", // vendor.file etc. are relative to the config file
    vendor_reg: ?regis.Registry = null, // test hook: skip the file
    fake_gap: bool = false, // tests only: no real waiting between requests
    mock: bool = false, // build option: loopback http allowed
    resolver: guard.Resolver = .{},
    // test hook: fixed clock (ms); 0 = real
    fake_now_ms: i64 = 0,

    pub fn nowMs(self: *const Ctx) i64 {
        return if (self.fake_now_ms != 0) self.fake_now_ms else util.nowMs(self.io);
    }
    // relative paths from the config resolve against the config file's folder
    pub fn rel(self: *const Ctx, a: std.mem.Allocator, p: []const u8) ![]u8 {
        if (p.len > 0 and (p[0] == '/' or (p.len > 2 and p[1] == ':'))) return a.dupe(u8, p);
        return std.fmt.allocPrint(a, "{s}/{s}", .{ self.cfg_dir, p });
    }
    pub fn envGet(self: *const Ctx, key: []const u8) ?[]const u8 {
        const v = self.env.get(key) orelse return null;
        return if (v.len == 0) null else v;
    }
    // cust dir: <home>/cust/<id>[/sub]. Caller frees.
    pub fn custPath(self: *const Ctx, alloc: std.mem.Allocator, cust: []const u8, sub: []const u8) ![]u8 {
        if (!validId(cust)) return error.BadCustId;
        if (sub.len == 0) return std.fmt.allocPrint(alloc, "{s}/cust/{s}", .{ self.home, cust });
        return std.fmt.allocPrint(alloc, "{s}/cust/{s}/{s}", .{ self.home, cust, sub });
    }
};

// cust id: 1..64 of [a-z0-9_-], so it can never escape a folder
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn resolveHome(arena: std.mem.Allocator, env: *std.process.Environ.Map, cfg_home: []const u8) ![]const u8 {
    if (cfg_home.len > 0) return cfg_home;
    if (env.get("SCRAPE_HOME")) |h| if (h.len > 0) return arena.dupe(u8, h);
    if (env.get("HOME")) |h| return std.fmt.allocPrint(arena, "{s}/.facebook-scrape", .{h});
    if (env.get("USERPROFILE")) |h| return std.fmt.allocPrint(arena, "{s}/.facebook-scrape", .{h});
    return error.NoHome;
}

test "cust ids cannot escape" {
    try std.testing.expect(validId("cust-01_a"));
    try std.testing.expect(!validId(""));
    try std.testing.expect(!validId("../x"));
    try std.testing.expect(!validId("a/b"));
    try std.testing.expect(!validId("A"));
}

// test helper: Ctx on a temp home with default config (mock arena = testing allocator arena)
pub fn testCtx(arena: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8) Ctx {
    util.quiet = true;
    return .{ .io = std.testing.io, .gpa = std.testing.allocator, .arena = arena, .env = env, .cfg = .{}, .home = home };
}
