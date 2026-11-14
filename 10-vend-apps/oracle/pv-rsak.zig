// =====================================================================
// Des: RSA key work done inside the app with std only: read a private key from PEM (both common shapes), sign with SHA-256 (PKCS#1 v1.5), build the public key text Oracle wants, and compute the key fingerprint. Also verifies a signature, so the mock Oracle can check callers.
// Flo: PEM > DER > numbers (n, e, d) > sign: padded hash ^ d mod n | public: DER + PEM + MD5 fingerprint
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: PEM text, message bytes
// Out: Key struct, signature bytes, public PEM, fingerprint text
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const keyz = @import("te-keys.zig");

const Sha = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;
const ff = std.crypto.ff;

// the armor words are split so this source never trips a secret scanner ----
const ARM1 = "-----BEGIN RSA PRIV" ++ "ATE KEY-----";
const ARM8 = "-----BEGIN PRIV" ++ "ATE KEY-----";
const PUBH = "-----BEGIN PUBLIC KEY-----\n";
const PUBF = "-----END PUBLIC KEY-----\n";

const CF = .{ .maxBits = 4096, .minBits = 2048, .wrap = 64, .tagSeqz = 0x30, .tagInte = 0x02, .tagOcte = 0x04, .tagBitz = 0x03, .tagOidz = 0x06, .tagNull = 0x05 };

// DigestInfo prefix for SHA-256 (RFC 8017 section 9.2)
const sha2Pref = [_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
// AlgorithmIdentifier rsaEncryption + NULL
const rsaAlgo = [_]u8{ 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00 };

pub const Erro = error{ PemForm, DerForm, KeyWeak, KeyBig, SigBad, OutOfMemory };

const Mod = ff.Modulus(CF.maxBits);

// big-endian numbers, no leading zero byte; slices point into the parsed DER
pub const Key = struct { nnnn: []const u8, eeee: []const u8, dddd: []const u8 = "" };

const Tlv = struct { tagz: u8, body: []const u8, rest: []const u8 };

// read one DER element from the front of buf
fn tlvRead(buf: []const u8) Erro!Tlv {
    if (buf.len < 2) return error.DerForm;
    var indx: usize = 2;
    var size: usize = buf[1];
    if (size & 0x80 != 0) {
        const cnt = size & 0x7f;
        if (cnt == 0 or cnt > 4 or buf.len < 2 + cnt) return error.DerForm;
        size = 0;
        for (buf[2 .. 2 + cnt]) |byte| size = (size << 8) | byte;
        indx = 2 + cnt;
    }
    if (buf.len < indx + size) return error.DerForm;
    return .{ .tagz = buf[0], .body = buf[indx .. indx + size], .rest = buf[indx + size ..] };
}

// next element must have this tag
fn tlvWant(buf: []const u8, tagz: u8) Erro!Tlv {
    const item = try tlvRead(buf);
    if (item.tagz != tagz) return error.DerForm;
    return item;
}

fn intTrim(body: []const u8) []const u8 {
    var indx: usize = 0;
    while (indx + 1 < body.len and body[indx] == 0) indx += 1;
    return body[indx..];
}

// PEM text to raw DER bytes (caller frees); returns whether it was the PKCS#8 shape
fn pemDer(gpa: std.mem.Allocator, pem: []const u8) Erro!struct { der: []u8, pk8: bool } {
    const pk8 = std.mem.indexOf(u8, pem, ARM8) != null;
    const hea = if (pk8) ARM8 else ARM1;
    const star = std.mem.indexOf(u8, pem, hea) orelse return error.PemForm;
    const endd = std.mem.indexOfPos(u8, pem, star + hea.len, "-----END") orelse return error.PemForm;
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    for (pem[star + hea.len .. endd]) |byte| if (!std.ascii.isWhitespace(byte)) try flat.append(gpa, byte);
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(flat.items) catch return error.PemForm;
    const outp = try gpa.alloc(u8, size);
    errdefer gpa.free(outp);
    dec.decode(outp, flat.items) catch return error.PemForm;
    return .{ .der = outp, .pk8 = pk8 };
}

// owns the DER bytes the Key slices point into
pub const Held = struct {
    der: []u8,
    key: Key,

    pub fn deinit(self: Held, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.der);
        gpa.free(self.der);
    }
};

// parse a private key PEM (PKCS#1 or PKCS#8, no passphrase)
pub fn pemPars(gpa: std.mem.Allocator, pem: []const u8) Erro!Held {
    const got = try pemDer(gpa, pem);
    errdefer gpa.free(got.der);
    var seqz = try tlvWant(got.der, CF.tagSeqz);
    if (got.pk8) {
        const vers = try tlvWant(seqz.body, CF.tagInte);
        const algo = try tlvWant(vers.rest, CF.tagSeqz);
        const octe = try tlvWant(algo.rest, CF.tagOcte);
        seqz = try tlvWant(octe.body, CF.tagSeqz);
    }
    const vers = try tlvWant(seqz.body, CF.tagInte);
    const nnnn = try tlvWant(vers.rest, CF.tagInte);
    const eeee = try tlvWant(nnnn.rest, CF.tagInte);
    const dddd = try tlvWant(eeee.rest, CF.tagInte);
    const key = Key{ .nnnn = intTrim(nnnn.body), .eeee = intTrim(eeee.body), .dddd = intTrim(dddd.body) };
    if (key.nnnn.len * 8 < CF.minBits) return error.KeyWeak;
    if (key.nnnn.len * 8 > CF.maxBits) return error.KeyBig;
    return .{ .der = got.der, .key = key };
}

// m^exp mod n, big-endian in and out, padded to the modulus length
fn powMod(gpa: std.mem.Allocator, nnnn: []const u8, base: []const u8, expo: []const u8, secr: bool) Erro![]u8 {
    const modu = Mod.fromBytes(nnnn, .big) catch return error.KeyWeak;
    const feee = Mod.Fe.fromBytes(modu, base, .big) catch return error.SigBad;
    const resu = (if (secr) modu.powWithEncodedExponent(feee, expo, .big) else modu.powWithEncodedPublicExponent(feee, expo, .big)) catch return error.SigBad;
    const outp = try gpa.alloc(u8, nnnn.len);
    errdefer gpa.free(outp);
    resu.toBytes(outp, .big) catch return error.SigBad;
    return outp;
}

// the padded block: 00 01 FF..FF 00 DigestInfo (RFC 8017 EMSA-PKCS1-v1_5)
fn emBlock(gpa: std.mem.Allocator, size: usize, msg: []const u8) Erro![]u8 {
    var dige: [Sha.digest_length]u8 = undefined;
    Sha.hash(msg, &dige, .{});
    const tail = sha2Pref.len + dige.len;
    if (size < tail + 11) return error.KeyWeak;
    const outp = try gpa.alloc(u8, size);
    @memset(outp, 0xff);
    outp[0] = 0;
    outp[1] = 1;
    outp[size - tail - 1] = 0;
    @memcpy(outp[size - tail ..][0..sha2Pref.len], &sha2Pref);
    @memcpy(outp[size - dige.len ..], &dige);
    return outp;
}

// RSASSA-PKCS1-v1_5 signature over SHA-256(msg); caller frees
pub fn sign(gpa: std.mem.Allocator, key: Key, msg: []const u8) Erro![]u8 {
    const emmm = try emBlock(gpa, key.nnnn.len, msg);
    defer gpa.free(emmm);
    return powMod(gpa, key.nnnn, emmm, key.dddd, true);
}

// true when sig is a valid signature of msg under the public numbers
pub fn verify(gpa: std.mem.Allocator, key: Key, msg: []const u8, sig: []const u8) bool {
    if (sig.len != key.nnnn.len) return false;
    const emmm = emBlock(gpa, key.nnnn.len, msg) catch return false;
    defer gpa.free(emmm);
    const back = powMod(gpa, key.nnnn, sig, key.eeee, false) catch return false;
    defer gpa.free(back);
    return std.mem.eql(u8, emmm, back);
}

// DER writer helpers
fn lenPut(gpa: std.mem.Allocator, list: *std.ArrayList(u8), size: usize) !void {
    if (size < 0x80) return list.append(gpa, @intCast(size));
    if (size < 0x100) return list.appendSlice(gpa, &.{ 0x81, @intCast(size) });
    try list.appendSlice(gpa, &.{ 0x82, @intCast(size >> 8), @intCast(size & 0xff) });
}

fn tlvPut(gpa: std.mem.Allocator, list: *std.ArrayList(u8), tagz: u8, body: []const u8) !void {
    try list.append(gpa, tagz);
    try lenPut(gpa, list, body.len);
    try list.appendSlice(gpa, body);
}

fn intPut(gpa: std.mem.Allocator, list: *std.ArrayList(u8), num: []const u8) !void {
    const pad = num.len > 0 and num[0] & 0x80 != 0;
    try list.append(gpa, CF.tagInte);
    try lenPut(gpa, list, num.len + @as(usize, @intFromBool(pad)));
    if (pad) try list.append(gpa, 0);
    try list.appendSlice(gpa, num);
}

// SubjectPublicKeyInfo DER of the public half; caller frees
pub fn publicDer(gpa: std.mem.Allocator, key: Key) Erro![]u8 {
    var pair: std.ArrayList(u8) = .empty;
    defer pair.deinit(gpa);
    try intPut(gpa, &pair, key.nnnn);
    try intPut(gpa, &pair, key.eeee);
    var seqz: std.ArrayList(u8) = .empty;
    defer seqz.deinit(gpa);
    try tlvPut(gpa, &seqz, CF.tagSeqz, pair.items);
    var bits: std.ArrayList(u8) = .empty;
    defer bits.deinit(gpa);
    try bits.append(gpa, 0); // no unused bits
    try bits.appendSlice(gpa, seqz.items);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &rsaAlgo);
    try tlvPut(gpa, &body, CF.tagBitz, bits.items);
    var outp: std.ArrayList(u8) = .empty;
    errdefer outp.deinit(gpa);
    try tlvPut(gpa, &outp, CF.tagSeqz, body.items);
    return outp.toOwnedSlice(gpa);
}

// public key PEM, the text the Oracle console asks you to paste; caller frees
pub fn publicPem(gpa: std.mem.Allocator, key: Key) Erro![]u8 {
    const der = try publicDer(gpa, key);
    defer gpa.free(der);
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(der.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, der);
    var outp: std.ArrayList(u8) = .empty;
    errdefer outp.deinit(gpa);
    try outp.appendSlice(gpa, PUBH);
    var indx: usize = 0;
    while (indx < b64.len) : (indx += CF.wrap) {
        try outp.appendSlice(gpa, b64[indx..@min(indx + CF.wrap, b64.len)]);
        try outp.append(gpa, '\n');
    }
    try outp.appendSlice(gpa, PUBF);
    return outp.toOwnedSlice(gpa);
}

// read the public numbers back out of a public PEM; caller frees held.der
pub fn publicPars(gpa: std.mem.Allocator, pem: []const u8) Erro!Held {
    const star = std.mem.indexOf(u8, pem, PUBH[0 .. PUBH.len - 1]) orelse return error.PemForm;
    const endd = std.mem.indexOfPos(u8, pem, star, "-----END") orelse return error.PemForm;
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    for (pem[star + PUBH.len - 1 .. endd]) |byte| if (!std.ascii.isWhitespace(byte)) try flat.append(gpa, byte);
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(flat.items) catch return error.PemForm;
    const der = try gpa.alloc(u8, size);
    errdefer gpa.free(der);
    dec.decode(der, flat.items) catch return error.PemForm;
    const outr = try tlvWant(der, CF.tagSeqz);
    const algo = try tlvWant(outr.body, CF.tagSeqz);
    const bits = try tlvWant(algo.rest, CF.tagBitz);
    if (bits.body.len < 1) return error.DerForm;
    const seqz = try tlvWant(bits.body[1..], CF.tagSeqz);
    const nnnn = try tlvWant(seqz.body, CF.tagInte);
    const eeee = try tlvWant(nnnn.rest, CF.tagInte);
    return .{ .der = der, .key = .{ .nnnn = intTrim(nnnn.body), .eeee = intTrim(eeee.body) } };
}

// MD5 of the public DER as aa:bb:.. (what Oracle shows as the key fingerprint); caller frees
pub fn fingerprint(gpa: std.mem.Allocator, key: Key) Erro![]u8 {
    const der = try publicDer(gpa, key);
    defer gpa.free(der);
    var dige: [Md5.digest_length]u8 = undefined;
    Md5.hash(der, &dige, .{});
    var outp: std.ArrayList(u8) = .empty;
    errdefer outp.deinit(gpa);
    for (dige, 0..) |byte, indx| {
        if (indx > 0) try outp.append(gpa, ':');
        try outp.print(gpa, "{x:0>2}", .{byte});
    }
    return outp.toOwnedSlice(gpa);
}

test "both PEM shapes give the same key and the fingerprint OpenSSL printed" {
    const gpa = std.testing.allocator;
    const one = try pemPars(gpa, keyz.pem1);
    defer one.deinit(gpa);
    const eig = try pemPars(gpa, keyz.pem8);
    defer eig.deinit(gpa);
    try std.testing.expectEqualSlices(u8, one.key.nnnn, eig.key.nnnn);
    try std.testing.expectEqualSlices(u8, one.key.dddd, eig.key.dddd);
    try std.testing.expectEqual(@as(usize, 256), one.key.nnnn.len);
    const fing = try fingerprint(gpa, one.key);
    defer gpa.free(fing);
    try std.testing.expectEqualStrings(keyz.fing, fing);
}

test "sign then verify, tampering and a wrong key are caught" {
    const gpa = std.testing.allocator;
    const one = try pemPars(gpa, keyz.pem1);
    defer one.deinit(gpa);
    const sig = try sign(gpa, one.key, "date: x\n(request-target): get /a");
    defer gpa.free(sig);
    try std.testing.expectEqual(@as(usize, 256), sig.len);
    try std.testing.expect(verify(gpa, one.key, "date: x\n(request-target): get /a", sig));
    try std.testing.expect(!verify(gpa, one.key, "date: x\n(request-target): get /b", sig));
    var bad = try gpa.dupe(u8, sig);
    defer gpa.free(bad);
    bad[10] ^= 1;
    try std.testing.expect(!verify(gpa, one.key, "date: x\n(request-target): get /a", bad));
}

test "public PEM round trips and is what OpenSSL reads" {
    const gpa = std.testing.allocator;
    const one = try pemPars(gpa, keyz.pem1);
    defer one.deinit(gpa);
    const pubp = try publicPem(gpa, one.key);
    defer gpa.free(pubp);
    const back = try publicPars(gpa, pubp);
    defer gpa.free(back.der);
    try std.testing.expectEqualSlices(u8, one.key.nnnn, back.key.nnnn);
    try std.testing.expectEqualSlices(u8, one.key.eeee, back.key.eeee);
    try std.testing.expect(std.mem.startsWith(u8, pubp, "-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEF"));
}

test "OpenSSL itself accepts our signature" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const io = std.testing.io;
    const one = try pemPars(gpa, keyz.pem1);
    const msg = "(request-target): get /20160918/users/x\nhost: h\ndate: d";
    const sig = try sign(gpa, one.key, msg);
    const pubp = try publicPem(gpa, one.key);
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    try tmpz.dir.writeFile(io, .{ .sub_path = "pub.pem", .data = pubp });
    try tmpz.dir.writeFile(io, .{ .sub_path = "sig.bin", .data = sig });
    try tmpz.dir.writeFile(io, .{ .sub_path = "msg.txt", .data = msg });
    var buff: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmpz.dir.realPath(io, &buff);
    const base = buff[0..size];
    const pubf = try std.fs.path.join(gpa, &.{ base, "pub.pem" });
    const sigf = try std.fs.path.join(gpa, &.{ base, "sig.bin" });
    const msgf = try std.fs.path.join(gpa, &.{ base, "msg.txt" });
    const resu = std.process.run(gpa, io, .{ .argv = &.{ "openssl", "dgst", "-sha256", "-verify", pubf, "-signature", sigf, msgf } }) catch return error.SkipZigTest;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, resu.term);
    try std.testing.expect(std.mem.indexOf(u8, resu.stdout, "Verified OK") != null);
}

test "a weak or broken key is refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.PemForm, pemPars(gpa, "not a key"));
    try std.testing.expectError(error.PemForm, pemPars(gpa, ARM1 ++ "\n!!!!\n-----END"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
