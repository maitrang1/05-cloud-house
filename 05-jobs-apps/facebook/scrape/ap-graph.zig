// Graph client: GET only (no write call exists here). Version pinned in config, appsecret_proof on every token call,
// cursor paging, error classes, usage-header throttle. Unknown fields stay in the JSON Value and never crash a sync.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const guard = @import("co-guard.zig");
const net = @import("co-net.zig");
const usage = @import("ap-usage.zig");

pub const Err = error{ NoSecret, NoToken, Guard, Net, BadJson, DeadToken, Blocked, RateLimited, UsageStop, Api, OutOfMemory };

pub const Class = enum { dead_token, block, rate, other };

// documented codes: 190 102 463 467 dead token · 368 block · 4 17 32 613 80001..80014 rate
pub fn classify(code: i64) Class {
    return switch (code) {
        190, 102, 463, 467 => .dead_token,
        368 => .block,
        4, 17, 32, 613 => .rate,
        else => if (code >= 80001 and code <= 80014) .rate else .other,
    };
}

pub const Param = struct { []const u8, []const u8 };

pub fn proofHex(secret: []const u8, token: []const u8) [64]u8 {
    const H = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [H.mac_length]u8 = undefined;
    H.create(&mac, token, secret);
    return std.fmt.bytesToHex(mac, .lower);
}

pub fn pct(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var o: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try o.append(a, c) else try o.print(a, "%{X:0>2}", .{c});
    }
    return o.items;
}

pub const Client = struct {
    cx: *ctx_mod.Ctx,
    a: std.mem.Allocator,
    secret: []const u8,
    app_id: []const u8,
    calls: u32 = 0,
    slowed: u32 = 0,
    stopped: bool = false,
    last_pct: u32 = 0,
    last_code: i64 = 0, // Graph error code of the last failed call (never the token)

    pub fn init(cx: *ctx_mod.Ctx, a: std.mem.Allocator) Err!Client {
        const g = cx.cfg.graph;
        const sec = cx.envGet(g.app_secret_env) orelse return Err.NoSecret;
        return .{ .cx = cx, .a = a, .secret = sec, .app_id = cx.envGet(g.app_id_env) orelse "" };
    }

    fn hostOf(base: []const u8) []const u8 {
        const i = std.mem.indexOf(u8, base, "://") orelse return base;
        const rest = base[i + 3 ..];
        const e = std.mem.indexOfAny(u8, rest, "/:?") orelse rest.len;
        return rest[0..e];
    }

    // one GET. token null = app-level call (oauth); a token always carries appsecret_proof.
    pub fn get(self: *Client, token: ?[]const u8, path: []const u8, params: []const Param) Err!std.json.Value {
        const g = self.cx.cfg.graph;
        if (self.stopped) return Err.UsageStop;
        const a = self.a;
        var q: std.ArrayList(u8) = .empty;
        for (params) |p| q.print(a, "{s}={s}&", .{ p[0], pct(a, p[1]) catch return Err.OutOfMemory }) catch return Err.OutOfMemory;
        if (token) |t| {
            if (t.len == 0) return Err.NoToken;
            const pr = proofHex(self.secret, t);
            q.print(a, "access_token={s}&appsecret_proof={s}", .{ pct(a, t) catch return Err.OutOfMemory, pr }) catch return Err.OutOfMemory;
        } else if (q.items.len > 0) _ = q.pop();
        const url = std.fmt.allocPrint(a, "{s}/{s}/{s}?{s}", .{ g.base, g.version, path, q.items }) catch return Err.OutOfMemory;
        const t = guard.parseUrl(a, url, .{ .allow_hosts = &.{hostOf(g.base)}, .mock = self.cx.mock }) catch return Err.Guard;
        const ip = guard.pin(self.cx.io, self.cx.resolver, t) catch return Err.Guard;
        if (!self.cx.fake_gap and self.calls > 0) util.sleepMs(self.cx.io, g.call_gap_ms);
        self.calls += 1;
        const resp = net.get(self.cx.io, a, t, ip, .{ .ua = g.user_agent, .timeout_s = g.timeout_s, .cap_bytes = @as(usize, g.body_cap_kb) * 1024 }) catch return Err.Net;
        // throttle on the usage headers (both kinds); stop is sticky for the run
        const u = usage.parse(a, net.headerValue(resp.headers, "x-app-usage"), net.headerValue(resp.headers, "x-business-use-case-usage"));
        self.last_pct = u.pct;
        switch (usage.verdict(u, g.slow_pct, g.stop_pct)) {
            .go => {},
            .slow => {
                self.slowed += 1;
                if (!self.cx.fake_gap) util.sleepMs(self.cx.io, g.slow_ms);
            },
            .stop => self.stopped = true,
        }
        if (resp.status >= 300 and resp.status < 400) return Err.Net;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, resp.body, .{ .allocate = .alloc_always }) catch return Err.BadJson;
        if (v == .object) if (v.object.get("error")) |e| {
            var code: i64 = 0;
            if (e == .object) if (e.object.get("code")) |c| if (c == .integer) {
                code = c.integer;
            };
            self.last_code = code;
            return switch (classify(code)) {
                .dead_token => Err.DeadToken,
                .block => Err.Blocked,
                .rate => Err.RateLimited,
                .other => Err.Api,
            };
        };
        if (resp.status >= 400) return Err.Api;
        return v;
    }

    // all items of a list edge, newest first as Graph returns them, by cursor. Stops at max_pages / max_rows / stop_at (id already known).
    pub fn pull(self: *Client, token: []const u8, path: []const u8, fields: []const u8, extra: []const Param, stop_at: ?*const fn (ctx: ?*anyopaque, item: std.json.Value) bool, stop_ctx: ?*anyopaque) Err![]const std.json.Value {
        const g = self.cx.cfg.graph;
        const a = self.a;
        var out: std.ArrayList(std.json.Value) = .empty;
        var after: []const u8 = "";
        var page: u32 = 0;
        const lim = std.fmt.allocPrint(a, "{d}", .{g.page_size}) catch return Err.OutOfMemory;
        while (page < g.max_pages) : (page += 1) {
            var ps: std.ArrayList(Param) = .empty;
            ps.append(a, .{ "fields", fields }) catch return Err.OutOfMemory;
            ps.append(a, .{ "limit", lim }) catch return Err.OutOfMemory;
            if (after.len > 0) ps.append(a, .{ "after", after }) catch return Err.OutOfMemory;
            ps.appendSlice(a, extra) catch return Err.OutOfMemory;
            const v = try self.get(token, path, ps.items);
            if (v != .object) return Err.BadJson;
            const data = v.object.get("data") orelse return Err.BadJson;
            if (data != .array) return Err.BadJson;
            for (data.array.items) |it| {
                if (stop_at) |f| if (f(stop_ctx, it)) return out.items;
                out.append(a, it) catch return Err.OutOfMemory;
                if (out.items.len >= g.max_rows) return out.items;
            }
            after = "";
            if (v.object.get("paging")) |pg| if (pg == .object) {
                const has_next = pg.object.get("next") != null;
                if (has_next) if (pg.object.get("cursors")) |cu| if (cu == .object) if (cu.object.get("after")) |af| if (af == .string) {
                    after = af.string;
                };
            };
            if (after.len == 0) break;
        }
        return out.items;
    }
};

pub fn strOf(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

test "classify maps every documented code" {
    for ([_]i64{ 190, 102, 463, 467 }) |c| try std.testing.expectEqual(Class.dead_token, classify(c));
    try std.testing.expectEqual(Class.block, classify(368));
    for ([_]i64{ 4, 17, 32, 613, 80001, 80008, 80014 }) |c| try std.testing.expectEqual(Class.rate, classify(c));
    try std.testing.expectEqual(Class.other, classify(100));
    try std.testing.expectEqual(Class.other, classify(80015));
}

test "proof is HMAC-SHA256(secret, token) in hex" {
    const p = proofHex("secret", "token");
    try std.testing.expectEqual(@as(usize, 64), p.len);
    try std.testing.expectEqualStrings(&p, &proofHex("secret", "token"));
    try std.testing.expect(!std.mem.eql(u8, &p, &proofHex("secret", "token2")));
}

// ---- tests against the mock Graph ----
const mg = @import("te-mock-graph.zig");

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    mock: mg.Mock = .{},
    srv: *@import("te-mini-srv.zig").Srv = undefined,
    cx: ctx_mod.Ctx = undefined,
    base: [64]u8 = undefined,

    fn up(self: *Rig, secret: []const u8) !Client {
        self.mock = .{};
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.env = std.process.Environ.Map.init(std.testing.allocator);
        try self.env.put("FACE_APP_SECRET", secret);
        self.cx = ctx_mod.testCtx(self.arena.allocator(), &self.env, ".");
        self.cx.mock = true;
        self.cx.fake_gap = true;
        self.srv = try self.mock.start(self.cx.io);
        self.cx.cfg.graph.base = self.srv.url(&self.base, "");
        return Client.init(&self.cx, self.arena.allocator());
    }
    fn down(self: *Rig) void {
        self.srv.stop();
        self.env.deinit();
        self.arena.deinit();
    }
};

test "graph: cursor paging gets every item; unknown fields do not crash" {
    var r: Rig = undefined;
    var c = try r.up(mg.secret);
    defer r.down();
    const items = try c.pull(mg.page_tok, "P1/conversations", "id", &.{}, null, null);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const acc = try c.pull(mg.user_long, "me/accounts", "id", &.{}, null, null);
    try std.testing.expectEqualStrings("P1", strOf(acc[0], "id"));
    try std.testing.expectEqual(@as(u32, 0), r.mock.bad_proofs.load(.acquire));
}

test "graph: every error code maps to its class" {
    var r: Rig = undefined;
    var c = try r.up(mg.secret);
    defer r.down();
    try std.testing.expectError(Err.DeadToken, c.get("DEADTOK", "P1/conversations", &.{}));
    try std.testing.expectEqual(@as(i64, 190), c.last_code);
    try std.testing.expectError(Err.Blocked, c.get("BLOCKTOK", "P1/conversations", &.{}));
    try std.testing.expectError(Err.RateLimited, c.get("RATETOK", "P1/conversations", &.{}));
    try std.testing.expectError(Err.Api, c.get(mg.page_tok, "P1/nothing", &.{}));
}

test "graph: a call without the right proof is refused by the server; no secret = no client" {
    var r: Rig = undefined;
    var c = try r.up("WRONGSECRET");
    defer r.down();
    try std.testing.expectError(Err.Api, c.get(mg.page_tok, "P1/conversations", &.{}));
    try std.testing.expect(r.mock.bad_proofs.load(.acquire) == 1);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cx = ctx_mod.testCtx(arena.allocator(), &env, ".");
    try std.testing.expectError(Err.NoSecret, Client.init(&cx, arena.allocator()));
    try std.testing.expectError(Err.NoToken, c.get("", "P1/conversations", &.{}));
}

test "graph: usage 85% slows, 96% stops the run" {
    var r: Rig = undefined;
    var c = try r.up(mg.secret);
    defer r.down();
    r.mock.usage_pct.store(85, .release);
    _ = try c.get(mg.page_tok, "P1/live_videos", &.{});
    try std.testing.expectEqual(@as(u32, 1), c.slowed);
    try std.testing.expect(!c.stopped);
    r.mock.usage_pct.store(96, .release);
    _ = try c.get(mg.page_tok, "P1/live_videos", &.{});
    try std.testing.expect(c.stopped);
    try std.testing.expectError(Err.UsageStop, c.get(mg.page_tok, "P1/live_videos", &.{}));
}

test "graph: a bad host in config is refused by the guard" {
    var r: Rig = undefined;
    var c = try r.up(mg.secret);
    defer r.down();
    r.cx.cfg.graph.base = "http://169.254.169.254";
    try std.testing.expectError(Err.Guard, c.get(mg.page_tok, "P1/conversations", &.{}));
    r.cx.cfg.graph.base = "https://evil.example.com";
    try std.testing.expectError(Err.Guard, c.get(mg.page_tok, "P1/conversations", &.{}));
}
