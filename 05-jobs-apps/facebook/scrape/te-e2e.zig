// e2e on mocks: the whole CLI router, every outside service faked on loopback (vendor, Graph + OAuth, webhook receiver).
const std = @import("std");
const util = @import("co-util.zig");
const main = @import("main.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const hook = @import("pv-hook.zig");
const ms = @import("te-mini-srv.zig");
const mv = @import("te-mock-vendor.zig");
const mg = @import("te-mock-graph.zig");

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
    try env.put("FACE_APP_ID", "APPID1");
    try env.put("FACE_APP_SECRET", mg.secret);
    try env.put("FACE_HOOK_VERIFY", "vt1");
    try env.put("SCRAPE_HOOK_SECRET", "whsec_e2e");
    try env.put("E2E_VKEY", mv.key);
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.cfg = mg.shipped(a);
    cx.mock = true;
    cx.fake_gap = true;
    var v = mv.Vend{ .cost = 3, .page = "{\"id\":\"100\",\"name\":\"Quan A\",\"followers_count\":7}" };
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    var gm = mg.Mock{};
    const gsrv = try gm.start(cx.io);
    defer gsrv.stop();
    var hk = Hook{};
    const hsrv = try ms.Srv.start(cx.io, hookH, &hk);
    defer hsrv.stop();
    var gb: [64]u8 = undefined;
    cx.cfg.graph.base = gsrv.url(&gb, "");
    cx.cfg.graph.redirect_uri = "https://app.example/cb";
    cx.cfg.hook.status_url = "https://app.example/deletion";
    cx.cfg.vendor.order = &.{"ve"};
    const defs = [_]shape.VendorDef{.{ .id = "ve", .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{vsrv.port}), .auth = .query, .auth_name = "apikey", .key_env = "E2E_VKEY", .credit_header = "x-cost", .budget = 100 }};
    cx.vendor_reg = .{ .defs = &defs };
    var st = store_mod.Store.init(cx.io, gpa, home);
    try st.putCust(a, .{ .cust_id = "e2ecust", .webhook_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/hook", .{hsrv.port}) });

    // cust + market lane
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "cust --cust e2ecust --add-target page=https://www.facebook.com/example"));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "sync --cust e2ecust")); // no consent yet
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "consent --cust e2ecust --grant"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "scan --cust e2ecust --dry-run"));
    try std.testing.expectEqual(@as(u32, 0), v.hits.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "scan --cust e2ecust"));
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("e2ecust"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "scan --cust e2ecust"));
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("e2ecust")); // idempotent
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "probe ve https://www.facebook.com/x --dry-run"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "probe ve https://www.facebook.com/x"));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "probe ve https://evil.example.com/x"));

    // own lane: connect, sync, resync adds nothing
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust"));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "login --cust e2ecust --code WRONGCODE"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --code GOODCODE"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --status"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "sync --cust e2ecust"));
    const total = try st.countRows("e2ecust");
    try std.testing.expect(total >= 15);
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "sync --cust e2ecust"));
    try std.testing.expectEqual(total, try st.countRows("e2ecust")); // resync: zero duplicates
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "sync --cust e2ecust --only nonsense"));

    // webhook: handshake, signed event, forged event, deletion callback
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "hook verify --mode subscribe --token vt1 --challenge 99"));
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "hook verify --mode subscribe --token bad --challenge 99"));
    const ev = "{\"object\":\"page\",\"entry\":[{\"id\":\"P1\",\"time\":1}]}";
    const evp = try std.fmt.allocPrint(a, "{s}/ev.json", .{home});
    try util.writeAtomic(a, cx.io, evp, ev);
    cx.fake_now_ms = 0;
    const av_ok = [_][]const u8{ "hook", "event", "--file", evp, "--sig", try std.fmt.allocPrint(a, "sha256={s}", .{hook.macHex(mg.secret, ev)}) };
    try std.testing.expectEqual(@as(u8, 0), main.dispatch(&cx, &av_ok, false));
    const av_bad = [_][]const u8{ "hook", "event", "--file", evp, "--sig", "sha256=00" };
    try std.testing.expectEqual(@as(u8, 3), main.dispatch(&cx, &av_bad, false));
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "hook delete --signed-request AAAA.BBBB"));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "hook status --code 0000000000000000"));

    // delivery + pull + state
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "rows --cust e2ecust --push"));
    try std.testing.expect(hk.n.load(.acquire) >= 1);
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "rows --cust e2ecust --since 0 --limit 5"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "state --cust e2ecust"));

    // a dead Page token reads dead (exit 3) and stays dead until reconnect; never silent
    const vl = try @import("pv-vault.zig").Vault.open(&cx);
    try vl.put("e2ecust", "page.P1", "DEADTOK");
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "sync --cust e2ecust"));
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "login --cust e2ecust --status"));
    try std.testing.expectEqual(@as(u8, 3), run(&cx, "sync --cust e2ecust")); // dead Pages are skipped, still flagged
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --code GOODCODE")); // reconnect heals
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "login --cust e2ecust --status"));

    // offboard: dump, dry-run purge, real purge
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "dump --cust e2ecust"));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "purge --cust e2ecust"));
    try std.testing.expect(util.exists(cx.io, try st.path(a, "e2ecust", "rows.jsonl"))); // dry run removed nothing
    try std.testing.expectEqual(@as(u8, 0), run(&cx, "purge --cust e2ecust --yes"));
    try std.testing.expect(!util.exists(cx.io, try st.path(a, "e2ecust", "")));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "frobnicate"));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, "scan"));
}
