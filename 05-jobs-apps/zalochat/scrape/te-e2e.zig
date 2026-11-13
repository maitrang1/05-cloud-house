// e2e on mocks: the whole CLI router, every outside service faked on loopback (site, vendor, OA API, webhook receiver).
const std = @import("std");
const util = @import("co-util.zig");
const main = @import("main.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const ms = @import("te-mini-srv.zig");
const site = @import("te-mock-site.zig");
const mv = @import("te-mock-vendor.zig");
const mo = @import("te-mock-oapi.zig");

const Hook = struct { n: std.atomic.Value(u32) = .init(0) };
fn hookH(ctx: *anyopaque, _: std.mem.Allocator, _: ms.Request) ms.Reply {
    const h: *Hook = @ptrCast(@alignCast(ctx));
    _ = h.n.fetchAdd(1, .acq_rel);
    return .{};
}

fn run(cx: *ctx_mod.Ctx, comptime line: []const u8) u8 {
    comptime var parts: [24][]const u8 = undefined;
    comptime var n = 0;
    comptime {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |p| : (n += 1) parts[n] = p;
    }
    const av: [n][]const u8 = parts[0..n].*;
    return main.dispatch(cx, &av, false);
}

test "e2e: a cust from first consent to purge" {
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
    try env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    try env.put("ZALO_APP_ID", "APPID1");
    try env.put("ZALO_APP_SECRET", "APPSECRET");
    try env.put("SCRAPE_HOOK_SECRET", "whsec_e2e");
    try env.put("E2E_VKEY", mv.key);
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.fake_gap = true;
    var s = site.Site.init(gpa);
    defer s.deinit();
    const ssrv = try s.start(cx.io);
    defer ssrv.stop();
    var v = mv.Vend{ .cost = 3 };
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    var o = mo.Oapi{};
    o.followers = 3;
    const osrv = try o.start(cx.io);
    defer osrv.stop();
    var hk = Hook{};
    const hsrv = try ms.Srv.start(cx.io, hookH, &hk);
    defer hsrv.stop();
    const obase = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{osrv.port});
    cx.cfg.public = .{ .user_agent = "e2e/1", .allow_hosts = &.{"zalo.me"}, .gap_ms = 1, .jitter_ms = 0, .timeout_s = 3, .body_cap_kb = 64, .daily_cap = 20, .robots_ttl_s = 60, .robots_cap_kb = 4 };
    cx.cfg.vendor.order = &.{"ve"};
    cx.cfg.oa.api_base = obase;
    cx.cfg.oa.oauth_base = obase;
    cx.cfg.oa.redirect_uri = "https://app.example/cb";
    const defs = [_]shape.VendorDef{.{ .id = "ve", .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{vsrv.port}), .auth = .query, .auth_name = "apikey", .key_env = "E2E_VKEY", .credit_header = "x-cost", .budget = 100 }};
    cx.vendor_reg = .{ .defs = &defs };
    var st = store_mod.Store.init(cx.io, gpa, home);
    // cust file with real mock urls (cust.json is the one hand-made file)
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    var b3: [128]u8 = undefined;
    const u_ok = try a.dupe(u8, ssrv.url(&b1, "/oa/ok"));
    const u_403 = try a.dupe(u8, ssrv.url(&b2, "/oa/403"));
    const u_priv = try a.dupe(u8, ssrv.url(&b3, "/private/x"));
    try st.putCust(a, .{ .cust_id = "e2ecust", .urls = &.{ u_ok, u_403, u_priv }, .webhook_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/hook", .{hsrv.port}) });

    // legal + public path
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "sync --cust e2ecust --tier oa")); // no consent yet
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "consent --cust e2ecust --grant"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "scan --cust e2ecust --dry-run"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "scan --cust e2ecust"));
    try std.testing.expectEqual(@as(usize, 2), try st.countRows("e2ecust")); // ok page + 403 page via vendor
    try std.testing.expectEqual(@as(u32, 0), s.hitsOf("/private/x")); // robots respected
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "scan --cust e2ecust"));
    try std.testing.expectEqual(@as(usize, 2), try st.countRows("e2ecust")); // idempotent
    // vendor probe (dry + real)
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "probe ve https://zalo.me/x --dry-run"));
    // official OA tier
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --tier oa"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --tier oa --code GOODCODE"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --tier oa --status"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "sync --cust e2ecust --tier oa"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "sync --cust e2ecust --tier articles"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "sync --cust e2ecust --tier mini --file te-mini-export.csv"));
    const total = try st.countRows("e2ecust");
    try std.testing.expect(total > 10);
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "sync --cust e2ecust --tier oa"));
    try std.testing.expectEqual(total, try st.countRows("e2ecust")); // resync adds nothing
    // delivery + pull + state
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "rows --cust e2ecust --push"));
    try std.testing.expect(hk.n.load(.acquire) >= 1);
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "rows --cust e2ecust --since 0 --limit 5"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "state --cust e2ecust"));
    // dead OA token reads dead (exit 3), never silent
    o.expireNow();
    o.refresh_dead = true;
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "sync --cust e2ecust --tier oa"));
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "login --cust e2ecust --tier oa --status"));
    // offboard: dump, dry-run purge, real purge
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "dump --cust e2ecust"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "purge --cust e2ecust"));
    try std.testing.expect(util.exists(cx.io, try st.path(a, "e2ecust", "rows.jsonl"))); // dry run removed nothing
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "purge --cust e2ecust --yes"));
    try std.testing.expect(!util.exists(cx.io, try st.path(a, "e2ecust", "")));
    // unknown command / bad usage
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "frobnicate"));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "scan"));
}
