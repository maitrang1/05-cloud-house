// Config loader: strict (unknown key -> refuse with line/col). All tunables live in 00-config.json.
const std = @import("std");

pub const Kind = struct {
    list: []const u8 = "", // dotted path to the array in a vendor reply ("" = reply itself, array or one object)
    key: []const []const u8 = &.{}, // candidate fields for the row key, first present wins
    fields: std.json.ArrayHashMap([]const []const u8) = .{}, // out name -> candidate vendor fields
    personal: []const []const u8 = &.{}, // out names that hold personal data (flagged on the row)
};
pub const Market = struct {
    user_agent: []const u8 = "facebook-scrape/0.1",
    allow_hosts: []const []const u8 = &.{},
    timeout_s: u32 = 20,
    body_cap_kb: u32 = 1024,
    daily_cap: u32 = 200,
    text_cap: u32 = 4000,
    field_cap: u32 = 500,
    kinds: std.json.ArrayHashMap(Kind) = .{},
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
pub const Graph = struct {
    base: []const u8 = "https://graph.facebook.com",
    dialog: []const u8 = "https://www.facebook.com",
    version: []const u8 = "v26.0",
    app_id_env: []const u8 = "FACE_APP_ID",
    app_secret_env: []const u8 = "FACE_APP_SECRET",
    redirect_uri: []const u8 = "",
    scopes: []const []const u8 = &.{},
    deny_scopes: []const []const u8 = &.{},
    page_size: u32 = 25,
    max_pages: u32 = 20,
    max_rows: u32 = 5000,
    call_gap_ms: u32 = 300,
    slow_pct: u32 = 80,
    stop_pct: u32 = 95,
    slow_ms: u32 = 2000,
    timeout_s: u32 = 20,
    body_cap_kb: u32 = 2048,
    user_agent: []const u8 = "facebook-scrape/0.1",
    insights: []const []const u8 = &.{},
    insights_period: []const u8 = "day",
    fields: std.json.ArrayHashMap([]const u8) = .{}, // per resource: Graph `fields=` list (inbox, msgs, feed, cmts, forms, leads, lives, lcmts)
    paths: std.json.ArrayHashMap([]const u8) = .{}, // per resource: path template, {page} {conv} {post} {form} {live} filled in
};
pub const Hook = struct {
    verify_env: []const u8 = "FACE_HOOK_VERIFY",
    status_url: []const u8 = "",
    user_keys: []const []const u8 = &.{}, // data fields that hold a Facebook user id (deletion purge)
};
pub const Legal = struct { retention_days: u32 = 90, consent_required: bool = true, own_expire_days: u32 = 30 };
pub const Sche = struct { kill_switch: bool = false, max_fails: u32 = 3, spike_pct: u32 = 300 };
pub const Watch = struct { ping_env: []const u8 = "SCRAPE_PING_URL", spike_min: u32 = 20 };

pub const Config = struct {
    home: []const u8 = "",
    market: Market = .{},
    vendor: Vendor = .{},
    deliv: Deliv = .{},
    secrets: Secrets = .{},
    graph: Graph = .{},
    hook: Hook = .{},
    legal: Legal = .{},
    sche: Sche = .{},
    watch: Watch = .{},
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
    if (cfg.market.timeout_s == 0 or cfg.market.body_cap_kb == 0 or cfg.graph.timeout_s == 0) {
        const s = std.fmt.bufPrint(why, "config: market/graph timeout_s and body_cap_kb must be > 0", .{}) catch "config: bad";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    }
    if (cfg.vendor.stop_pct == 0 or cfg.vendor.stop_pct > 100) {
        const s = std.fmt.bufPrint(why, "config: vendor.stop_pct must be 1..100", .{}) catch "config: bad";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    }
    if (cfg.graph.slow_pct == 0 or cfg.graph.stop_pct <= cfg.graph.slow_pct or cfg.graph.stop_pct > 100) {
        const s = std.fmt.bufPrint(why, "config: graph.slow_pct < stop_pct <= 100", .{}) catch "config: bad";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    }
    for (cfg.graph.scopes) |scp| if (scopeDenied(scp, cfg.graph.deny_scopes)) {
        const s = std.fmt.bufPrint(why, "config: graph.scopes has a write scope: {s}", .{scp}) catch "config: write scope";
        why_len.* = s.len;
        return LoadErr.BadConfig;
    };
    return cfg;
}

// a scope is a write scope when it is in deny_scopes or starts with publish_ (read-only app: none may be requested)
pub fn scopeDenied(sc: []const u8, deny: []const []const u8) bool {
    if (std.mem.startsWith(u8, sc, "publish_")) return true;
    for (deny) |d| if (std.mem.eql(u8, sc, d)) return true;
    return false;
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
    const c = try parse(arena.allocator(), "{\"market\":{\"timeout_s\":10}}", &w, &n);
    try std.testing.expectEqual(@as(u32, 10), c.market.timeout_s);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"markt\":{}}", &w, &n));
    try std.testing.expect(std.mem.indexOf(u8, w[0..n], "line 1") != null);
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"market\":{\"timeout_s\":0}}", &w, &n));
}

test "a write scope in config is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"graph\":{\"scopes\":[\"pages_show_list\",\"publish_video\"]}}", &w, &n));
    try std.testing.expectError(LoadErr.BadConfig, parse(arena.allocator(), "{\"graph\":{\"scopes\":[\"pages_manage_posts\"],\"deny_scopes\":[\"pages_manage_posts\"]}}", &w, &n));
    _ = try parse(arena.allocator(), "{\"graph\":{\"scopes\":[\"pages_show_list\"],\"deny_scopes\":[\"pages_manage_posts\"]}}", &w, &n);
}

test "shipped 00-config.json parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = try load(arena.allocator(), std.testing.io, "00-config.json", &w, &n);
    try std.testing.expect(c.vendor.order.len == 3);
    try std.testing.expect(c.market.kinds.map.count() >= 5);
}
