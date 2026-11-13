// Vault: per-cust secrets (Page tokens) in AES-256-GCM. The cust id is the AAD, so a blob copied into another cust's folder will not open.
// Master key: env var named in config (64 hex chars). Secrets never appear in logs, errors or output; names only.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const Err = error{ NoMasterKey, BadMasterKey, BadBlob, WrongKeyOrCust, NotFound, OutOfMemory, BadName };

pub const Vault = struct {
    io: Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    key: [32]u8,

    pub fn open(cx: *const ctx_mod.Ctx) Err!Vault {
        const hex = cx.envGet(cx.cfg.secrets.master_env) orelse return Err.NoMasterKey;
        var k: [32]u8 = undefined;
        if (hex.len != 64) return Err.BadMasterKey;
        _ = std.fmt.hexToBytes(&k, hex) catch return Err.BadMasterKey;
        return .{ .io = cx.io, .gpa = cx.gpa, .home = cx.home, .key = k };
    }

    fn path(self: *const Vault, a: std.mem.Allocator, cust: []const u8) ![]u8 {
        if (!ctx_mod.validId(cust)) return error.BadCustId;
        return std.fmt.allocPrint(a, "{s}/cust/{s}/secrets.enc", .{ self.home, cust });
    }

    fn load(self: *const Vault, a: std.mem.Allocator, cust: []const u8) !std.json.ArrayHashMap([]const u8) {
        const raw = util.readAll(a, self.io, try self.path(a, cust), 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return .{},
            else => return e,
        };
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \r\n"), ':');
        if (!std.mem.eql(u8, it.next() orelse return Err.BadBlob, "v1")) return Err.BadBlob;
        var nonce: [Aes.nonce_length]u8 = undefined;
        var tag: [Aes.tag_length]u8 = undefined;
        util.hexDecode(&nonce, it.next() orelse return Err.BadBlob) catch return Err.BadBlob;
        util.hexDecode(&tag, it.next() orelse return Err.BadBlob) catch return Err.BadBlob;
        const ch = it.next() orelse return Err.BadBlob;
        if (ch.len % 2 != 0) return Err.BadBlob;
        const ct = try a.alloc(u8, ch.len / 2);
        util.hexDecode(ct, ch) catch return Err.BadBlob;
        const pt = try a.alloc(u8, ct.len);
        Aes.decrypt(pt, ct, tag, cust, nonce, self.key) catch return Err.WrongKeyOrCust;
        const m = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, pt, .{ .allocate = .alloc_always }) catch return Err.BadBlob;
        return m;
    }

    fn save(self: *const Vault, a: std.mem.Allocator, cust: []const u8, m: std.json.ArrayHashMap([]const u8)) !void {
        const pt = try std.json.Stringify.valueAlloc(a, m, .{});
        var nonce: [Aes.nonce_length]u8 = undefined;
        self.io.random(&nonce);
        const ct = try a.alloc(u8, pt.len);
        var tag: [Aes.tag_length]u8 = undefined;
        Aes.encrypt(ct, &tag, pt, cust, nonce, self.key);
        const out = try std.fmt.allocPrint(a, "v1:{s}:{s}:{s}\n", .{ std.fmt.bytesToHex(nonce, .lower), std.fmt.bytesToHex(tag, .lower), try util.hexEncode(a, ct) });
        try util.mkdirp(self.io, try std.fmt.allocPrint(a, "{s}/cust/{s}", .{ self.home, cust }));
        try util.writeAtomic(a, self.io, try self.path(a, cust), out);
    }

    pub fn put(self: *const Vault, cust: []const u8, name: []const u8, value: []const u8) !void {
        if (name.len == 0 or name.len > 64) return Err.BadName;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var m = try self.load(a, cust);
        try m.map.put(a, try a.dupe(u8, name), try a.dupe(u8, value));
        try self.save(a, cust, m);
    }

    // several names in one atomic write (token pairs must rotate together)
    pub fn putMany(self: *const Vault, cust: []const u8, kv: []const [2][]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var m = try self.load(a, cust);
        for (kv) |p| try m.map.put(a, try a.dupe(u8, p[0]), try a.dupe(u8, p[1]));
        try self.save(a, cust, m);
    }

    // caller frees with `alloc`
    pub fn get(self: *const Vault, alloc: std.mem.Allocator, cust: []const u8, name: []const u8) !?[]u8 {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const m = try self.load(arena.allocator(), cust);
        const v = m.map.get(name) orelse return null;
        return try alloc.dupe(u8, v);
    }

    pub fn names(self: *const Vault, a: std.mem.Allocator, cust: []const u8) ![]const []const u8 {
        const m = try self.load(a, cust);
        var l: std.ArrayList([]const u8) = .empty;
        var it = m.map.iterator();
        while (it.next()) |e| try l.append(a, e.key_ptr.*);
        return l.toOwnedSlice(a);
    }

    pub fn exists(self: *const Vault, cust: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        return util.exists(self.io, self.path(arena.allocator(), cust) catch return false);
    }
};

fn testKey(env: *std.process.Environ.Map) !void {
    try env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
}

test "vault: roundtrip, file holds no plaintext, other cust cannot open the blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try testKey(&env);
    const cx = ctx_mod.testCtx(a, &env, home);
    const v = try Vault.open(&cx);
    try v.put("alpha", "oa_access", "TOKEN-SECRET-123");
    try v.put("alpha", "oa_refresh", "REFRESH-SECRET-456");
    const got = (try v.get(a, "alpha", "oa_access")).?;
    try std.testing.expectEqualStrings("TOKEN-SECRET-123", got);
    try std.testing.expect((try v.get(a, "alpha", "nope")) == null);
    const raw = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/alpha/secrets.enc", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, raw, "SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "oa_access") == null);
    const ns = try v.names(a, "alpha");
    try std.testing.expectEqual(@as(usize, 2), ns.len);
    // copy alpha's blob into beta: must not open (AAD = cust id)
    try util.mkdirp(cx.io, try std.fmt.allocPrint(a, "{s}/cust/beta", .{home}));
    try util.writeAtomic(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/beta/secrets.enc", .{home}), raw);
    try std.testing.expectError(Err.WrongKeyOrCust, v.get(a, "beta", "oa_access"));
    // tamper
    var bad = try a.dupe(u8, raw);
    bad[bad.len - 3] = if (bad[bad.len - 3] == '0') '1' else '0';
    try util.writeAtomic(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/alpha/secrets.enc", .{home}), bad);
    try std.testing.expectError(Err.WrongKeyOrCust, v.get(a, "alpha", "oa_access"));
}

test "vault: no master key / bad master key refused; nonce differs per save" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const cx = ctx_mod.testCtx(arena.allocator(), &env, ".zig-cache/tmp/none");
    try std.testing.expectError(Err.NoMasterKey, Vault.open(&cx));
    try env.put("SCRAPE_MASTER_KEY", "tooshort");
    try std.testing.expectError(Err.BadMasterKey, Vault.open(&cx));
    try env.put("SCRAPE_MASTER_KEY", "zz" ++ "0" ** 62);
    try std.testing.expectError(Err.BadMasterKey, Vault.open(&cx));
}

test "vault: bad names refused, putMany is one write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try testKey(&env);
    const cx = ctx_mod.testCtx(a, &env, home);
    const v = try Vault.open(&cx);
    try std.testing.expectError(Err.BadName, v.put("a", "", "x"));
    try v.putMany("a", &.{ .{ "k1", "v1" }, .{ "k2", "v2" } });
    try std.testing.expectEqualStrings("v2", (try v.get(a, "a", "k2")).?);
    try std.testing.expectError(error.BadCustId, v.put("../a", "k", "v"));
}
