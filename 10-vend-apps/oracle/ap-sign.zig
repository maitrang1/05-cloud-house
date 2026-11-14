// =====================================================================
// Des: Builds the Oracle request signature (Signature version 1, rsa-sha256): the text to sign, the signature, and the Authorization header value. Same recipe the Oracle docs give; GET signs host and date, POST and PUT also sign the body hash, type and length.
// Flo: method + target + host + date (+ body) > signing string > RSA sign > base64 > header value
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Creds (tenancy, user, fingerprint, key), method, target (path?query), host, date, body
// Out: Signed{ auth header value, x-content-sha256 value }
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const rsak = @import("pv-rsak.zig");
const keyz = @import("te-keys.zig");

const Sha = std.crypto.hash.sha2.Sha256;

const CF = .{ .headGet = "(request-target) host date", .headPut = "(request-target) host date x-content-sha256 content-type content-length" };

// who is calling: ocids + fingerprint of the uploaded public key + the private key numbers
pub const Creds = struct { tena: []const u8, user: []const u8, fing: []const u8, key: rsak.Key };

pub const Signed = struct {
    auth: []u8, // Authorization header value
    shaz: []u8, // x-content-sha256 value, empty for bodiless calls
};

// true for methods that carry a body and so need the longer header list
pub fn hasBody(meth: []const u8) bool {
    return std.ascii.eqlIgnoreCase(meth, "post") or std.ascii.eqlIgnoreCase(meth, "put");
}

// sign one request; caller frees both fields (meth in any case)
pub fn sign(gpa: std.mem.Allocator, creds: Creds, meth: []const u8, target: []const u8, host: []const u8, date: []const u8, body: ?[]const u8, ctyp: []const u8) !Signed {
    const lowm = try std.ascii.allocLowerString(gpa, meth);
    defer gpa.free(lowm);
    const bodz = hasBody(meth);
    var shaz: []u8 = try gpa.alloc(u8, 0);
    errdefer gpa.free(shaz);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.print(gpa, "(request-target): {s} {s}\nhost: {s}\ndate: {s}", .{ lowm, target, host, date });
    if (bodz) {
        const raww = body orelse "";
        var dige: [Sha.digest_length]u8 = undefined;
        Sha.hash(raww, &dige, .{});
        gpa.free(shaz);
        const enc = std.base64.standard.Encoder;
        shaz = try gpa.alloc(u8, enc.calcSize(dige.len));
        _ = enc.encode(shaz, &dige);
        try text.print(gpa, "\nx-content-sha256: {s}\ncontent-type: {s}\ncontent-length: {d}", .{ shaz, ctyp, raww.len });
    }
    const sigz = try rsak.sign(gpa, creds.key, text.items);
    defer gpa.free(sigz);
    const enc = std.base64.standard.Encoder;
    const sig64 = try gpa.alloc(u8, enc.calcSize(sigz.len));
    defer gpa.free(sig64);
    _ = enc.encode(sig64, sigz);
    const auth = try std.fmt.allocPrint(gpa, "Signature version=\"1\",keyId=\"{s}/{s}/{s}\",algorithm=\"rsa-sha256\",headers=\"{s}\",signature=\"{s}\"", .{ creds.tena, creds.user, creds.fing, if (bodz) CF.headPut else CF.headGet, sig64 });
    return .{ .auth = auth, .shaz = shaz };
}

test "a GET signature has the Oracle shape and verifies" {
    const gpa = std.testing.allocator;
    const held = try rsak.pemPars(gpa, keyz.pem1);
    defer held.deinit(gpa);
    const creds = Creds{ .tena = "ocid1.tenancy.oc1..t", .user = "ocid1.user.oc1..u", .fing = keyz.fing, .key = held.key };
    const sg = try sign(gpa, creds, "GET", "/20160918/users/u?x=1", "iaas.eu-frankfurt-1.oraclecloud.com", "Sun, 05 Jan 2014 21:31:40 GMT", null, "application/json");
    defer gpa.free(sg.auth);
    defer gpa.free(sg.shaz);
    try std.testing.expectEqual(@as(usize, 0), sg.shaz.len);
    try std.testing.expect(std.mem.startsWith(u8, sg.auth, "Signature version=\"1\",keyId=\"ocid1.tenancy.oc1..t/ocid1.user.oc1..u/4a:04:"));
    try std.testing.expect(std.mem.indexOf(u8, sg.auth, "algorithm=\"rsa-sha256\",headers=\"(request-target) host date\",signature=\"") != null);
}

test "a POST signature adds the body hash and length" {
    const gpa = std.testing.allocator;
    const held = try rsak.pemPars(gpa, keyz.pem1);
    defer held.deinit(gpa);
    const creds = Creds{ .tena = "t", .user = "u", .fing = "f", .key = held.key };
    const sg = try sign(gpa, creds, "POST", "/20160918/vcns", "h", "d", "{}", "application/json");
    defer gpa.free(sg.auth);
    defer gpa.free(sg.shaz);
    // sha256("{}") in base64
    try std.testing.expectEqualStrings("RBNvo1WzZ4oRRq0W9+hknpT7T8If536DEMBg9hyq/4o=", sg.shaz);
    try std.testing.expect(std.mem.indexOf(u8, sg.auth, "headers=\"(request-target) host date x-content-sha256 content-type content-length\"") != null);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
