// =====================================================================
// Des: Turns the 2FA setup key from the GitHub page into the 6-digit code an authenticator app would show, so no phone app is needed
// Flo: setup key (base32) > raw key bytes > HMAC-SHA1 over the 30-second counter > pick 4 bytes > 6 digits
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: base32 setup key (spaces, dashes, lower case allowed), unix seconds
// Out: 6 ASCII digits | TotpErro.BadKey
// Run: not run directly - imported by github-account.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const Hmac = std.crypto.auth.hmac.HmacSha1;

const CF = .{ .step_secs = 30, .digi = 6, .keyz_maxz = 128, .keyz_minz = 10 };

pub const TotpErro = error{BadKey};

fn b32Value(c: u8) ?u5 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a'),
        '2'...'7' => @intCast(c - '2' + 26),
        else => null,
    };
}

// RFC 4648 base32; spaces, dashes and padding are skipped ----
pub fn b32Decode(out: []u8, text: []const u8) TotpErro![]u8 {
    var bits: u32 = 0;
    var have: u5 = 0;
    var n: usize = 0;
    for (text) |c| {
        if (c == ' ' or c == '-' or c == '=' or c == '\r' or c == '\n' or c == '\t') continue;
        const v = b32Value(c) orelse return error.BadKey;
        bits = (bits << 5) | v;
        have += 5;
        if (have < 8) continue;
        have -= 8;
        if (n == out.len) return error.BadKey;
        out[n] = @truncate(bits >> have);
        n += 1;
    }
    if (n < CF.keyz_minz) return error.BadKey;
    return out[0..n];
}

pub fn valid(text: []const u8) bool {
    var buf: [CF.keyz_maxz]u8 = undefined;
    _ = b32Decode(&buf, text) catch return false;
    return true;
}

pub fn code(text: []const u8, unix_secs: i64) TotpErro![CF.digi]u8 {
    var buf: [CF.keyz_maxz]u8 = undefined;
    const key = try b32Decode(&buf, text);
    defer std.crypto.secureZero(u8, &buf);
    var msg: [8]u8 = undefined;
    std.mem.writeInt(u64, &msg, @intCast(@divFloor(@max(unix_secs, 0), CF.step_secs)), .big);
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, &msg, key);
    const off: usize = mac[mac.len - 1] & 0x0f;
    const bin = std.mem.readInt(u32, mac[off..][0..4], .big) & 0x7fff_ffff;
    var out: [CF.digi]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>6}", .{bin % 1_000_000}) catch unreachable;
    return out;
}

test "RFC 6238 SHA-1 vectors, last six digits" {
    const key = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
    try std.testing.expectEqualStrings("287082", &try code(key, 59));
    try std.testing.expectEqualStrings("081804", &try code(key, 1111111109));
    try std.testing.expectEqualStrings("050471", &try code(key, 1111111111));
    try std.testing.expectEqualStrings("005924", &try code(key, 1234567890));
    try std.testing.expectEqualStrings("279037", &try code(key, 2000000000));
}

test "spaces, dashes and lower case are accepted; junk and short keys are refused" {
    try std.testing.expectEqualStrings("287082", &try code("gezd gnbv-gy3t qojq gezd gnbv gy3t qojq", 59));
    try std.testing.expectError(error.BadKey, code("GEZD1NBV", 59));
    try std.testing.expectError(error.BadKey, code("GEZDGNBV", 59));
    try std.testing.expect(valid("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"));
    try std.testing.expect(!valid("not a key!"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
