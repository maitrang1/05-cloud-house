// Official Zalo OA API client (READ ONLY - no send endpoint exists in this file or anywhere else).
// Tokens live in the vault. Refresh tokens are single use: the new pair is saved in ONE write before anything else happens.
// A failed refresh marks the cust's OA "dead" and stops all calls (no hammering) until `login` runs again.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");
const guard = @import("pu-guard.zig");
const net = @import("pu-net.zig");
const call_mod = @import("ve-call.zig");
const vault_mod = @import("pv-vault.zig");

pub const Err = error{ NoCreds, NoToken, TokenDead, QuotaStop, Api, Net, BadReply, OutOfMemory, NoMasterKey, BadMasterKey };

pub const Client = struct {
    cx: *ctx_mod.Ctx,
    st: *const store_mod.Store,
    vault: vault_mod.Vault,
    cust: []const u8,
    a: std.mem.Allocator, // run arena
    calls: u32 = 0,
    last_api_error: i64 = 0,

    pub fn init(cx: *ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) Err!Client {
        const v = vault_mod.Vault.open(cx) catch |e| return switch (e) {
            error.NoMasterKey => Err.NoMasterKey,
            error.BadMasterKey => Err.BadMasterKey,
            else => Err.NoCreds,
        };
        return .{ .cx = cx, .st = st, .vault = v, .cust = cust, .a = a };
    }

    fn secret(self: *Client, name: []const u8) ?[]const u8 {
        return (self.vault.get(self.a, self.cust, name) catch return null);
    }

    pub fn status(self: *Client) []const u8 {
        const s = self.secret("oa_status") orelse return if (self.secret("oa_access") != null) "ok" else "none";
        return s;
    }

    fn markDead(self: *Client) void {
        self.vault.put(self.cust, "oa_status", "dead") catch {};
        self.st.audit(self.cust, self.cx.nowMs(), "oapi", "oa", 0, "token_dead");
    }

    fn pace(self: *Client) void {
        if (!self.cx.fake_gap) util.sleepMs(self.cx.io, self.cx.cfg.oa.call_gap_ms);
    }

    // one HTTPS round trip to a configured Zalo base; host allowlist = that base's host only
    fn http(self: *Client, base: []const u8, path_q: []const u8, method: []const u8, hs: []const std.http.Header, body: ?[]const u8) Err!net.Resp {
        const a = self.a;
        const full = std.fmt.allocPrint(a, "{s}{s}", .{ base, path_q }) catch return Err.OutOfMemory;
        const host = hostOf(base);
        const t = guard.parseUrl(a, full, .{ .allow_hosts = &.{host}, .mock = self.cx.mock }) catch return Err.Net;
        const ip = guard.pin(self.cx.io, self.cx.resolver, t) catch return Err.Net;
        return net.get(self.cx.io, a, t, ip, .{ .ua = self.cx.cfg.public.user_agent, .timeout_s = self.cx.cfg.public.timeout_s, .cap_bytes = 4 * 1024 * 1024, .headers = hs, .method = method, .body = body }) catch Err.Net;
    }

    fn tokenCall(self: *Client, form: []const u8) Err!void {
        const c = self.cx.cfg.oa;
        const sec = self.cx.envGet(c.app_secret_env) orelse return Err.NoCreds;
        const hs = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "secret_key", .value = sec },
        };
        const r = try self.http(c.oauth_base, c.paths.token, "POST", &hs, form);
        const v = std.json.parseFromSliceLeaky(std.json.Value, self.a, r.body, .{ .allocate = .alloc_always }) catch return Err.BadReply;
        if (v != .object) return Err.BadReply;
        if (v.object.get("error")) |e| if (e == .integer and e.integer != 0) return Err.Api;
        const at = v.object.get("access_token") orelse return Err.BadReply;
        const rt = v.object.get("refresh_token") orelse return Err.BadReply;
        if (at != .string or rt != .string) return Err.BadReply;
        var ttl: i64 = 90000;
        if (v.object.get("expires_in")) |x| ttl = switch (x) {
            .string => std.fmt.parseInt(i64, x.string, 10) catch 90000,
            .integer => x.integer,
            else => 90000,
        };
        ttl = std.math.clamp(ttl, 60, 365 * 86400); // a hostile or buggy reply cannot overflow the clock math
        const exp = std.fmt.allocPrint(self.a, "{d}", .{self.cx.nowMs() + ttl * 1000}) catch return Err.OutOfMemory;
        // single write: both tokens + expiry + status rotate together
        self.vault.putMany(self.cust, &.{ .{ "oa_access", at.string }, .{ "oa_refresh", rt.string }, .{ "oa_expires_ms", exp }, .{ "oa_status", "ok" } }) catch return Err.Net;
    }

    pub fn refresh(self: *Client) Err!void {
        const rt = self.secret("oa_refresh") orelse return Err.NoToken;
        const app_id = self.cx.envGet(self.cx.cfg.oa.app_id_env) orelse return Err.NoCreds;
        const form = std.fmt.allocPrint(self.a, "refresh_token={s}&app_id={s}&grant_type=refresh_token", .{ rt, app_id }) catch return Err.OutOfMemory;
        self.tokenCall(form) catch |e| {
            if (e == Err.Api or e == Err.BadReply) {
                self.markDead();
                return Err.TokenDead;
            }
            return e;
        };
        self.st.audit(self.cust, self.cx.nowMs(), "oapi", "oa", 0, "token_refreshed");
    }

    pub fn exchangeCode(self: *Client, code: []const u8) Err!void {
        const verifier = self.secret("oa_pkce_verifier") orelse return Err.NoToken;
        const app_id = self.cx.envGet(self.cx.cfg.oa.app_id_env) orelse return Err.NoCreds;
        const form = std.fmt.allocPrint(self.a, "code={s}&app_id={s}&grant_type=authorization_code&code_verifier={s}", .{ code, app_id, verifier }) catch return Err.OutOfMemory;
        try self.tokenCall(form);
        self.st.audit(self.cust, self.cx.nowMs(), "oapi", "oa", 0, "connected");
    }

    // authorize url for the cust to open; verifier + state saved in the vault (PKCE)
    pub fn authorizeUrl(self: *Client) Err![]u8 {
        const c = self.cx.cfg.oa;
        const app_id = self.cx.envGet(c.app_id_env) orelse return Err.NoCreds;
        if (c.redirect_uri.len == 0) return Err.NoCreds;
        var rnd: [48]u8 = undefined;
        self.cx.io.random(&rnd);
        const enc = std.base64.url_safe_no_pad.Encoder;
        const verifier = self.a.alloc(u8, enc.calcSize(rnd.len)) catch return Err.OutOfMemory;
        _ = enc.encode(verifier, &rnd);
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &h, .{});
        const chal = self.a.alloc(u8, enc.calcSize(h.len)) catch return Err.OutOfMemory;
        _ = enc.encode(chal, &h);
        var sb: [16]u8 = undefined;
        self.cx.io.random(&sb);
        const state = util.hexEncode(self.a, &sb) catch return Err.OutOfMemory;
        self.vault.putMany(self.cust, &.{ .{ "oa_pkce_verifier", verifier }, .{ "oa_state", state } }) catch return Err.Net;
        const ru = call_mod.pctEncode(self.a, c.redirect_uri) catch return Err.OutOfMemory;
        return std.fmt.allocPrint(self.a, "{s}{s}?app_id={s}&redirect_uri={s}&code_challenge={s}&code_challenge_method=S256&state={s}", .{ c.oauth_base, c.paths.authorize, app_id, ru, chal, state }) catch Err.OutOfMemory;
    }

    fn accessToken(self: *Client) Err![]const u8 {
        const st = self.secret("oa_status");
        if (st != null and std.mem.eql(u8, st.?, "dead")) return Err.TokenDead;
        const at = self.secret("oa_access") orelse return Err.NoToken;
        const exp_s = self.secret("oa_expires_ms") orelse return at;
        const exp = std.fmt.parseInt(i64, exp_s, 10) catch 0;
        if (self.cx.nowMs() + @as(i64, self.cx.cfg.oa.refresh_margin_s) * 1000 >= exp) {
            try self.refresh();
            return self.secret("oa_access") orelse Err.NoToken;
        }
        return at;
    }

    // GET path?data=<json>; returns the `data` member. -216/-124 -> refresh once and retry; -223/-224 -> QuotaStop
    pub fn call(self: *Client, path: []const u8, data_json: []const u8) Err!std.json.Value {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const tok = try self.accessToken();
            const pq = std.fmt.allocPrint(self.a, "{s}?data={s}", .{ path, call_mod.pctEncode(self.a, data_json) catch return Err.OutOfMemory }) catch return Err.OutOfMemory;
            const hs = [_]std.http.Header{.{ .name = "access_token", .value = tok }};
            self.calls += 1;
            const r = try self.http(self.cx.cfg.oa.api_base, pq, "GET", &hs, null);
            self.pace();
            if (r.status < 200 or r.status >= 300) return Err.Net;
            const v = std.json.parseFromSliceLeaky(std.json.Value, self.a, r.body, .{ .allocate = .alloc_always }) catch return Err.BadReply;
            if (v != .object) return Err.BadReply;
            const code: i64 = if (v.object.get("error")) |e| (if (e == .integer) e.integer else 0) else 0;
            self.last_api_error = code;
            if (code == 0) return v.object.get("data") orelse .null;
            if ((code == -216 or code == -124) and attempt == 0) {
                try self.refresh();
                continue;
            }
            if (code == -216 or code == -124) {
                self.markDead();
                return Err.TokenDead;
            }
            if (code == -223 or code == -224) return Err.QuotaStop;
            return Err.Api;
        }
    }
};

fn hostOf(base: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, base, "://") orelse return base;
    const rest = base[i + 3 ..];
    const e = std.mem.indexOfAny(u8, rest, "/:?") orelse rest.len;
    return rest[0..e];
}

// ---- tests ----
const mo = @import("te-mock-oapi.zig");

pub const Rig = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    hb: [128]u8 = undefined,
    home: []const u8 = "",
    cx: ctx_mod.Ctx = undefined,
    st: store_mod.Store = undefined,
    mock: mo.Oapi = .{},
    srv: *@import("te-mini-srv.zig").Srv = undefined,

    pub fn setup(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.env = std.process.Environ.Map.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.home = try std.fmt.bufPrint(&self.hb, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
        const a = self.arena.allocator();
        try self.env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        try self.env.put("ZALO_APP_ID", "APPID1");
        try self.env.put("ZALO_APP_SECRET", "APPSECRET");
        self.cx = ctx_mod.testCtx(a, &self.env, self.home);
        self.cx.mock = true;
        self.cx.fake_gap = true;
        self.cx.cfg.public.user_agent = "t/1";
        self.cx.cfg.public.timeout_s = 3;
        self.srv = try self.mock.start(self.cx.io);
        const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.srv.port});
        self.cx.cfg.oa.api_base = base;
        self.cx.cfg.oa.oauth_base = base;
        self.cx.cfg.oa.redirect_uri = "https://app.example/cb";
        self.cx.cfg.oa.page_users = 50;
        self.cx.cfg.oa.page_msgs = 10;
        self.cx.cfg.oa.max_followers = 10000;
        self.st = store_mod.Store.init(self.cx.io, std.testing.allocator, self.home);
        try self.st.putCust(a, .{ .cust_id = "alpha", .consent = true, .consent_at = 1, .oa_enabled = true });
    }
    pub fn teardown(self: *Rig) void {
        self.srv.stop();
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "oapi: login by code, call, expiry -> one refresh, single-use rotation" {
    var rig = Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    var c = try Client.init(&rig.cx, &rig.st, a, "alpha");
    const url = try c.authorizeUrl();
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "app_id=APPID1") != null);
    try std.testing.expectEqualStrings("none", c.status()[0..4]);
    try c.exchangeCode("GOODCODE");
    try std.testing.expectEqualStrings("ok", c.status());
    const d = try c.call("/v2.0/oa/getoa", "{}");
    try std.testing.expectEqualStrings("Test OA", d.object.get("name").?.string);
    // server kills the access token: client refreshes once, retries, succeeds
    rig.mock.expireNow();
    const d2 = try c.call("/v2.0/oa/getoa", "{}");
    try std.testing.expect(d2 == .object);
    try std.testing.expectEqual(@as(u32, 1), rig.mock.refreshes);
    // again: second rotation works because the NEW refresh token was saved
    rig.mock.expireNow();
    _ = try c.call("/v2.0/oa/getoa", "{}");
    try std.testing.expectEqual(@as(u32, 2), rig.mock.refreshes);
    // a used code cannot be replayed
    var c2 = try Client.init(&rig.cx, &rig.st, a, "alpha");
    _ = try c2.authorizeUrl();
    try std.testing.expectError(Err.Api, c2.exchangeCode("GOODCODE"));
}

test "oapi: dead refresh token reads dead and stops calling" {
    var rig = Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    var c = try Client.init(&rig.cx, &rig.st, a, "alpha");
    _ = try c.authorizeUrl();
    try c.exchangeCode("GOODCODE");
    rig.mock.expireNow();
    rig.mock.refresh_dead = true;
    try std.testing.expectError(Err.TokenDead, c.call("/v2.0/oa/getoa", "{}"));
    try std.testing.expectEqualStrings("dead", c.status());
    const before = rig.mock.calls;
    try std.testing.expectError(Err.TokenDead, c.call("/v2.0/oa/getoa", "{}"));
    try std.testing.expectEqual(before, rig.mock.calls); // no network once dead
}

test "oapi: quota error stops softly; no master key / no creds are refused; no secrets in audit" {
    var rig = Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    var c = try Client.init(&rig.cx, &rig.st, a, "alpha");
    _ = try c.authorizeUrl();
    try c.exchangeCode("GOODCODE");
    rig.mock.quota_stop = true;
    try std.testing.expectError(Err.QuotaStop, c.call("/v2.0/oa/quota/message", "{}"));
    try std.testing.expectEqualStrings("ok", c.status()); // not dead
    const audit = try util.readAll(a, rig.cx.io, try std.fmt.allocPrint(a, "{s}/cust/alpha/audit.jsonl", .{rig.home}), 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, audit, "ACCESS-") == null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "REFRESH-") == null);
    try std.testing.expect(std.mem.indexOf(u8, audit, "APPSECRET") == null);
    _ = rig.env.swapRemove("SCRAPE_MASTER_KEY");
    try std.testing.expectError(Err.NoMasterKey, Client.init(&rig.cx, &rig.st, a, "alpha"));
    try rig.env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    _ = rig.env.swapRemove("ZALO_APP_SECRET");
    var c3 = try Client.init(&rig.cx, &rig.st, a, "alpha");
    try std.testing.expectError(Err.NoCreds, c3.refresh());
}
