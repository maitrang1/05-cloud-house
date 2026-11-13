// =====================================================================
// Des: Builds the AWS request signature (Signature Version 4, HMAC-SHA256): the canonical request, the string to sign, the derived key and the Authorization header value. Same recipe the AWS docs give.
// Flo: canonical request > hash > string to sign > derive key (date, region, service) > hmac > header value
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Creds (key id, secret), Params (method, host, path, query, headers, body, region, service, amz date)
// Out: Signed{ Authorization header value, hex sha256 of the body }
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const Sha = std.crypto.hash.sha2.Sha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

const CF = .{ .algo = "AWS4-HMAC-SHA256", .scop = "aws4_request", .pref = "AWS4", .datSize = 8 };

// who is calling
pub const Creds = struct { akid: []const u8, secr: []const u8 };

// what is being signed; path and query must already be canonical (encoded, query sorted)
pub const Params = struct {
    meth: []const u8,
    host: []const u8,
    path: []const u8,
    query: []const u8 = "",
    ctyp: []const u8 = "", // content-type, empty for bodiless calls
    amzt: []const u8 = "", // x-amz-target, empty when unused
    body: []const u8 = "",
    regi: []const u8,
    serv: []const u8,
    amzd: []const u8, // 20150830T123600Z
};

pub const Signed = struct {
    auth: []u8, // Authorization header value
    hash: [Sha.digest_length * 2]u8, // lowercase hex sha256 of the body
};

// lowercase hex of a hash
fn hexz(dige: []const u8, outp: []u8) void {
    const digs = "0123456789abcdef";
    for (dige, 0..) |byte, indx| {
        outp[indx * 2] = digs[byte >> 4];
        outp[indx * 2 + 1] = digs[byte & 0xf];
    }
}

// HMAC-SHA256
fn hmac(key: []const u8, text: []const u8) [Hmac.mac_length]u8 {
    var outp: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&outp, text, key);
    return outp;
}

// the derived signing key for a date, region and service
pub fn keyDerive(gpa: std.mem.Allocator, secr: []const u8, date: []const u8, regi: []const u8, serv: []const u8) ![Hmac.mac_length]u8 {
    const seed = try std.mem.concat(gpa, u8, &.{ CF.pref, secr });
    defer gpa.free(seed);
    const kdat = hmac(seed, date);
    const kreg = hmac(&kdat, regi);
    const kser = hmac(&kreg, serv);
    return hmac(&kser, CF.scop);
}

// sign one request; the caller frees .auth
pub fn sign(gpa: std.mem.Allocator, creds: Creds, par: Params) !Signed {
    var bdig: [Sha.digest_length]u8 = undefined;
    Sha.hash(par.body, &bdig, .{});
    var bhex: [Sha.digest_length * 2]u8 = undefined;
    hexz(&bdig, &bhex);

    // headers in name order: content-type, host, x-amz-date, x-amz-target
    var cano: std.ArrayList(u8) = .empty;
    defer cano.deinit(gpa);
    var shed: std.ArrayList(u8) = .empty;
    defer shed.deinit(gpa);
    if (par.ctyp.len > 0) {
        try cano.print(gpa, "content-type:{s}\n", .{par.ctyp});
        try shed.appendSlice(gpa, "content-type;");
    }
    try cano.print(gpa, "host:{s}\nx-amz-date:{s}\n", .{ par.host, par.amzd });
    try shed.appendSlice(gpa, "host;x-amz-date");
    if (par.amzt.len > 0) {
        try cano.print(gpa, "x-amz-target:{s}\n", .{par.amzt});
        try shed.appendSlice(gpa, ";x-amz-target");
    }
    const requ = try std.fmt.allocPrint(gpa, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ par.meth, par.path, par.query, cano.items, shed.items, bhex });
    defer gpa.free(requ);
    var rdig: [Sha.digest_length]u8 = undefined;
    Sha.hash(requ, &rdig, .{});
    var rhex: [Sha.digest_length * 2]u8 = undefined;
    hexz(&rdig, &rhex);

    const date = par.amzd[0..CF.datSize];
    const scop = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}", .{ date, par.regi, par.serv, CF.scop });
    defer gpa.free(scop);
    const tosg = try std.fmt.allocPrint(gpa, "{s}\n{s}\n{s}\n{s}", .{ CF.algo, par.amzd, scop, rhex });
    defer gpa.free(tosg);
    const keyz = try keyDerive(gpa, creds.secr, date, par.regi, par.serv);
    const sdig = hmac(&keyz, tosg);
    var shex: [Hmac.mac_length * 2]u8 = undefined;
    hexz(&sdig, &shex);
    const auth = try std.fmt.allocPrint(gpa, "{s} Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{ CF.algo, creds.akid, scop, shed.items, shex });
    return .{ .auth = auth, .hash = bhex };
}

test "signing key matches the AWS docs derivation example" {
    const gpa = std.testing.allocator;
    const keyz = try keyDerive(gpa, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam");
    var hex: [Hmac.mac_length * 2]u8 = undefined;
    hexz(&keyz, &hex);
    try std.testing.expectEqualStrings("c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9", &hex);
}

test "get-vanilla matches the AWS signature test suite" {
    const gpa = std.testing.allocator;
    const sg = try sign(gpa, .{ .akid = "AKIDEXAMPLE", .secr = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" }, .{ .meth = "GET", .host = "example.amazonaws.com", .path = "/", .regi = "us-east-1", .serv = "service", .amzd = "20150830T123600Z" });
    defer gpa.free(sg.auth);
    try std.testing.expectEqualStrings("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", sg.auth);
}

test "a body and a target join the signed headers" {
    const gpa = std.testing.allocator;
    const sg = try sign(gpa, .{ .akid = "A", .secr = "s" }, .{ .meth = "POST", .host = "h", .path = "/", .ctyp = "application/x-amz-json-1.1", .amzt = "AWSEvents.PutRule", .body = "{}", .regi = "r", .serv = "events", .amzd = "20260101T000000Z" });
    defer gpa.free(sg.auth);
    try std.testing.expect(std.mem.indexOf(u8, sg.auth, "SignedHeaders=content-type;host;x-amz-date;x-amz-target,") != null);
    try std.testing.expectEqualStrings("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", &sg.hash); // sha256("{}")
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
