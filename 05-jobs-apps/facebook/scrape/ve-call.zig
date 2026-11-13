// One vendor call. Builds the request from the registry row (5 auth styles), sends it through the same pinned-IP client,
// reads the credit header, extracts the page. The key lives in memory only; every error text is redacted.
const std = @import("std");
const Io = std.Io;
const shape = @import("rw-shape.zig");
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");

pub const Env = struct {
    io: Io,
    mock: bool,
    resolver: guard.Resolver = .{},
    ua: []const u8,
    timeout_s: u32,
    cap_bytes: usize,
};

pub const Result = union(enum) {
    ok: struct { body: []const u8, credits: u32 },
    dead, // key rejected (401/403) -> switch the vendor off
    limited, // 402/429 -> plan or rate exhausted
    failed, // 5xx, network, bad shape
    challenge, // vendor returned a captcha/bot page: we stop, never solve
};

pub fn pctEncode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try o.append(a, c);
        } else try o.print(a, "%{X:0>2}", .{c});
    }
    return o.items;
}

pub const Built = struct { url: []const u8, method: []const u8, headers: []const std.http.Header, body: ?[]const u8 };

fn jsonEsc(a: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, s, .{});
}

pub fn build(a: std.mem.Allocator, d: shape.VendorDef, key: []const u8, target: []const u8) !Built {
    var hs: std.ArrayList(std.http.Header) = .empty;
    const post = std.mem.eql(u8, d.method, "POST");
    if (!post) {
        var q: std.ArrayList(u8) = .empty;
        if (d.auth == .query) try q.print(a, "{s}={s}&", .{ d.auth_name, try pctEncode(a, key) });
        try q.print(a, "{s}={s}", .{ d.url_param, try pctEncode(a, target) });
        if (d.extra.len > 0) try q.print(a, "&{s}", .{d.extra});
        switch (d.auth) {
            .header => try hs.append(a, .{ .name = d.auth_name, .value = key }),
            .bearer => try hs.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{key}) }),
            .basic => {
                const raw = try std.fmt.allocPrint(a, "{s}:", .{key});
                const enc = std.base64.standard.Encoder;
                const buf = try a.alloc(u8, enc.calcSize(raw.len));
                _ = enc.encode(buf, raw);
                try hs.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Basic {s}", .{buf}) });
            },
            else => {},
        }
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, d.base, '?') != null) "&" else "?";
        return .{ .url = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ d.base, sep, q.items }), .method = "GET", .headers = hs.items, .body = null };
    }
    // POST: JSON body {url_param: target, [auth_name: key], extra...}
    var b: std.ArrayList(u8) = .empty;
    try b.print(a, "{{{s}:{s}", .{ try jsonEsc(a, d.url_param), try jsonEsc(a, target) });
    if (d.auth == .body) try b.print(a, ",{s}:{s}", .{ try jsonEsc(a, d.auth_name), try jsonEsc(a, key) });
    if (d.extra.len > 0) try b.print(a, ",{s}", .{d.extra});
    try b.append(a, '}');
    try hs.append(a, .{ .name = "Content-Type", .value = "application/json" });
    switch (d.auth) {
        .header => try hs.append(a, .{ .name = d.auth_name, .value = key }),
        .bearer => try hs.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{key}) }),
        .basic => {
            const raw = try std.fmt.allocPrint(a, "{s}:", .{key});
            const enc = std.base64.standard.Encoder;
            const buf = try a.alloc(u8, enc.calcSize(raw.len));
            _ = enc.encode(buf, raw);
            try hs.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Basic {s}", .{buf}) });
        },
        else => {},
    }
    return .{ .url = d.base, .method = "POST", .headers = hs.items, .body = b.items };
}

fn dotPath(a: std.mem.Allocator, body: []const u8, path: []const u8) ?[]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch return null;
    var cur = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return if (cur == .string) cur.string else null;
}

pub fn call(a: std.mem.Allocator, env: Env, d: shape.VendorDef, key: []const u8, target: []const u8) Result {
    const built = build(a, d, key, target) catch return .failed;
    const t = guard.parseUrl(a, built.url, .{ .allow_hosts = &.{hostOf(d.base)}, .mock = env.mock }) catch return .failed;
    const ip = guard.pin(env.io, env.resolver, t) catch return .failed;
    var t2 = t;
    _ = &t2;
    const resp = net.get(env.io, a, t, ip, .{ .ua = env.ua, .timeout_s = env.timeout_s, .cap_bytes = env.cap_bytes, .headers = built.headers, .method = built.method, .body = built.body }) catch return .failed;
    if (resp.status == 401 or resp.status == 403) return .dead;
    if (resp.status == 402 or resp.status == 429) return .limited;
    if (resp.status < 200 or resp.status >= 300) return .failed;
    var credits: u32 = d.cost_default;
    if (d.credit_header.len > 0) {
        const hv = net.headerValue(resp.headers, d.credit_header);
        if (hv.len > 0) credits = std.fmt.parseInt(u32, hv, 10) catch d.cost_default;
    }
    var page: []const u8 = resp.body;
    if (std.mem.startsWith(u8, d.reply, "json:")) page = dotPath(a, resp.body, d.reply[5..]) orelse return .failed;
    if (looksChallenge(page)) return .challenge;
    return .{ .ok = .{ .body = page, .credits = credits } };
}

// a bot-check page in the head of a reply: we stop, never solve
pub fn looksChallenge(body: []const u8) bool {
    const head = body[0..@min(body.len, 8192)];
    const marks = [_][]const u8{ "cf-challenge", "Just a moment...", "g-recaptcha", "h-captcha", "hcaptcha", "Attention Required! | Cloudflare", "captcha-delivery", "px-captcha", "/cdn-cgi/challenge-platform", "checkpoint_title", "/checkpoint/" };
    for (marks) |m| if (std.ascii.indexOfIgnoreCase(head, m) != null) return true;
    return false;
}

fn hostOf(base: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, base, "://") orelse return base;
    const rest = base[i + 3 ..];
    const e = std.mem.indexOfAny(u8, rest, "/:?") orelse rest.len;
    return rest[0..e];
}

test "build: all five auth styles hide the key where it belongs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tgt = "https://facebook.com/a b?x=1&y=2";
    const q = try build(a, .{ .id = "q", .base = "https://v.example/api", .auth = .query, .auth_name = "apikey", .key_env = "K", .extra = "js=false" }, "KEY1", tgt);
    try std.testing.expectEqualStrings("https://v.example/api?apikey=KEY1&url=https%3A%2F%2Ffacebook.com%2Fa%20b%3Fx%3D1%26y%3D2&js=false", q.url);
    const h = try build(a, .{ .id = "h", .base = "https://v.example/api", .auth = .header, .auth_name = "x-api-key", .key_env = "K" }, "KEY1", tgt);
    try std.testing.expect(std.mem.indexOf(u8, h.url, "KEY1") == null);
    try std.testing.expectEqualStrings("KEY1", h.headers[0].value);
    const b = try build(a, .{ .id = "b", .base = "https://v.example/api", .auth = .bearer, .key_env = "K" }, "KEY1", tgt);
    try std.testing.expectEqualStrings("Bearer KEY1", b.headers[0].value);
    const ba = try build(a, .{ .id = "ba", .base = "https://v.example/api", .auth = .basic, .key_env = "K" }, "KEY1", tgt);
    try std.testing.expectEqualStrings("Basic S0VZMTo=", ba.headers[0].value);
    const p = try build(a, .{ .id = "p", .base = "https://v.example/api", .method = "POST", .auth = .body, .auth_name = "token", .key_env = "K", .extra = "\"formats\":[\"html\"]" }, "KEY1", "https://facebook.com/x");
    try std.testing.expectEqualStrings("{\"url\":\"https://facebook.com/x\",\"token\":\"KEY1\",\"formats\":[\"html\"]}", p.body.?);
    try std.testing.expectEqualStrings("https://v.example/api", p.url);
}

// ---- tests against mock-vendor ----
const mv = @import("te-mock-vendor.zig");

fn menv() Env {
    return .{ .io = std.testing.io, .mock = true, .ua = "t/1", .timeout_s = 3, .cap_bytes = 1 << 20 };
}

fn def(a: std.mem.Allocator, srv: *@import("te-mini-srv.zig").Srv, id: []const u8, auth: shape.Auth, auth_name: []const u8) !shape.VendorDef {
    return .{ .id = id, .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/{s}", .{ srv.port, id }), .auth = auth, .auth_name = auth_name, .key_env = "K", .credit_header = "x-cost", .method = if (auth == .body) "POST" else "GET" };
}

test "call: five auth styles reach the mock and return the page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = mv.Vend{ .page = "og:title" };
    const srv = try v.start(std.testing.io);
    defer srv.stop();
    const cases = [_]struct { id: []const u8, auth: shape.Auth, name: []const u8 }{
        .{ .id = "query", .auth = .query, .name = "apikey" },
        .{ .id = "header", .auth = .header, .name = "x-api-key" },
        .{ .id = "bearer", .auth = .bearer, .name = "" },
        .{ .id = "basic", .auth = .basic, .name = "" },
        .{ .id = "body", .auth = .body, .name = "token" },
    };
    for (cases) |c| {
        const d = try def(a, srv, c.id, c.auth, c.name);
        const r = call(a, menv(), d, mv.key, "https://facebook.com/cuahang?x=1");
        try std.testing.expect(r == .ok);
        try std.testing.expect(std.mem.indexOf(u8, r.ok.body, "og:title") != null);
        try std.testing.expectEqual(@as(u32, 1), r.ok.credits);
        try std.testing.expectEqualStrings("https://facebook.com/cuahang?x=1", v.target());
    }
    // wrong key on every style = dead
    for (cases) |c| try std.testing.expect(call(a, menv(), try def(a, srv, c.id, c.auth, c.name), "WRONG", "https://facebook.com/x") == .dead);
}

test "call: header cost overrides default; json reply path; limited/err/challenge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = mv.Vend{ .cost = 5, .page = "og:title" };
    const srv = try v.start(std.testing.io);
    defer srv.stop();
    var d = try def(a, srv, "query", .query, "apikey");
    const r = call(a, menv(), d, mv.key, "https://facebook.com/x");
    try std.testing.expectEqual(@as(u32, 5), r.ok.credits);
    d = try def(a, srv, "json", .header, "x-api-key");
    d.reply = "json:data.html";
    const rj = call(a, menv(), d, mv.key, "https://facebook.com/x");
    try std.testing.expect(rj == .ok and std.mem.indexOf(u8, rj.ok.body, "og:title") != null);
    d.reply = "json:data.nope";
    try std.testing.expect(call(a, menv(), d, mv.key, "https://facebook.com/x") == .failed);
    d = try def(a, srv, "query", .query, "apikey");
    v.setMode(.limited);
    try std.testing.expect(call(a, menv(), d, mv.key, "https://facebook.com/x") == .limited);
    v.setMode(.err);
    try std.testing.expect(call(a, menv(), d, mv.key, "https://facebook.com/x") == .failed);
    v.setMode(.challenge);
    try std.testing.expect(call(a, menv(), d, mv.key, "https://facebook.com/x") == .challenge);
}
