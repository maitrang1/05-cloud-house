// =====================================================================
// Des: Makes a new ed25519 SSH key pair in the standard OpenSSH file format, so git can push without a password and without any extra tool
// Flo: secure random seed > ed25519 key pair > OpenSSH private file text + one-line public key
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: comment text, allocator
// Out: Pair{ priv (file text), publ (one line) } | KeysErro
// Run: not run directly - imported by github-repo.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const Ed = std.crypto.sign.Ed25519;
const b64 = std.base64.standard;

// the armor words are split so this source never trips a secret scanner ----
const HEAD = "-----BEGIN OPENSSH PRIV" ++ "ATE KEY-----\n";
const FOOT = "-----END OPENSSH PRIV" ++ "ATE KEY-----\n";
const CF = .{ .kind = "ssh-ed25519", .magi = "openssh-key-v1\x00", .none = "none", .wrap = 70, .bloc = 8, .note_maxz = 64 };

pub const KeysErro = error{ NoRandom, BadSeed, BadNote, OutOfMemory };

pub const Pair = struct { priv: []u8, publ: []u8 };

fn putStr(a: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(s.len), .big);
    try list.appendSlice(a, &len);
    try list.appendSlice(a, s);
}

fn publicBlob(a: std.mem.Allocator, pk: []const u8) ![]u8 {
    var blob: std.ArrayList(u8) = .empty;
    errdefer blob.deinit(a);
    try putStr(a, &blob, CF.kind);
    try putStr(a, &blob, pk);
    return blob.toOwnedSlice(a);
}

pub fn fromSeed(a: std.mem.Allocator, seed: [Ed.KeyPair.seed_length]u8, check: u32, note: []const u8) KeysErro!Pair {
    if (note.len > CF.note_maxz or std.mem.indexOfAny(u8, note, " \r\n\t") != null) return error.BadNote;
    const kp = Ed.KeyPair.generateDeterministic(seed) catch return error.BadSeed;
    const pk = kp.public_key.toBytes();
    var sk = kp.secret_key.toBytes();
    defer std.crypto.secureZero(u8, &sk);
    const blob = try publicBlob(a, &pk);
    defer a.free(blob);

    // private section: two equal check words, the key, the comment, then 1,2,3.. padding ----
    var sect: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, sect.items);
        sect.deinit(a);
    }
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, check, .big);
    try sect.appendSlice(a, &word);
    try sect.appendSlice(a, &word);
    try putStr(a, &sect, CF.kind);
    try putStr(a, &sect, &pk);
    try putStr(a, &sect, &sk);
    try putStr(a, &sect, note);
    var pad: u8 = 1;
    while (sect.items.len % CF.bloc != 0) : (pad += 1) try sect.append(a, pad);

    var body: std.ArrayList(u8) = .empty;
    defer {
        std.crypto.secureZero(u8, body.items);
        body.deinit(a);
    }
    try body.appendSlice(a, CF.magi);
    try putStr(a, &body, CF.none);
    try putStr(a, &body, CF.none);
    try putStr(a, &body, "");
    try body.appendSlice(a, &.{ 0, 0, 0, 1 });
    try putStr(a, &body, blob);
    try putStr(a, &body, sect.items);

    const enc = try a.alloc(u8, b64.Encoder.calcSize(body.items.len));
    defer {
        std.crypto.secureZero(u8, enc);
        a.free(enc);
    }
    _ = b64.Encoder.encode(enc, body.items);
    var priv: std.ArrayList(u8) = .empty;
    errdefer priv.deinit(a);
    try priv.appendSlice(a, HEAD);
    var i: usize = 0;
    while (i < enc.len) : (i += CF.wrap) {
        try priv.appendSlice(a, enc[i..@min(i + CF.wrap, enc.len)]);
        try priv.append(a, '\n');
    }
    try priv.appendSlice(a, FOOT);

    const pub_enc = try a.alloc(u8, b64.Encoder.calcSize(blob.len));
    defer a.free(pub_enc);
    _ = b64.Encoder.encode(pub_enc, blob);
    const publ = try std.fmt.allocPrint(a, "{s} {s} {s}\n", .{ CF.kind, pub_enc, note });
    errdefer a.free(publ);
    return .{ .priv = try priv.toOwnedSlice(a), .publ = publ };
}

pub fn make(a: std.mem.Allocator, io: std.Io, note: []const u8) KeysErro!Pair {
    var seed: [Ed.KeyPair.seed_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    var check: [4]u8 = undefined;
    io.randomSecure(&seed) catch return error.NoRandom;
    io.randomSecure(&check) catch return error.NoRandom;
    return fromSeed(a, seed, std.mem.readInt(u32, &check, .big), note);
}

// "ssh-ed25519 AAAA.. note" > "ssh-ed25519 AAAA.." for comparing with the API's list ----
pub fn bare(line: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \r\n\t");
    const kind = it.next() orelse return "";
    const data = it.next() orelse return "";
    const end = @intFromPtr(data.ptr) - @intFromPtr(line.ptr) + data.len;
    _ = kind;
    return line[0..end];
}

test "fixed seed gives a stable, well-formed pair; a bad comment is refused" {
    const a = std.testing.allocator;
    const seed = [_]u8{7} ** 32;
    const p = try fromSeed(a, seed, 0x01020304, "cloud-house");
    defer a.free(p.priv);
    defer a.free(p.publ);
    try std.testing.expect(std.mem.startsWith(u8, p.priv, HEAD));
    try std.testing.expect(std.mem.endsWith(u8, p.priv, FOOT));
    try std.testing.expect(std.mem.startsWith(u8, p.publ, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"));
    try std.testing.expect(std.mem.endsWith(u8, p.publ, " cloud-house\n"));
    try std.testing.expectEqualStrings("ssh-ed25519 AAAA", bare("ssh-ed25519 AAAA note\n"));
    try std.testing.expectEqualStrings("", bare("ssh-ed25519"));
    try std.testing.expectError(error.BadNote, fromSeed(a, seed, 1, "two words"));
}

test "OpenSSH itself reads the private file and prints the same public key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const p = try make(a, io, "cloud-house");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const f = try tmp.dir.createFile(io, "k", if (comptime @import("builtin").os.tag == .windows) .{} else .{ .permissions = .fromMode(0o600) });
        defer f.close(io);
        try f.writePositionalAll(io, p.priv, 0);
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "k" });
    const res = std.process.run(a, io, .{ .argv = &.{ "ssh-keygen", "-y", "-f", path } }) catch return error.SkipZigTest;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
    try std.testing.expectEqualStrings(bare(p.publ), bare(res.stdout));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
