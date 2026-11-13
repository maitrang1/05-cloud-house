// isol: cust A can never read or write cust B's rows, files, cache, budgets, logs or deliveries. Blocks every release (`zig build test`).
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const scan = @import("cm-scan.zig");
const rows_cmd = @import("cm-rows.zig");
const deliv = @import("rw-deliv.zig");
const sche = @import("rw-sche.zig");
const site = @import("te-mock-site.zig");
const ms = @import("te-mini-srv.zig");

const Hook = struct {
    bodies: [4][4096]u8 = undefined,
    lens: [4]usize = .{ 0, 0, 0, 0 },
    n: usize = 0,
};

fn hookH(ctx: *anyopaque, _: std.mem.Allocator, req: ms.Request) ms.Reply {
    const h: *Hook = @ptrCast(@alignCast(ctx));
    if (h.n < 4) {
        const l = @min(req.body.len, 4096);
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
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.fake_gap = true;
    cx.cfg.public = .{ .user_agent = "t/1", .allow_hosts = &.{}, .gap_ms = 1, .jitter_ms = 0, .timeout_s = 3, .body_cap_kb = 64, .daily_cap = 3, .robots_ttl_s = 60, .robots_cap_kb = 4 };
    cx.cfg.deliv.secret_env = "ISOL_HOOK";
    cx.cfg.deliv.retries = 0;
    var st = store_mod.Store.init(cx.io, gpa, home);
    var s = site.Site.init(gpa);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var hk = Hook{};
    const hsrv = try ms.Srv.start(cx.io, hookH, &hk);
    defer hsrv.stop();
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const url_shared = try a.dupe(u8, srv.url(&b1, "/oa/ok"));
    const url_alpha_only = try a.dupe(u8, srv.url(&b2, "/oa/other"));
    try st.putCust(a, .{ .cust_id = "alpha", .webhook_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/h", .{hsrv.port}) });
    try st.putCust(a, .{ .cust_id = "beta", .webhook_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/h", .{hsrv.port}) });

    // both scan the shared page; only alpha scans the private one; alpha burns its whole daily cap
    const ra = try scan.scanCust(&cx, &st, "alpha", &.{ url_shared, url_alpha_only, url_shared, url_shared }, false);
    try std.testing.expectEqual(@as(u32, 2), ra.added);
    try std.testing.expect(ra.over_cap > 0 or ra.dup > 0);
    const rb = try scan.scanCust(&cx, &st, "beta", &.{url_shared}, false);
    try std.testing.expectEqual(@as(u32, 1), rb.added); // not a "dup" of alpha's row
    try std.testing.expectEqual(@as(u32, 0), rb.over_cap); // alpha's spent cap is not beta's

    // rows: each file holds only its own cust
    const rows_a = try std.fmt.allocPrint(a, "{s}/cust/alpha/rows.jsonl", .{home});
    const rows_b = try std.fmt.allocPrint(a, "{s}/cust/beta/rows.jsonl", .{home});
    try std.testing.expect(!contains(a, cx.io, rows_a, "\"cust_id\":\"beta\""));
    try std.testing.expect(!contains(a, cx.io, rows_b, "\"cust_id\":\"alpha\""));
    try std.testing.expect(!contains(a, cx.io, rows_b, "Other Shop")); // alpha-only content
    // files: beta has no copy of alpha's private page
    const h_other = util.sha256Hex("<html><head><title>Other</title><meta property=\"og:title\" content=\"Other Shop\"/></head><body><h1>Other</h1></body></html>");
    try std.testing.expect(util.exists(cx.io, try std.fmt.allocPrint(a, "{s}/cust/alpha/files/{s}.html", .{ home, h_other })));
    try std.testing.expect(!util.exists(cx.io, try std.fmt.allocPrint(a, "{s}/cust/beta/files/{s}.html", .{ home, h_other })));
    // budgets
    try std.testing.expect((try st.fetchesToday("alpha", cx.nowMs())) >= 2);
    try std.testing.expectEqual(@as(u32, 1), try st.fetchesToday("beta", cx.nowMs()));
    // logs: alpha-only url never in beta's audit/usage
    const aud_b = try std.fmt.allocPrint(a, "{s}/cust/beta/audit.jsonl", .{home});
    try std.testing.expect(!contains(a, cx.io, aud_b, "/oa/other"));
    try std.testing.expect(!contains(a, cx.io, aud_b, "alpha"));
    // the store refuses a cross-cust write
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"t\":1}", .{});
    const foreign = try shape.makeRow(a, "alpha", .public, "k", "oa_page", 1, d);
    try std.testing.expectError(error.CustMismatch, st.upsert("beta", &.{foreign}));
    // ids that could escape a folder are refused everywhere
    for ([_][]const u8{ "../alpha", "alpha/../beta", "a/b", "", "ALPHA", "alpha\x00" }) |bad| {
        try std.testing.expectError(error.BadCustId, st.upsert(bad, &.{}));
        try std.testing.expect(!ctx_mod.validId(bad));
    }
    // delivery: beta's batch carries no alpha row
    const sum = try deliv.push(&cx, &st, "beta");
    try std.testing.expect(sum.outcome == .delivered);
    try std.testing.expect(hk.n == 1);
    try std.testing.expect(std.mem.indexOf(u8, hk.bodies[0][0..hk.lens[0]], "\"cust_id\":\"beta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hk.bodies[0][0..hk.lens[0]], "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, hk.bodies[0][0..hk.lens[0]], "Other Shop") == null);
    // delivery cursors are separate
    try std.testing.expectEqual(@as(usize, 0), deliv.cursorOf(&st, a, "alpha"));
    // pause: alpha paused, beta runs
    try st.appendLog("alpha", "PAUSED", "x");
    try std.testing.expect(sche.check(&cx, &st, "alpha") == .paused);
    try std.testing.expect(sche.check(&cx, &st, "beta") == .go);
    // pull api: beta cursor 0 never shows alpha rows
    const pg = try st.rowsSince(a, "beta", 0, 100);
    for (pg.rows) |r| try std.testing.expectEqualStrings("beta", r.cust_id);
    // nothing but cust/ and ops-level vendors|metrics at the home root
    var dir = try std.Io.Dir.cwd().openDir(cx.io, home, .{ .iterate = true });
    defer dir.close(cx.io);
    var it = dir.iterate();
    while (try it.next(cx.io)) |e| {
        const ok = std.mem.eql(u8, e.name, "cust") or std.mem.eql(u8, e.name, "vendors") or std.mem.eql(u8, e.name, "metrics.log");
        try std.testing.expect(ok);
    }
}

test "isol: the CLI refuses a cust id that escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(arena.allocator(), &env, ".zig-cache/tmp/none");
    try std.testing.expectEqual(@as(u8, 2), scan.run(&cx, &.{ "--cust", "../x" }, false));
    try std.testing.expectEqual(@as(u8, 2), rows_cmd.run(&cx, &.{ "--cust", "../x" }, false));
}
