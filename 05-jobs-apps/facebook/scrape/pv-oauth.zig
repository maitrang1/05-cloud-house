// Own lane connect: Facebook Login (code flow) -> long-lived user token -> Page tokens -> vault. Least scopes from config; a write scope is refused.
// The user token is used once and never stored. A Page belongs to one cust (pages.json); a second cust claiming it is refused.
const std = @import("std");
const util = @import("co-util.zig");
const cfg_mod = @import("co-cfg.zig");
const ctx_mod = @import("co-ctx.zig");
const graph = @import("ap-graph.zig");
const vault_mod = @import("pv-vault.zig");
const store_mod = @import("rw-store.zig");

pub const Page = struct { id: []const u8, name: []const u8 };
pub const Err = error{ PageTaken, NoPages, NoRedirect, WriteScope } || graph.Err || vault_mod.Err;

// the consent URL the cust opens (hand step: they log in and approve)
pub fn authUrl(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, state: []const u8) Err![]u8 {
    const g = cx.cfg.graph;
    if (g.redirect_uri.len == 0) return Err.NoRedirect;
    for (g.scopes) |s| if (cfg_mod.scopeDenied(s, g.deny_scopes)) return Err.WriteScope;
    const id = cx.envGet(g.app_id_env) orelse return Err.NoSecret;
    const sc = std.mem.join(a, ",", g.scopes) catch return Err.OutOfMemory;
    return std.fmt.allocPrint(a, "{s}/{s}/dialog/oauth?client_id={s}&redirect_uri={s}&scope={s}&state={s}&response_type=code", .{ g.dialog, g.version, id, graph.pct(a, g.redirect_uri) catch return Err.OutOfMemory, sc, state }) catch Err.OutOfMemory;
}

fn pagesFile(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/pages.json", .{cx.home});
}

// offboard: the cust gives up its Pages (so another cust may connect them, and no webhook routes to a purged cust)
pub fn release(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, cust: []const u8) void {
    const p = pagesFile(cx, a) catch return;
    const t = util.readAll(a, cx.io, p, 1024 * 1024) catch return;
    const m = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, t, .{}) catch return;
    var out: std.json.ArrayHashMap([]const u8) = .{};
    var it = m.map.iterator();
    while (it.next()) |e| if (!std.mem.eql(u8, e.value_ptr.*, cust)) out.map.put(a, e.key_ptr.*, e.value_ptr.*) catch return;
    util.writeAtomic(a, cx.io, p, std.json.Stringify.valueAlloc(a, out, .{}) catch return) catch {};
}

pub fn ownerOf(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, page: []const u8) ?[]const u8 {
    const t = util.readAll(a, cx.io, pagesFile(cx, a) catch return null, 1024 * 1024) catch return null;
    const m = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, t, .{}) catch return null;
    return m.map.get(page);
}

fn claim(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, page: []const u8, cust: []const u8) !void {
    const p = try pagesFile(cx, a);
    var m: std.json.ArrayHashMap([]const u8) = .{};
    if (util.readAll(a, cx.io, p, 1024 * 1024)) |t| {
        m = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, t, .{}) catch .{};
    } else |_| {}
    if (m.map.get(page)) |o| if (!std.mem.eql(u8, o, cust)) return Err.PageTaken;
    try m.map.put(a, page, cust);
    try util.mkdirp(cx.io, cx.home);
    try util.writeAtomic(a, cx.io, p, try std.json.Stringify.valueAlloc(a, m, .{}));
}

// code -> user token -> long-lived -> Page tokens -> vault. Returns the connected Pages.
pub fn connect(cx: *ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, code: []const u8) Err![]const Page {
    const g = cx.cfg.graph;
    var c = try graph.Client.init(cx, a);
    const redir = g.redirect_uri;
    const tp = g.paths.map.get("token") orelse return Err.Api;
    const s1 = try c.get(null, tp, &.{ .{ "client_id", c.app_id }, .{ "redirect_uri", redir }, .{ "client_secret", c.secret }, .{ "code", code } });
    const short = graph.strOf(s1, "access_token");
    if (short.len == 0) return Err.Api;
    const s2 = try c.get(null, tp, &.{ .{ "grant_type", "fb_exchange_token" }, .{ "client_id", c.app_id }, .{ "client_secret", c.secret }, .{ "fb_exchange_token", short } });
    const long = graph.strOf(s2, "access_token");
    if (long.len == 0) return Err.Api;
    const accts = try c.pull(long, g.paths.map.get("pages") orelse return Err.Api, "id,name,access_token", &.{}, null, null);
    if (accts.len == 0) return Err.NoPages;
    const v = try vault_mod.Vault.open(cx);
    var out: std.ArrayList(Page) = .empty;
    for (accts) |pg| {
        const id = graph.strOf(pg, "id");
        const tok = graph.strOf(pg, "access_token");
        if (id.len == 0 or tok.len == 0) continue;
        claim(cx, a, id, cust) catch |e| return if (e == Err.PageTaken) Err.PageTaken else Err.Api;
        const pn = std.fmt.allocPrint(a, "page.{s}", .{id}) catch return Err.OutOfMemory;
        const dn = std.fmt.allocPrint(a, "dead.{s}", .{id}) catch return Err.OutOfMemory;
        v.putMany(cust, &.{ .{ pn, tok }, .{ dn, "0" } }) catch return Err.BadBlob;
        out.append(a, .{ .id = id, .name = graph.strOf(pg, "name") }) catch return Err.OutOfMemory;
    }
    if (out.items.len == 0) return Err.NoPages;
    // cust file: connected pages + own lane on
    var cu = st.getCust(a, cust) catch @import("rw-shape.zig").Cust{ .cust_id = cust };
    var ids: std.ArrayList([]const u8) = .empty;
    ids.appendSlice(a, cu.pages) catch return Err.OutOfMemory;
    for (out.items) |p| {
        var have = false;
        for (ids.items) |x| if (std.mem.eql(u8, x, p.id)) {
            have = true;
        };
        if (!have) ids.append(a, p.id) catch return Err.OutOfMemory;
    }
    cu.pages = ids.items;
    cu.own_enabled = true;
    st.putCust(a, cu) catch return Err.Api;
    st.audit(cust, cx.nowMs(), "login", "connect", 0, "pages_connected");
    return out.items;
}

pub fn pageToken(v: *const vault_mod.Vault, a: std.mem.Allocator, cust: []const u8, page: []const u8) !?[]u8 {
    const n = try std.fmt.allocPrint(a, "page.{s}", .{page});
    return v.get(a, cust, n);
}

pub fn isDead(v: *const vault_mod.Vault, a: std.mem.Allocator, cust: []const u8, page: []const u8) bool {
    const n = std.fmt.allocPrint(a, "dead.{s}", .{page}) catch return false;
    const x = (v.get(a, cust, n) catch return false) orelse return false;
    return std.mem.eql(u8, x, "1");
}

pub fn markDead(v: *const vault_mod.Vault, a: std.mem.Allocator, cust: []const u8, page: []const u8) void {
    const n = std.fmt.allocPrint(a, "dead.{s}", .{page}) catch return;
    v.put(cust, n, "1") catch {};
}

const mg = @import("te-mock-graph.zig");

test "oauth: connect a Page; token only in the vault; another cust cannot claim it; dead flag" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("FACE_APP_SECRET", mg.secret);
    try env.put("FACE_APP_ID", "APPID1");
    try env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.fake_gap = true;
    var m = mg.Mock{};
    const srv = try m.start(cx.io);
    defer srv.stop();
    var bb: [64]u8 = undefined;
    cx.cfg.graph.base = srv.url(&bb, "");
    cx.cfg.graph.redirect_uri = "https://app.example.com/cb";
    cx.cfg.graph.scopes = &.{ "pages_show_list", "pages_read_engagement" };
    cx.cfg.graph.paths = try cfgPaths(a);
    const st = store_mod.Store.init(cx.io, gpa, home);
    const url = try authUrl(&cx, a, "st1");
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=pages_show_list,pages_read_engagement") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "APPSECRET") == null);
    const pages = try connect(&cx, &st, a, "acme", mg.code);
    try std.testing.expectEqualStrings("P1", pages[0].id);
    const v = try vault_mod.Vault.open(&cx);
    try std.testing.expectEqualStrings("PAGETOK1", (try pageToken(&v, a, "acme", "P1")).?);
    const cu = try st.getCust(a, "acme");
    try std.testing.expect(cu.own_enabled and cu.pages.len == 1);
    // the token is nowhere in clear text
    const raw = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/acme/secrets.enc", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, raw, "PAGETOK1") == null);
    try std.testing.expectEqualStrings("acme", ownerOf(&cx, a, "P1").?);
    try std.testing.expectError(Err.PageTaken, connect(&cx, &st, a, "other", mg.code));
    try std.testing.expect(!isDead(&v, a, "acme", "P1"));
    markDead(&v, a, "acme", "P1");
    try std.testing.expect(isDead(&v, a, "acme", "P1"));
    try std.testing.expectError(Err.Api, connect(&cx, &st, a, "acme", "WRONGCODE"));
    // offboard frees the Page for another cust
    release(&cx, a, "acme");
    try std.testing.expect(ownerOf(&cx, a, "P1") == null);
    _ = try connect(&cx, &st, a, "other", mg.code);
    try std.testing.expectEqualStrings("other", ownerOf(&cx, a, "P1").?);
    // a write scope kills the consent link
    cx.cfg.graph.scopes = &.{"publish_video"};
    try std.testing.expectError(Err.WriteScope, authUrl(&cx, a, "x"));
}

pub fn cfgPaths(a: std.mem.Allocator) !std.json.ArrayHashMap([]const u8) {
    var m: std.json.ArrayHashMap([]const u8) = .{};
    try m.map.put(a, "pages", "me/accounts");
    try m.map.put(a, "token", "oauth/access_token");
    try m.map.put(a, "inbox", "{page}/conversations");
    try m.map.put(a, "msgs", "{conv}/messages");
    try m.map.put(a, "feed", "{page}/published_posts");
    try m.map.put(a, "cmts", "{post}/comments");
    try m.map.put(a, "forms", "{page}/leadgen_forms");
    try m.map.put(a, "leads", "{form}/leads");
    try m.map.put(a, "lives", "{page}/live_videos");
    try m.map.put(a, "lcmts", "{live}/comments");
    try m.map.put(a, "stats", "{page}/insights");
    return m;
}
