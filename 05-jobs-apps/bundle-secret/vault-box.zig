// =====================================================================
// Des: Locks a block of bytes with a passphrase so the bundle can sit in git as unreadable ciphertext
// Flo: passphrase > Argon2id key > AES-256-GCM seal (fresh salt + nonce, cost signed in the header) > unseal checks tag
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: passphrase, bytes, Argon2 cost (time, memory KiB, lanes)
// Out: sealed bytes | plain bytes | BoxErro (BadKey = wrong passphrase or damaged file)
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const argon2 = std.crypto.pwhash.argon2;

pub const MAGIC = "CHSB1";
const SALT = 16;
const NONCE = Aes.nonce_length;
const TAG = Aes.tag_length;
const COST = 12;
pub const HEAD = MAGIC.len + COST + SALT + NONCE;
const CF = .{ .memo_minz = 8, .memo_maxz = 1048576, .time_maxz = 16, .para_maxz = 8 };

pub const BoxErro = error{ NotSealed, BadKey, NoRandom, OutOfMemory };

pub const Cost = struct { time: u32, memo: u32, para: u32 };

fn derive(a: std.mem.Allocator, io: std.Io, pass: []const u8, salt: []const u8, cost: Cost) BoxErro![32]u8 {
    var k: [32]u8 = undefined;
    argon2.kdf(a, &k, pass, salt, .{ .t = cost.time, .m = cost.memo, .p = @intCast(cost.para) }, .argon2id, io) catch return error.OutOfMemory;
    return k;
}

pub fn costOkay(c: Cost) bool {
    return c.time >= 1 and c.time <= CF.time_maxz and c.memo >= CF.memo_minz and c.memo <= CF.memo_maxz and c.para >= 1 and c.para <= CF.para_maxz;
}

// the cost travels in the file head and is signed with the text, so it cannot be lowered unseen ----
pub fn seal(a: std.mem.Allocator, io: std.Io, pass: []const u8, plain: []const u8, cost: Cost) BoxErro![]u8 {
    if (!costOkay(cost)) return error.NotSealed;
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

// the cost stored in a sealed file, or null when it is not one (for `status`, no passphrase needed) ----
pub fn costOf(blob: []const u8) ?Cost {
    if (blob.len < HEAD + TAG or !std.mem.startsWith(u8, blob, MAGIC)) return null;
    const c: Cost = .{ .time = std.mem.readInt(u32, blob[MAGIC.len..][0..4], .little), .memo = std.mem.readInt(u32, blob[MAGIC.len + 4 ..][0..4], .little), .para = std.mem.readInt(u32, blob[MAGIC.len + 8 ..][0..4], .little) };
    return if (costOkay(c)) c else null;
}

pub fn unseal(a: std.mem.Allocator, io: std.Io, pass: []const u8, blob: []const u8) BoxErro![]u8 {
    const cost = costOf(blob) orelse return error.NotSealed;
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
    try std.testing.expectError(error.NotSealed, unseal(a, io, "pass one", "CHSB1short"));
    try std.testing.expectError(error.NotSealed, seal(a, io, "p", "x", .{ .time = 0, .memo = 8, .para = 1 }));
    const twin = try seal(a, io, "pass one", "SECRET-123", TEST_COST);
    defer a.free(twin);
    try std.testing.expect(!std.mem.eql(u8, blob[MAGIC.len + COST ..], twin[MAGIC.len + COST ..]));
}

test "an empty message seals and opens; the cost is readable without a passphrase" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const blob = try seal(a, io, "pw", "", TEST_COST);
    defer a.free(blob);
    const back = try unseal(a, io, "pw", blob);
    defer a.free(back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
    const c = costOf(blob).?;
    try std.testing.expectEqual(TEST_COST, c);
    try std.testing.expect(costOf("nope") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
