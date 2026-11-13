// URL guard: https:443 only, allowlist, no IP literals/userinfo, resolved IP must be public and is PINNED (connect to it, never re-resolve).
// Redaction helpers keep keys/tokens out of logs.
const std = @import("std");
const Io = std.Io;

pub const GuardErr = error{ TooLong, BadChars, Scheme, Userinfo, Port, IpLiteral, BadHost, NotAllowed, PrivateIp, DnsFail, OutOfMemory };

pub const Target = struct { host: []const u8, port: u16, tls: bool, path: []const u8, loopback: bool = false };

pub const Opts = struct {
    allow_hosts: []const []const u8,
    mock: bool = false, // build option: loopback http allowed
    any_host: bool = false, // cust webhook urls: skip the allowlist, keep every other check
};

fn isLoopbackName(h: []const u8) bool {
    return std.mem.eql(u8, h, "127.0.0.1") or std.mem.eql(u8, h, "localhost");
}

fn labelsOk(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    var it = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (l.len == 0 or l.len > 63) return false;
        if (l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return n >= 2;
}

// 1.2.3.4, 0x7f.1, 2130706433, 017700000001: last label numeric or 0x-ish = an IP in disguise
fn looksNumeric(host: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, host, '.');
    const last = if (dot) |d| host[d + 1 ..] else host;
    if (last.len == 0) return false;
    if (std.mem.startsWith(u8, last, "0x") or std.mem.startsWith(u8, last, "0X")) return true;
    for (last) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn allowed(host: []const u8, list: []const []const u8) bool {
    for (list) |a| {
        if (std.mem.startsWith(u8, a, "*.")) {
            const suf = a[1..];
            if (host.len > suf.len and std.ascii.eqlIgnoreCase(host[host.len - suf.len ..], suf)) return true;
        } else if (std.ascii.eqlIgnoreCase(host, a)) return true;
    }
    return false;
}

// Parse + validate. Host is lowercased into `arena`. No network.
pub fn parseUrl(arena: std.mem.Allocator, url: []const u8, o: Opts) GuardErr!Target {
    if (url.len > 2048) return GuardErr.TooLong;
    for (url) |c| if (c < 0x21 or c > 0x7e or c == '\\') return GuardErr.BadChars;
    var rest: []const u8 = undefined;
    var tls = true;
    if (std.ascii.startsWithIgnoreCase(url, "https://")) {
        rest = url[8..];
    } else if (o.mock and std.ascii.startsWithIgnoreCase(url, "http://")) {
        rest = url[7..];
        tls = false;
    } else return GuardErr.Scheme;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const auth = rest[0..end];
    var tail = rest[end..];
    if (std.mem.indexOfScalar(u8, auth, '@') != null) return GuardErr.Userinfo;
    if (std.mem.indexOfScalar(u8, auth, '[') != null) return GuardErr.IpLiteral;
    var host = auth;
    var port: u16 = 443;
    var has_port = false;
    if (std.mem.lastIndexOfScalar(u8, auth, ':')) |c| {
        host = auth[0..c];
        port = std.fmt.parseInt(u16, auth[c + 1 ..], 10) catch return GuardErr.Port;
        has_port = true;
    }
    const lower = try arena.dupe(u8, host);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
    const loop = o.mock and isLoopbackName(lower);
    if (loop) {
        if (!tls and port == 0) return GuardErr.Port;
    } else {
        if (looksNumeric(lower)) return GuardErr.IpLiteral;
        if (has_port and port != 443) return GuardErr.Port;
        if (!tls) return GuardErr.Scheme;
        if (!labelsOk(lower)) return GuardErr.BadHost;
        if (!o.any_host and !allowed(lower, o.allow_hosts)) return GuardErr.NotAllowed;
    }
    if (std.mem.indexOfScalar(u8, tail, '#')) |h| tail = tail[0..h];
    if (tail.len == 0 or tail[0] == '?') {
        tail = try std.fmt.allocPrint(arena, "/{s}", .{tail});
    }
    if (std.ascii.indexOfIgnoreCase(tail, "%00") != null) return GuardErr.BadChars;
    return .{ .host = lower, .port = port, .tls = tls, .path = try arena.dupe(u8, tail), .loopback = loop };
}

pub fn ip4Public(b: [4]u8) bool {
    const a = b[0];
    const c = b[1];
    if (a == 0 or a == 10 or a == 127) return false;
    if (a == 100 and c >= 64 and c <= 127) return false;
    if (a == 169 and c == 254) return false;
    if (a == 172 and c >= 16 and c <= 31) return false;
    if (a == 192 and c == 0 and b[2] == 0) return false;
    if (a == 192 and c == 0 and b[2] == 2) return false;
    if (a == 192 and c == 88 and b[2] == 99) return false;
    if (a == 192 and c == 168) return false;
    if (a == 198 and (c == 18 or c == 19)) return false;
    if (a == 198 and c == 51 and b[2] == 100) return false;
    if (a == 203 and c == 0 and b[2] == 113) return false;
    if (a >= 224) return false;
    return true;
}

pub fn ip6Public(b: [16]u8) bool {
    var zero = true;
    for (b[0..15]) |x| {
        if (x != 0) zero = false;
    }
    if (zero and (b[15] == 0 or b[15] == 1)) return false; // :: and ::1
    if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7
    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return false; // fe80::/10
    if (b[0] == 0xff) return false; // multicast
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return false; // doc
    if (b[0] == 0x20 and b[1] == 0x02) return false; // 6to4
    if (b[0] == 0x01 and b[1] == 0 and b[2] == 0 and b[3] == 0 and b[4] == 0 and b[5] == 0 and b[6] == 0 and b[7] == 0) return false; // discard
    var mapped = true;
    for (b[0..10]) |x| {
        if (x != 0) mapped = false;
    }
    if (mapped and b[10] == 0xff and b[11] == 0xff) return ip4Public(.{ b[12], b[13], b[14], b[15] });
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b) return false; // NAT64
    return true;
}

pub fn ipPublic(a: Io.net.IpAddress) bool {
    return switch (a) {
        .ip4 => |x| ip4Public(x.bytes),
        .ip6 => |x| ip6Public(x.bytes),
    };
}

pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, io: Io, host: []const u8, port: u16, out: []Io.net.IpAddress) anyerror!usize = realResolve,
};

fn realResolve(_: ?*anyopaque, io: Io, host: []const u8, port: u16, out: []Io.net.IpAddress) anyerror!usize {
    const hn = try Io.net.HostName.init(host);
    var buf: [32]Io.net.HostName.LookupResult = undefined;
    var q: Io.Queue(Io.net.HostName.LookupResult) = .init(&buf);
    try hn.lookup(io, &q, .{ .port = port });
    var n: usize = 0;
    while (q.getOne(io)) |r| {
        switch (r) {
            .address => |a| if (n < out.len) {
                out[n] = a;
                n += 1;
            },
            .canonical_name => {},
        }
    } else |_| {}
    return n;
}

// Resolve and require EVERY answer to be public (a mixed answer = rebinding trick). Returns the first as the pin.
pub fn pin(io: Io, rs: Resolver, t: Target) GuardErr!Io.net.IpAddress {
    if (t.loopback) return Io.net.IpAddress.parse("127.0.0.1", t.port) catch GuardErr.DnsFail;
    var out: [16]Io.net.IpAddress = undefined;
    const n = rs.func(rs.ctx, io, t.host, t.port, &out) catch return GuardErr.DnsFail;
    if (n == 0) return GuardErr.DnsFail;
    for (out[0..n]) |a| if (!ipPublic(a)) return GuardErr.PrivateIp;
    return out[0];
}

// ---- redaction: logs never carry query strings or secrets ----
pub fn redactUrl(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var s = url;
    var scheme: []const u8 = "";
    if (std.mem.indexOf(u8, s, "://")) |i| {
        const after = s[i + 3 ..];
        if (std.mem.indexOfScalar(u8, after, '@')) |at| {
            const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
            if (at < slash) {
                scheme = s[0 .. i + 3];
                s = after[at + 1 ..];
            }
        }
    }
    if (std.mem.indexOfScalar(u8, s, '?')) |q| return std.fmt.allocPrint(alloc, "{s}{s}?...", .{ scheme, s[0..q] });
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ scheme, s });
}

const secret_keys = [_][]const u8{ "api_key=", "apikey=", "token=", "key=", "access_token=", "secret=", "authorization: bearer ", "x-api-key: " };

// Replace the value after a secret-ish key with ***. Case-insensitive; value ends at & space quote newline.
pub fn redactText(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    outer: while (i < text.len) {
        for (secret_keys) |k| {
            if (i + k.len <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + k.len], k)) {
                try out.appendSlice(alloc, text[i .. i + k.len]);
                i += k.len;
                try out.appendSlice(alloc, "***");
                while (i < text.len and text[i] != '&' and text[i] != ' ' and text[i] != '"' and text[i] != '\'' and text[i] != '\n' and text[i] != '\r') i += 1;
                continue :outer;
            }
        }
        try out.append(alloc, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---- tests ----
const T = struct { url: []const u8, ok: bool, err: ?GuardErr = null };
const hosts = [_][]const u8{ "zalo.me", "www.zalo.me", "*.zaloapp.com" };

test "url table: 60 verdicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const table = [_]T{
        .{ .url = "https://zalo.me/abc", .ok = true },
        .{ .url = "https://ZALO.me/abc", .ok = true },
        .{ .url = "https://zalo.me", .ok = true },
        .{ .url = "https://zalo.me?x=1", .ok = true },
        .{ .url = "https://zalo.me:443/a", .ok = true },
        .{ .url = "https://www.zalo.me/a/b?c=d#frag", .ok = true },
        .{ .url = "https://chat.zaloapp.com/x", .ok = true },
        .{ .url = "https://a.b.zaloapp.com/x", .ok = true },
        .{ .url = "HTTPS://zalo.me/a", .ok = true },
        .{ .url = "http://zalo.me/a", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "ftp://zalo.me/a", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "file:///etc/passwd", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "javascript:alert(1)", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "//zalo.me/a", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "zalo.me/a", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "", .ok = false, .err = GuardErr.Scheme },
        .{ .url = "https://zalo.me:8443/a", .ok = false, .err = GuardErr.Port },
        .{ .url = "https://zalo.me:80/a", .ok = false, .err = GuardErr.Port },
        .{ .url = "https://zalo.me:abc/a", .ok = false, .err = GuardErr.Port },
        .{ .url = "https://zalo.me:99999/a", .ok = false, .err = GuardErr.Port },
        .{ .url = "https://user@zalo.me/a", .ok = false, .err = GuardErr.Userinfo },
        .{ .url = "https://user:pw@zalo.me/a", .ok = false, .err = GuardErr.Userinfo },
        .{ .url = "https://zalo.me@evil.com/a", .ok = false, .err = GuardErr.Userinfo },
        .{ .url = "https://evil.com#@zalo.me/", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://127.0.0.1/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://10.0.0.1/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://169.254.169.254/latest/meta-data", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://2130706433/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://0x7f.0.0.1/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://0x7f000001/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://017700000001/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://[::1]/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://[::ffff:127.0.0.1]/a", .ok = false, .err = GuardErr.IpLiteral },
        .{ .url = "https://localhost/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://localhost.zalo.me.evil.com/a", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://zalo.me.evil.com/a", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://evilzalo.me/a", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://zalo.me.:443/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://-zalo.me/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://za_lo.me/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://zalo..me/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://.zalo.me/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://zaloapp.com/a", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://example.com/a", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://metadata.google.internal/", .ok = false, .err = GuardErr.NotAllowed },
        .{ .url = "https://zalo.me/a b", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/a\tb", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/a\nb", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me\\@evil.com/", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/a\x00b", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/a%00b", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/\xc3\xa9", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/\x7f", .ok = false, .err = GuardErr.BadChars },
        .{ .url = "https://zalo.me/%2e%2e/x", .ok = true },
        .{ .url = "https://zalo.me/..;/x", .ok = true },
        .{ .url = "https://zalo.me/a?u=http://127.0.0.1/", .ok = true },
        .{ .url = "https://zalo.me/#", .ok = true },
        .{ .url = "https://zalo.me:/a", .ok = false, .err = GuardErr.Port },
        .{ .url = "https://:443/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://zalo/a", .ok = false, .err = GuardErr.BadHost },
        .{ .url = "https://xn--zalo-abc.me/a", .ok = false, .err = GuardErr.NotAllowed },
    };
    try std.testing.expect(table.len >= 60);
    for (table) |t| {
        const r = parseUrl(arena.allocator(), t.url, .{ .allow_hosts = &hosts });
        if (t.ok) {
            _ = r catch |e| {
                std.debug.print("expected ok: {s} got {s}\n", .{ t.url, @errorName(e) });
                return error.TestUnexpectedResult;
            };
        } else {
            if (r) |_| {
                std.debug.print("expected refusal: {s}\n", .{t.url});
                return error.TestUnexpectedResult;
            } else |e| if (e != t.err.?) {
                std.debug.print("{s}: want {s} got {s}\n", .{ t.url, @errorName(t.err.?), @errorName(e) });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "mock build allows only loopback http" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const o: Opts = .{ .allow_hosts = &hosts, .mock = true };
    const t = try parseUrl(arena.allocator(), "http://127.0.0.1:8080/x?a=1", o);
    try std.testing.expect(t.loopback and !t.tls and t.port == 8080);
    try std.testing.expectError(GuardErr.Scheme, parseUrl(arena.allocator(), "http://zalo.me/x", o));
    try std.testing.expectError(GuardErr.IpLiteral, parseUrl(arena.allocator(), "http://10.0.0.1/x", o));
    // non-mock build: loopback is just an IP literal / bad scheme
    try std.testing.expectError(GuardErr.Scheme, parseUrl(arena.allocator(), "http://127.0.0.1/x", .{ .allow_hosts = &hosts }));
}

test "ip classes" {
    const bad4 = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 10, 1, 2, 3 }, .{ 127, 0, 0, 1 }, .{ 169, 254, 169, 254 }, .{ 172, 16, 0, 1 }, .{ 172, 31, 255, 255 }, .{ 192, 168, 1, 1 }, .{ 100, 64, 0, 1 }, .{ 198, 18, 0, 1 }, .{ 224, 0, 0, 1 }, .{ 255, 255, 255, 255 } };
    for (bad4) |b| try std.testing.expect(!ip4Public(b));
    const good4 = [_][4]u8{ .{ 8, 8, 8, 8 }, .{ 172, 15, 0, 1 }, .{ 172, 32, 0, 1 }, .{ 100, 63, 0, 1 }, .{ 100, 128, 0, 1 }, .{ 203, 0, 114, 1 } };
    for (good4) |b| try std.testing.expect(ip4Public(b));
    var v6: [16]u8 = @splat(0);
    try std.testing.expect(!ip6Public(v6));
    v6[15] = 1;
    try std.testing.expect(!ip6Public(v6));
    var m: [16]u8 = @splat(0);
    m[10] = 0xff;
    m[11] = 0xff;
    m[12] = 127;
    m[15] = 1;
    try std.testing.expect(!ip6Public(m));
    m[12] = 8;
    m[13] = 8;
    m[14] = 8;
    m[15] = 8;
    try std.testing.expect(ip6Public(m));
    var fc: [16]u8 = @splat(0);
    fc[0] = 0xfd;
    try std.testing.expect(!ip6Public(fc));
    fc[0] = 0xfe;
    fc[1] = 0x80;
    try std.testing.expect(!ip6Public(fc));
    var g: [16]u8 = @splat(0);
    g[0] = 0x26;
    g[1] = 0x06;
    try std.testing.expect(ip6Public(g));
}

const Fake = struct {
    answers: []const Io.net.IpAddress,
    fn f(ctx: ?*anyopaque, _: Io, _: []const u8, _: u16, out: []Io.net.IpAddress) anyerror!usize {
        const s: *const Fake = @ptrCast(@alignCast(ctx.?));
        for (s.answers, 0..) |a, i| out[i] = a;
        return s.answers.len;
    }
};

test "dns rebinding: any private answer refuses; public pins first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try parseUrl(arena.allocator(), "https://zalo.me/a", .{ .allow_hosts = &hosts });
    const pub1 = try Io.net.IpAddress.parse("8.8.8.8", 443);
    const pub2 = try Io.net.IpAddress.parse("1.1.1.1", 443);
    const priv = try Io.net.IpAddress.parse("10.0.0.5", 443);
    const lo = try Io.net.IpAddress.parse("127.0.0.1", 443);
    const ok = Fake{ .answers = &.{ pub1, pub2 } };
    const p = try pin(std.testing.io, .{ .ctx = @constCast(&ok), .func = Fake.f }, t);
    try std.testing.expect(p.ip4.bytes[0] == 8);
    const mixed = Fake{ .answers = &.{ pub1, priv } };
    try std.testing.expectError(GuardErr.PrivateIp, pin(std.testing.io, .{ .ctx = @constCast(&mixed), .func = Fake.f }, t));
    const loop = Fake{ .answers = &.{lo} };
    try std.testing.expectError(GuardErr.PrivateIp, pin(std.testing.io, .{ .ctx = @constCast(&loop), .func = Fake.f }, t));
    const none = Fake{ .answers = &.{} };
    try std.testing.expectError(GuardErr.DnsFail, pin(std.testing.io, .{ .ctx = @constCast(&none), .func = Fake.f }, t));
}

test "redaction hides keys and query values" {
    const a = std.testing.allocator;
    const u = try redactUrl(a, "https://api.x.com/v1?api_key=SECRET&url=zalo.me");
    defer a.free(u);
    try std.testing.expectEqualStrings("https://api.x.com/v1?...", u);
    const ur2 = try redactUrl(a, "https://user:pw@zalo.me/a");
    defer a.free(ur2);
    try std.testing.expectEqualStrings("https://zalo.me/a", ur2);
    const t = try redactText(a, "GET /?token=abc123&x=1 Authorization: Bearer TOPSECRET\nx-api-key: K9");
    defer a.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "TOPSECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "K9") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "x=1") != null);
}
