// =====================================================================
// Des: Keeps passwords, tokens and codes in one local file locked with a passphrase, so no secret ever sits in git, logs or plain text
// Flo: passphrase > Argon2id key > AES-256-GCM open > name/value pairs in memory > change > seal with fresh salt and nonce > .part + rename
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: vault file path, passphrase, Argon2 cost (time, memory KiB, lanes)
// Out: Vault (getz / putz / drop / save) | VaulErro (BadKey = wrong passphrase or damaged file)
// Run: not run directly - imported by app-ctx.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const argon2 = std.crypto.pwhash.argon2;

pub const MAGIC = "CHGV1";
const SALT = 16;
const NONCE = Aes.nonce_length;
const TAG = Aes.tag_length;
const COST = 12;
const HEAD = MAGIC.len + COST + SALT + NONCE;
const CF = .{ .file_maxz = 4 * 1024 * 1024, .part = ".part", .memo_minz = 8, .memo_maxz = 1048576, .time_maxz = 16, .para_maxz = 8 };

pub const VaulErro = error{ NotSealed, BadKey, Unreadable, WriteFail, NoRandom, OutOfMemory };

pub const Cost = struct { time: u32, memo: u32, para: u32 };

const Pair = struct { keyz: []const u8, valu: []const u8 };

fn derive(a: std.mem.Allocator, io: std.Io, pass: []const u8, salt: []const u8, cost: Cost) VaulErro![32]u8 {
    var k: [32]u8 = undefined;
    argon2.kdf(a, &k, pass, salt, .{ .t = cost.time, .m = cost.memo, .p = @intCast(cost.para) }, .argon2id, io) catch return error.OutOfMemory;
    return k;
}

fn costOkay(c: Cost) bool {
    return c.time >= 1 and c.time <= CF.time_maxz and c.memo >= CF.memo_minz and c.memo <= CF.memo_maxz and c.para >= 1 and c.para <= CF.para_maxz;
}

// the cost travels in the file head and is signed with the text, so it cannot be lowered unseen ----
pub fn seal(a: std.mem.Allocator, io: std.Io, pass: []const u8, plain: []const u8, cost: Cost) VaulErro![]u8 {
    const out = try a.alloc(u8, HEAD + plain.len + TAG);
    errdefer a.free(out);
    @memcpy(out[0..MAGIC.len], MAGIC);
    std.mem.writeInt(u32, out[MAGIC.len..][0..4], cost.time, .little);
    std.mem.writeInt(u32, out[MAGIC.len + 4 ..][0..4], cost.memo, .little);
    std.mem.writeInt(u32, out[MAGIC.len + 8 ..][0..4], cost.para, .little);
    const salt = out[MAGIC.len + COST ..][0..SALT];
    const nonce = out[MAGIC.len + COST + SALT ..][0..NONCE];
    io.randomSecure(salt) catch return error.NoRandom;
    io.randomSecure(nonce) catch return error.NoRandom;
    var key = try derive(a, io, pass, salt, cost);
    defer std.crypto.secureZero(u8, &key);
    var tag: [TAG]u8 = undefined;
    Aes.encrypt(out[HEAD..][0..plain.len], &tag, plain, out[0 .. MAGIC.len + COST], nonce.*, key);
    @memcpy(out[out.len - TAG ..], &tag);
    return out;
}

pub fn unseal(a: std.mem.Allocator, io: std.Io, pass: []const u8, blob: []const u8) VaulErro![]u8 {
    if (blob.len < HEAD + TAG or !std.mem.startsWith(u8, blob, MAGIC)) return error.NotSealed;
    const cost: Cost = .{ .time = std.mem.readInt(u32, blob[MAGIC.len..][0..4], .little), .memo = std.mem.readInt(u32, blob[MAGIC.len + 4 ..][0..4], .little), .para = std.mem.readInt(u32, blob[MAGIC.len + 8 ..][0..4], .little) };
    if (!costOkay(cost)) return error.NotSealed;
    const salt = blob[MAGIC.len + COST ..][0..SALT];
    const nonce = blob[MAGIC.len + COST + SALT ..][0..NONCE].*;
    const text = blob[HEAD .. blob.len - TAG];
    const tag = blob[blob.len - TAG ..][0..TAG].*;
    var key = try derive(a, io, pass, salt, cost);
    defer std.crypto.secureZero(u8, &key);
    const plain = try a.alloc(u8, text.len);
    Aes.decrypt(plain, text, tag, blob[0 .. MAGIC.len + COST], nonce, key) catch {
        a.free(plain);
        return error.BadKey;
    };
    return plain;
}

pub const Vault = struct {
    a: std.mem.Allocator,
    path: []const u8,
    pass: []const u8,
    cost: Cost,
    list: std.ArrayList(Pair) = .empty,
    fresh: bool = true,

    pub fn getz(self: *const Vault, keyz: []const u8) ?[]const u8 {
        for (self.list.items) |p| if (std.mem.eql(u8, p.keyz, keyz)) return p.valu;
        return null;
    }

    pub fn putz(self: *Vault, keyz: []const u8, valu: []const u8) VaulErro!void {
        const copy = try self.a.dupe(u8, valu);
        for (self.list.items) |*p| if (std.mem.eql(u8, p.keyz, keyz)) {
            p.valu = copy;
            return;
        };
        try self.list.append(self.a, .{ .keyz = try self.a.dupe(u8, keyz), .valu = copy });
    }

    pub fn drop(self: *Vault, keyz: []const u8) bool {
        for (self.list.items, 0..) |p, i| if (std.mem.eql(u8, p.keyz, keyz)) {
            _ = self.list.orderedRemove(i);
            return true;
        };
        return false;
    }

    pub fn save(self: *Vault, io: std.Io) VaulErro!void {
        const text = std.json.Stringify.valueAlloc(self.a, self.list.items, .{}) catch return error.OutOfMemory;
        const blob = try seal(self.a, io, self.pass, text, self.cost);
        const part = std.mem.concat(self.a, u8, &.{ self.path, CF.part }) catch return error.OutOfMemory;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.path)) |d| cwd.createDirPath(io, d) catch return error.WriteFail;
        {
            // owner-only on POSIX; Windows keeps the profile folder's own access list ----
            const f = cwd.createFile(io, part, if (comptime builtin.os.tag == .windows) .{} else .{ .permissions = .fromMode(0o600) }) catch return error.WriteFail;
            defer f.close(io);
            f.writePositionalAll(io, blob, 0) catch return error.WriteFail;
        }
        cwd.rename(part, cwd, self.path, io) catch return error.WriteFail;
        self.fresh = false;
    }
};

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// a missing file opens as an empty vault; a present file must open with this passphrase ----
pub fn open(io: std.Io, a: std.mem.Allocator, path: []const u8, pass: []const u8, cost: Cost) VaulErro!Vault {
    var v: Vault = .{ .a = a, .path = try a.dupe(u8, path), .pass = try a.dupe(u8, pass), .cost = cost };
    const blob = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| {
        return if (e == error.FileNotFound) v else error.Unreadable;
    };
    const plain = try unseal(a, io, pass, blob);
    const pairs = std.json.parseFromSliceLeaky([]const Pair, a, plain, .{ .allocate = .alloc_always }) catch return error.BadKey;
    try v.list.appendSlice(a, pairs);
    v.fresh = false;
    return v;
}

const TEST_COST: Cost = .{ .time = 1, .memo = 8, .para = 1 };

test "seal and unseal; wrong pass, flipped byte, lowered cost and short blob fail" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const blob = try seal(a, io, "pass one", "SECRET-123", TEST_COST);
    defer a.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "SECRET-123") == null);
    const back = try unseal(a, io, "pass one", blob);
    defer a.free(back);
    try std.testing.expectEqualStrings("SECRET-123", back);
    try std.testing.expectError(error.BadKey, unseal(a, io, "pass two", blob));
    blob[HEAD + 2] ^= 1;
    try std.testing.expectError(error.BadKey, unseal(a, io, "pass one", blob));
    blob[HEAD + 2] ^= 1;
    std.mem.writeInt(u32, blob[MAGIC.len + 4 ..][0..4], 16, .little);
    try std.testing.expectError(error.BadKey, unseal(a, io, "pass one", blob));
    std.mem.writeInt(u32, blob[MAGIC.len + 4 ..][0..4], 1, .little);
    try std.testing.expectError(error.NotSealed, unseal(a, io, "pass one", blob));
    try std.testing.expectError(error.NotSealed, unseal(a, io, "pass one", "CHGV1short"));
    const twin = try seal(a, io, "pass one", "SECRET-123", TEST_COST);
    defer a.free(twin);
    try std.testing.expect(!std.mem.eql(u8, blob[MAGIC.len + COST ..], twin[MAGIC.len + COST ..]));
}

test "vault file: put, save, reopen, drop; wrong passphrase never opens or overwrites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "v", "main.vault" });
    try std.testing.expect(!exists(io, path));
    var v = try open(io, a, path, "pw", TEST_COST);
    try std.testing.expect(v.fresh);
    try v.putz("auth.toke", "tok-AAA");
    try v.putz("acct.pass", "p1");
    try v.putz("acct.pass", "p2");
    try v.save(io);
    try std.testing.expect(exists(io, path));
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, raw, "tok-AAA") == null);
    var w = try open(io, a, path, "pw", TEST_COST);
    try std.testing.expectEqualStrings("tok-AAA", w.getz("auth.toke").?);
    try std.testing.expectEqualStrings("p2", w.getz("acct.pass").?);
    try std.testing.expect(w.getz("none") == null);
    try std.testing.expect(w.drop("auth.toke"));
    try std.testing.expect(!w.drop("auth.toke"));
    try w.save(io);
    const x = try open(io, a, path, "pw", TEST_COST);
    try std.testing.expect(x.getz("auth.toke") == null);
    try std.testing.expectError(error.BadKey, open(io, a, path, "other", TEST_COST));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
