// Watch: one metrics line per run, usage-spike alert, optional health ping (URL comes from an env var; it holds a secret id).
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");
const guard = @import("pu-guard.zig");
const net = @import("pu-net.zig");

pub const Metric = struct { ts: i64, cust: []const u8, job: []const u8, code: u8, fetched: u32, added: u32, blocked: u32, failed: u32, credits: u32, ms: i64 };

pub fn record(cx: *const ctx_mod.Ctx, m: Metric) void {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const line = util.jsonStr(a, m) catch return;
    util.mkdirp(cx.io, cx.home) catch return;
    util.appendLine(cx.io, std.fmt.allocPrint(a, "{s}/metrics.log", .{cx.home}) catch return, line) catch {};
}

// spike: today's fetches vs the average of earlier days that have data. Alert needs >= spike_min and > spike_pct% of the average.
pub fn spike(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, cust: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const txt = util.readAll(a, cx.io, try st.path(a, cust, "fetches.jsonl"), 64 * 1024 * 1024) catch return false;
    const today = @divFloor(cx.nowMs(), store_mod.day_ms);
    var today_n: u64 = 0;
    var prev_total: u64 = 0;
    var days = std.AutoHashMapUnmanaged(i64, void).empty;
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |ln| {
        var f = std.mem.tokenizeScalar(u8, ln, ' ');
        const ts = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
        const n = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const d = @divFloor(ts, store_mod.day_ms);
        if (d == today) {
            today_n += n;
        } else if (d < today) {
            prev_total += n;
            try days.put(a, d, {});
        }
    }
    if (days.count() == 0 or today_n < cx.cfg.watch.spike_min) return false;
    const avg = prev_total / days.count();
    return today_n * 100 > avg * cx.cfg.sche.spike_pct;
}

pub fn alert(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, cust: []const u8, what: []const u8) void {
    st.audit(cust, cx.nowMs(), "alert", what, 0, "alert");
    util.eprint(cx.io, "ALERT cust={s}: {s}\n", .{ cust, what });
}

// GET the ping url (ok) or url/fail. Silent if unset; never blocks a run on failure.
pub fn ping(cx: *const ctx_mod.Ctx, ok: bool) void {
    const base = cx.envGet(cx.cfg.watch.ping_env) orelse return;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const url = if (ok) base else std.fmt.allocPrint(a, "{s}/fail", .{std.mem.trimEnd(u8, base, "/")}) catch return;
    const t = guard.parseUrl(a, url, .{ .allow_hosts = &.{}, .mock = cx.mock, .any_host = true }) catch return;
    const ip = guard.pin(cx.io, cx.resolver, t) catch return;
    _ = net.get(cx.io, a, t, ip, .{ .ua = cx.cfg.public.user_agent, .timeout_s = 5, .cap_bytes = 4096 }) catch {};
}

test "spike alert: only with history, enough volume, and a big jump" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(arena.allocator(), &env, home);
    cx.fake_now_ms = 10 * store_mod.day_ms + 5000;
    cx.cfg.sche.spike_pct = 300;
    cx.cfg.watch.spike_min = 20;
    const st = store_mod.Store.init(cx.io, cx.gpa, home);
    try std.testing.expect(!(try spike(&cx, &st, "demo")));
    try st.bumpFetches("demo", 10 * store_mod.day_ms + 1, 100);
    try std.testing.expect(!(try spike(&cx, &st, "demo"))); // no history yet
    try st.bumpFetches("demo", 8 * store_mod.day_ms, 10);
    try st.bumpFetches("demo", 9 * store_mod.day_ms, 10);
    try std.testing.expect(try spike(&cx, &st, "demo")); // 100 vs avg 10
    cx.cfg.watch.spike_min = 500;
    try std.testing.expect(!(try spike(&cx, &st, "demo")));
}

const ms = @import("te-mini-srv.zig");
fn pingH(ctx: *anyopaque, _: std.mem.Allocator, req: ms.Request) ms.Reply {
    const n: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
    _ = n.fetchAdd(1, .acq_rel);
    return .{ .body = if (std.mem.endsWith(u8, req.path, "/fail")) "fail" else "ok" };
}
test "ping: ok and fail variants reach the url; unset = silent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(a, &env, "unused");
    cx.mock = true;
    cx.cfg.public.user_agent = "t/1";
    ping(&cx, true); // unset: no crash
    var n = std.atomic.Value(u32).init(0);
    const srv = try ms.Srv.start(std.testing.io, pingH, &n);
    defer srv.stop();
    try env.put("SCRAPE_PING_URL", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/uuid", .{srv.port}));
    ping(&cx, true);
    ping(&cx, false);
    try std.testing.expectEqual(@as(u32, 2), n.load(.acquire));
}
