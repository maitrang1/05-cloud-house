// =====================================================================
// Des: Locks a CI secret with the repo's public key the same way libsodium does, so only GitHub can open it and the value is never readable
// Flo: repo public key (base64) > sealed box (X25519 + XSalsa20-Poly1305) > base64 text for the secrets API
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: base64 public key (32 bytes), secret value
// Out: base64 sealed value (caller's allocator) | SealErro
// Run: not run directly - imported by github-ci.zig and the mock
// Exe: n/a
// =====================================================================
const std = @import("std");
const Box = std.crypto.nacl.SealedBox;
const b64 = std.base64.standard;

pub const SealErro = error{ BadKey, SealFail, OutOfMemory };

pub const KeyPair = Box.KeyPair;

pub fn seal(a: std.mem.Allocator, io: std.Io, keyz_b64: []const u8, plain: []const u8) SealErro![]u8 {
    var pk: [Box.public_length]u8 = undefined;
    const size = b64.Decoder.calcSizeForSlice(keyz_b64) catch return error.BadKey;
    if (size != pk.len) return error.BadKey;
    b64.Decoder.decode(&pk, keyz_b64) catch return error.BadKey;
    const raw = try a.alloc(u8, plain.len + Box.seal_length);
    defer a.free(raw);
    Box.seal(io, raw, plain, pk) catch return error.SealFail;
    const out = try a.alloc(u8, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(out, raw);
    return out;
}

// the receiving side: used by the mock vendor and by tests ----
pub fn open(a: std.mem.Allocator, pair: KeyPair, sealed_b64: []const u8) SealErro![]u8 {
    const size = b64.Decoder.calcSizeForSlice(sealed_b64) catch return error.BadKey;
    if (size < Box.seal_length) return error.BadKey;
    const raw = try a.alloc(u8, size);
    defer a.free(raw);
    b64.Decoder.decode(raw, sealed_b64) catch return error.BadKey;
    const out = try a.alloc(u8, size - Box.seal_length);
    errdefer a.free(out);
    Box.open(out, raw, pair) catch return error.SealFail;
    return out;
}

pub fn publicB64(a: std.mem.Allocator, pair: KeyPair) SealErro![]u8 {
    const out = try a.alloc(u8, b64.Encoder.calcSize(pair.public_key.len));
    _ = b64.Encoder.encode(out, &pair.public_key);
    return out;
}

// vector made with libsodium (PyNaCl 1.5.0): secret key bytes 1..32 ----
const VEC_SK = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
const VEC_PK = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c";
const VEC_CT = "133b4c03dfa021997948549f52693cf3ee953eea06492d833d3ece5b1e2d6e7e43df0f650b1572371c3140fabb671a21d003f963aaa6db99e9dada8cf7ee7de7a34a3e11bef33ce3208c8bc424";
const VEC_MSG = "cloud-house sealed box vector";

fn vecPair() !KeyPair {
    var sk: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sk, VEC_SK);
    return KeyPair.generateDeterministic(sk);
}

test "known answer: the public key and a libsodium ciphertext both match" {
    const a = std.testing.allocator;
    const pair = try vecPair();
    var pk: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&pk, VEC_PK);
    try std.testing.expectEqualSlices(u8, &pk, &pair.public_key);
    var ct: [VEC_CT.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&ct, VEC_CT);
    var ct_b64: [std.base64.standard.Encoder.calcSize(ct.len)]u8 = undefined;
    const got = try open(a, pair, std.base64.standard.Encoder.encode(&ct_b64, &ct));
    defer a.free(got);
    try std.testing.expectEqualStrings(VEC_MSG, got);
}

test "seal then open; two seals differ; a bad key or a flipped byte fails" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const pair = try vecPair();
    const pk = try publicB64(a, pair);
    defer a.free(pk);
    const one = try seal(a, io, pk, "hc-ping.example/uuid");
    defer a.free(one);
    const two = try seal(a, io, pk, "hc-ping.example/uuid");
    defer a.free(two);
    try std.testing.expect(!std.mem.eql(u8, one, two));
    const back = try open(a, pair, one);
    defer a.free(back);
    try std.testing.expectEqualStrings("hc-ping.example/uuid", back);
    try std.testing.expectError(error.BadKey, seal(a, io, "c2hvcnQ=", "x"));
    try std.testing.expectError(error.BadKey, seal(a, io, "not base64 !!", "x"));
    one[one.len - 6] = if (one[one.len - 6] == 'A') 'B' else 'A';
    try std.testing.expectError(error.SealFail, open(a, pair, one));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
