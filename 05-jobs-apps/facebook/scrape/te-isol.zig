// isol: cust A can never read or write cust B's rows, files, cache, tokens, budgets, logs, Pages or deliveries. Blocks every release (`zig build test`).
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const scan = @import("cm-scan.zig");
const sync = @import("cm-sync.zig");
const rows_cmd = @import("cm-rows.zig");
const deliv = @import("rw-deliv.zig");
const sche = @import("rw-sche.zig");
const oauth = @import("pv-oauth.zig");
const vault_mod = @import("pv-vault.zig");
const hook = @import("pv-hook.zig");
const ms = @import("te-mini-srv.zig");
const mv = @import("te-mock-vendor.zig");
const mg = @import("te-mock-graph.zig");

const Hook = struct {
    bodies: [4][8192]u8 = undefined,
    lens: [4]usize = .{ 0, 0, 0, 0 },
    n: usize = 0,
};

fn hookH(ctx: *anyopaque, _: std.mem.Allocator, req: ms.Request) ms.Reply {
    const h: *Hook = @ptrCast(@alignCast(ctx));
    if (h.n < 4) {
        const l = @min(req.body.len, 8192);
        @memcpy(h.bodies[h.n][0..l], req.body[0..l]);
        h.lens[h.n] = l;
        h.n += 1;
    }
    return .{};
}

fn contains(a: std.mem.Allocator, io: std.Io, path: []const u8, needle: []const u8) bool {
    const t = util.readAll(a, io, path, 16 * 1024 * 1024) catch return false;
    return std.mem.indexOf(u8, t, needle) != null;
}

test "isol: two custs through the whole stack never touch" {
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
    try env.put("ISOL_HOOK", "whsec_isol");
    try env.put("ISOL_VKEY", mv.key);
    try env.put("FACE_APP_ID", "APPID1");
    try env.put("FACE_APP_SECRET", mg.secret);
    try env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.cfg = mg.shipped(a);
    cx.mock = true;
    cx.fake_gap = true;
    cx.fake_now_ms = 1_780_000_000_000;
    cx.cfg.market.daily_cap = 3;
    cx.cfg.deliv.secret_env = "ISOL_HOOK";
    cx.cfg.deliv.retries = 0;
    cx.cfg.vendor.order = &.{"ve"};
    cx.cfg.graph.redirect_uri = "https://app.example/cb";
    cx.cfg.hook.status_url = "https://app.example/deletion";
    var st = store_mod.Store.init(cx.io, gpa, home);
    var v = mv.Vend{ .page = "{\"id\":\"100\",\"name\":\"Shared Shop\",\"followers_count\":5}" };
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    var gm = mg.Mock{};
    const gsrv = try gm.start(cx.io);
    defer gsrv.stop();
    var gb: [64]u8 = undefined;
    cx.cfg.graph.base = gsrv.url(&gb, "");
    var hk = Hook{};
    const hsrv = try ms.Srv.start(cx.io, hookH, &hk);
    defer hsrv.stop();
    const defs = [_]shape.VendorDef{.{ .id = "ve", .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{vsrv.port}), .auth = .query, .auth_name = "apikey", .key_env = "ISOL_VKEY", .credit_header = "x-cost", .budget = 100 }};
    cx.vendor_reg = .{ .defs = &defs };
    const hook_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/h", .{hsrv.port});
    const t1 = shape.Target{ .kind = "page", .url = "https://www.facebook.com/shared" };
    const t2 = shape.Target{ .kind = "page", .url = "https://www.facebook.com/alphaonly" };
    try st.putCust(a, .{ .cust_id = "alpha", .consent = true, .webhook_url = hook_url, .targets = &.{ t1, t2, t1, t1 } });
    try st.putCust(a, .{ .cust_id = "beta", .consent = true, .webhook_url = hook_url, .targets = &.{t1} });

    // alpha connects the Page; beta cannot claim it
    _ = try oauth.connect(&cx, &st, a, "alpha", mg.code);
    try std.testing.expectError(oauth.Err.PageTaken, oauth.connect(&cx, &st, a, "beta", mg.code));
    const vl = try vault_mod.Vault.open(&cx);
    try std.testing.expect((try vl.get(a, "beta", "page.P1")) == null);
    try std.testing.expect(!util.exists(cx.io, try std.fmt.allocPrint(a, "{s}/cust/beta/secrets.enc", .{home})) or (try vl.get(a, "beta", "page.P1")) == null);
    const cb = try st.getCust(a, "beta");
    try std.testing.expectEqual(@as(usize, 0), cb.pages.len);

    // market lane: both scan the shared page; alpha burns its whole daily cap; beta's cap is its own
    const ra = try scan.scanCust(&cx, &st, "alpha", &.{}, false);
    try std.testing.expectEqual(@as(u32, 3), ra.fetched);
    try std.testing.expect(ra.over_cap > 0);
    const rb = try scan.scanCust(&cx, &st, "beta", &.{}, false);
    try std.testing.expectEqual(@as(u32, 1), rb.added); // not a "dup" of alpha's row
    try std.testing.expectEqual(@as(u32, 0), rb.over_cap);

    // own lane: only alpha has private rows
    const sa = try sync.syncCust(&cx, &st, "alpha", "", "");
    try std.testing.expectEqual(@as(u8, 0), sa.code());
    try std.testing.expect(sa.added >= 10);
    const sb = try sync.syncCust(&cx, &st, "beta", "", "");
    try std.testing.expectEqual(@as(u32, 0), sb.pages);
    try std.testing.expectEqual(@as(u32, 0), sb.added);

    // rows: each file holds only its own cust, and none of alpha's private chat reaches beta
    const rows_a = try std.fmt.allocPrint(a, "{s}/cust/alpha/rows.jsonl", .{home});
    const rows_b = try std.fmt.allocPrint(a, "{s}/cust/beta/rows.jsonl", .{home});
    try std.testing.expect(contains(a, cx.io, rows_a, "xin chao"));
    try std.testing.expect(!contains(a, cx.io, rows_a, "\"cust_id\":\"beta\""));
    try std.testing.expect(!contains(a, cx.io, rows_b, "\"cust_id\":\"alpha\""));
    for ([_][]const u8{ "xin chao", "PAGETOK1", "U100", "a@example.com", "P1" }) |secret| try std.testing.expect(!contains(a, cx.io, rows_b, secret));
    // budgets and logs are separate
    try std.testing.expect((try st.fetchesToday("alpha", cx.nowMs())) > (try st.fetchesToday("beta", cx.nowMs())));
    const aud_b = try std.fmt.allocPrint(a, "{s}/cust/beta/audit.jsonl", .{home});
    try std.testing.expect(!contains(a, cx.io, aud_b, "alphaonly"));
    try std.testing.expect(!contains(a, cx.io, aud_b, "alpha"));
    // the store refuses a cross-cust write
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"t\":1}", .{});
    const foreign = try shape.makeRow(a, "alpha", .public, "k", "page", 1, d);
    try std.testing.expectError(error.CustMismatch, st.upsert("beta", &.{foreign}));
    // ids that could escape a folder are refused everywhere
    for ([_][]const u8{ "../alpha", "alpha/../beta", "a/b", "", "ALPHA", "alpha\x00" }) |bad| {
        try std.testing.expectError(error.BadCustId, st.upsert(bad, &.{}));
        try std.testing.expect(!ctx_mod.validId(bad));
    }
    // delivery: beta's batch carries no alpha row
    const sum = try deliv.push(&cx, &st, "beta");
    try std.testing.expect(sum.outcome == .delivered);
    try std.testing.expectEqual(@as(usize, 1), hk.n);
    const body = hk.bodies[0][0..hk.lens[0]];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cust_id\":\"beta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "xin chao") == null);
    try std.testing.expectEqual(@as(usize, 0), deliv.cursorOf(&st, a, "alpha")); // cursors are separate
    // webhook events reach only the cust that owns the Page
    const ev = "{\"object\":\"page\",\"entry\":[{\"id\":\"P1\",\"time\":1}]}";
    const sig = try std.fmt.allocPrint(a, "sha256={s}", .{hook.macHex(mg.secret, ev)});
    const eh = try hook.handleEvent(&cx, &st, a, ev, sig);
    try std.testing.expectEqual(@as(u32, 1), eh.stored);
    try std.testing.expect(!contains(a, cx.io, rows_b, "\"kind\":\"event\""));
    try std.testing.expect(contains(a, cx.io, rows_a, "\"kind\":\"event\""));
    // pause: alpha paused, beta runs
    try st.appendLog("alpha", "PAUSED", "x");
    try std.testing.expect(sche.check(&cx, &st, "alpha") == .paused);
    try std.testing.expect(sche.check(&cx, &st, "beta") == .go);
    // pull api: beta cursor 0 never shows alpha rows
    const pg = try st.rowsSince(a, "beta", 0, 100);
    for (pg.rows) |r| try std.testing.expectEqualStrings("beta", r.cust_id);
    // nothing but cust/ and ops-level files at the home root
    var dir = try std.Io.Dir.cwd().openDir(cx.io, home, .{ .iterate = true });
    defer dir.close(cx.io);
    var it = dir.iterate();
    while (try it.next(cx.io)) |e| {
        const ok = std.mem.eql(u8, e.name, "cust") or std.mem.eql(u8, e.name, "vendors") or std.mem.eql(u8, e.name, "metrics.log") or std.mem.eql(u8, e.name, "pages.json");
        try std.testing.expect(ok);
    }
}

test "isol: deleting one Facebook user touches only that user's rows, in every cust" {
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
    try env.put("FACE_APP_SECRET", "S3CRET");
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.cfg.hook.user_keys = &.{ "user_id", "from_id" };
    var st = store_mod.Store.init(cx.io, gpa, home);
    const mine = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"from\":{\"id\":\"U1\"}}", .{});
    const other = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"from\":{\"id\":\"U2\"}}", .{});
    _ = try st.upsert("alpha", &.{ try shape.makeRow(a, "alpha", .private, "m1", "chat", 1, mine), try shape.makeRow(a, "alpha", .private, "m2", "chat", 1, other) });
    _ = try st.upsert("beta", &.{ try shape.makeRow(a, "beta", .private, "m3", "chat", 1, mine), try shape.makeRow(a, "beta", .private, "m4", "chat", 1, other) });
    const legal = @import("pv-legal.zig");
    try std.testing.expectEqual(@as(u32, 2), try legal.purgeUser(&cx, &st, a, "U1"));
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("alpha"));
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("beta"));
}

test "isol: the CLI refuses a cust id that escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(arena.allocator(), &env, ".zig-cache/tmp/none");
    try std.testing.expectEqual(@as(u8, 2), scan.run(&cx, &.{ "--cust", "../x" }, false));
    try std.testing.expectEqual(@as(u8, 2), sync.run(&cx, &.{ "--cust", "../x" }, false));
    try std.testing.expectEqual(@as(u8, 2), rows_cmd.run(&cx, &.{ "--cust", "../x" }, false));
}
