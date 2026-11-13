// Config loader: strict (unknown key -> refuse with line/col). All tunables live in 00-config.json.
const std = @import("std");

pub const Public = struct {
    user_agent: []const u8 = "zalochat-scrape/0.1",
    allow_hosts: []const []const u8 = &.{},
    gap_ms: u32 = 3000,
    jitter_ms: u32 = 1500,
    timeout_s: u32 = 20,
    body_cap_kb: u32 = 1024,
    daily_cap: u32 = 200,
    robots_ttl_s: u32 = 3600,
    robots_cap_kb: u32 = 128,
    stop_on_block: bool = true,
    retry_5xx: u32 = 1,
    text_cap: u32 = 4000,
    field_cap: u32 = 500,
};
pub const Vendor = struct {
    file: []const u8 = "df-scrape-vendors.json",
    stop_pct: u32 = 80,
    breaker_fails: u32 = 3,
    breaker_cool_s: u32 = 300,
    order: []const []const u8 = &.{},
};
pub const Deliv = struct {
    retries: u32 = 3,
    backoff_ms: u32 = 500,
    secret_env: []const u8 = "SCRAPE_HOOK_SECRET",
    sig_header: []const u8 = "x-scrape-signature",
    pull_page: u32 = 100,
};
pub const Secrets = struct { master_env: []const u8 = "SCRAPE_MASTER_KEY" };
pub const OaPaths = struct {
    authorize: []const u8 = "/v4/oa/permission",
    token: []const u8 = "/v4/oa/access_token",
    info: []const u8 = "/v2.0/oa/getoa",
    followers: []const u8 = "/v2.0/oa/getfollowers",
    profile: []const u8 = "/v2.0/oa/getprofile",
    recent: []const u8 = "/v2.0/oa/listrecentchat",
    conversation: []const u8 = "/v2.0/oa/conversation",
    quota: []const u8 = "/v2.0/oa/quota/message",
    articles: []const u8 = "/v2.0/article/getslice",
    article_detail: []const u8 = "/v2.0/article/getdetail",
};

pub const Oa = struct {
    api_base: []const u8 = "https://openapi.zalo.me",
    oauth_base: []const u8 = "https://oauth.zaloapp.com",
    app_id_env: []const u8 = "ZALO_APP_ID",
    app_secret_env: []const u8 = "ZALO_APP_SECRET",
    refresh_margin_s: u32 = 3600,
    page_users: u32 = 50,
    page_msgs: u32 = 10,
    max_followers: u32 = 10000,
    call_gap_ms: u32 = 500,
    redirect_uri: []const u8 = "",
    max_messages: u32 = 2000,
    max_articles: u32 = 500,
    paths: OaPaths = .{},
};
pub const Legal = struct { retention_days: u32 = 90, consent_required: bool = true };
pub const Side = struct {
    enabled: bool = false,
    node: []const u8 = "node",
    dir: []const u8 = "side",
    lease_ttl_s: u32 = 120,
    daily_cap: u32 = 300,
    whitelist: []const []const u8 = &.{},
    gap_ms: u32 = 1500,
    call_timeout_ms: u32 = 60000,
    history_count: u32 = 50,
    risk_days: u32 = 7,
    max_groups: u32 = 100,
};
pub const Sche = struct { kill_switch: bool = false, max_fails: u32 = 3, spike_pct: u32 = 300 };

pub const Chan = struct { proof_pages: u32 = 20, pass_pct: u32 = 95 };
pub const Watch = struct { ping_env: []const u8 = "SCRAPE_PING_URL", spike_min: u32 = 20 };

pub const Config = struct {
    home: []const u8 = "",
    public: Public = .{},
    vendor: Vendor = .{},
    deliv: Deliv = .{},
    secrets: Secrets = .{},
    oa: Oa = .{},
    legal: Legal = .{},
    side: Side = .{},
    sche: Sche = .{},
    watch: Watch = .{},
    chan: Chan = .{},
};

pub const LoadErr = error{ BadConfig, NoConfig, OutOfMemory };

// Parse text strictly. On failure `why` gets a one-line reason with line/col.
pub fn parse(arena: std.mem.Allocator, text: []const u8, why: *[160]u8, why_len: *usize) LoadErr!Config {
    var diag = std.json.Diagnostics{};
    var sc = std.json.Scanner.initCompleteInput(arena, text);
    defer sc.deinit();
    sc.enableDiagnostics(&diag);
    const cfg = std.json.parseFromTokenSourceLeaky(Config, arena, &sc, .{ .ignore_unknown_fields = false }) catch |e| {
        const s = std.fmt.bufPrint(why, "config: {s} at line {d} col {d}", .{ @errorName(e), diag.getLine(), diag.getColumn() }) catch "config: bad";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    };
    if (cfg.public.gap_ms == 0 or cfg.public.timeout_s == 0 or cfg.public.body_cap_kb == 0) {
        const s = std.fmt.bufPrint(why, "config: public.gap_ms/timeout_s/body_cap_kb must be > 0", .{}) catch "config: bad";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    }
    if (cfg.vendor.stop_pct == 0 or cfg.vendor.stop_pct > 100) {
        const s = std.fmt.bufPrint(why, "config: vendor.stop_pct must be 1..100", .{}) catch "config: bad";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    }
    return cfg;
}

pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8, why: *[160]u8, why_len: *usize) LoadErr!Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch {
        const s = std.fmt.bufPrint(why, "config: cannot read {s}", .{path}) catch "config: unreadable";
        why_len.* = s.len;
        return LoadErr.NoConfig;
    };
    return parse(arena, text, why, why_len);
}

test "parse accepts the shipped shape and refuses unknown keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try parse(arena.allocator(), "{\"public\":{\"gap_ms\":10}}", &w, &n);
    try std.testing.expectEqual(@as(u32, 10), c.public.gap_ms);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"publik\":{}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "line 1") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"public\":{\"gap_ms\":0}}", &w, &n));
}

test "shipped 00-config.json parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try load(arena.allocator(), std.testing.io, "00-config.json", &w, &n);
    try std.testing.expect(c.vendor.order.len == 5);
}
