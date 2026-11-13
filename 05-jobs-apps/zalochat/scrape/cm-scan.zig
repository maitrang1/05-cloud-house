// scan: public path. For one cust: fetch urls politely -> parse -> rows (deduped) -> raw file -> audit. --dry-run = guard + robots only, writes nothing.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const fetch = @import("pu-fetch.zig");
const parse = @import("pu-parse.zig");
const guard = @import("pu-guard.zig");
const route = @import("ve-route.zig");
const regis = @import("ve-regis.zig");
const meter = @import("rw-meter.zig");
const sche = @import("rw-sche.zig");
const watch = @import("rw-watch.zig");

pub const Result = struct {
    fetched: u32 = 0,
    via_vendor: u32 = 0,
    credits: u32 = 0,
    added: u32 = 0,
    dup: u32 = 0,
    not_found: u32 = 0,
    robots_denied: u32 = 0,
    blocked: u32 = 0,
    failed: u32 = 0,
    refused: u32 = 0,
    over_cap: u32 = 0,
    dry_run: bool = false,

    pub fn code(self: Result) u8 {
        if (self.blocked > 0) return 3;
        if (self.failed > 0) return 1;
        if (self.refused > 0) return 2; // a url the guard refuses is a config/usage problem
        return 0;
    }
};

const AuditCtx = struct { st: *const store_mod.Store, cust: []const u8, now: i64 };
fn auditCb(p: ?*anyopaque, url: []const u8, status: i64, note: []const u8) void {
    const c: *AuditCtx = @ptrCast(@alignCast(p.?));
    c.st.audit(c.cust, c.now, "scan", url, status, note);
}

pub fn scanCust(cx: *ctx_mod.Ctx, st: *store_mod.Store, cust_id: []const u8, urls_in: []const []const u8, dry: bool) !Result {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cust = try st.getCust(a, cust_id);
    const urls = if (urls_in.len > 0) urls_in else cust.urls;
    const cap = if (cust.daily_cap > 0) cust.daily_cap else cx.cfg.public.daily_cap;
    const now = cx.nowMs();
    const used = try st.fetchesToday(cust_id, now);
    const left = cap -| used;
    var res = Result{ .dry_run = dry };
    var ac = AuditCtx{ .st = st, .cust = cust_id, .now = now };
    var sess = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = cx.mock, .resolver = cx.resolver, .max_pages = left });
    sess.fake_gap = cx.fake_gap;
    sess.audit = auditCb;
    sess.audit_ctx = &ac;
    // vendor registry: injected (tests) or the config file; a bad file only disables the fallback
    var reg: ?regis.Registry = cx.vendor_reg;
    if (reg == null and cust.vendors_allowed and cx.cfg.vendor.order.len > 0) {
        const rp = try cx.rel(a, cx.cfg.vendor.file);
        reg = regis.load(a, cx.io, rp, cx.mock) catch null;
        if (reg == null) st.audit(cust_id, now, "scan", "vendors", 0, "registry_unreadable");
    }
    var rt = route.Router.init(cx, st, a, cust_id, &sess, reg, cust.vendors_allowed);
    var batch: std.ArrayList(shape.Row) = .empty;
    for (urls) |u| {
        if (dry) {
            // verdict only: url guard
            const red = guard.redactUrl(a, u) catch u;
            if (guard.parseUrl(a, u, .{ .allow_hosts = cx.cfg.public.allow_hosts, .mock = cx.mock })) |_| {
                util.print(cx.io, "  ok       {s}\n", .{red});
            } else |e| {
                res.refused += 1;
                util.print(cx.io, "  REFUSED  {s}  ({s})\n", .{ red, @errorName(e) });
            }
            continue;
        }
        const o = rt.get(u);
        switch (o) {
            .ok => |pg| {
                res.fetched += 1;
                if (rt.last_via == .vendor) res.via_vendor += 1;
                const m = try parse.parse(a, u, pg.body, .{ .text_cap = cx.cfg.public.text_cap, .field_cap = cx.cfg.public.field_cap });
                const row = try parse.toRow(a, cust_id, m, pg.fetched_ms);
                try batch.append(a, row);
                const h = util.sha256Hex(pg.body);
                const fname = try std.fmt.allocPrint(a, "{s}.html", .{h});
                try st.putFile(cust_id, fname, pg.body);
            },
            .not_found => res.not_found += 1,
            .robots_denied => res.robots_denied += 1,
            .blocked => res.blocked += 1,
            .stopped => res.blocked += 1,
            .guard_refused => res.refused += 1,
            .cap_reached => res.over_cap += 1,
            else => res.failed += 1,
        }
    }
    if (!dry) {
        if (sess.pages + rt.vendor_pages > 0) try st.bumpFetches(cust_id, now, sess.pages + rt.vendor_pages);
        if (batch.items.len > 0) {
            const s = try st.upsert(cust_id, batch.items);
            res.added = s.added;
            res.dup = s.dup;
        }
    }
    res.credits = rt.vendor_credits;
    // usage: one entry per OK run; a failed or blocked run costs the cust nothing
    if (!dry and res.code() == 0 and (res.fetched > 0 or res.dup > 0)) meter.record(st, cust_id, now, "scan", sess.pages + rt.vendor_pages, rt.vendor_credits) catch {};
    return res;
}

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: scan works for one cust\nfix: scrape scan --cust ID [--url U] [--dry-run]\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ - (max 64)\nfix: use a safe id\n", .{});
        return 2;
    }
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    switch (sche.check(cx, &st, cust)) {
        .go => {},
        .killed => {
            util.eprint(cx.io, "error: kill switch is on\nwhy: config sche.kill_switch or the KILL file\nfix: turn it off to run\n", .{});
            return 3;
        },
        .paused => {
            util.eprint(cx.io, "error: cust {s} is paused\nwhy: repeated failed runs (see dlq-runs.jsonl)\nfix: fix the cause, then scrape state --cust {s} --resume\n", .{ cust, cust });
            return 3;
        },
    }
    const t0 = util.monoMs(cx.io);
    const urls = args.all(cx.gpa, av, "--url") catch return 1;
    defer cx.gpa.free(urls);
    const r = scanCust(cx, &st, cust, urls, args.has(av, "--dry-run")) catch |e| {
        util.eprint(cx.io, "error: scan failed ({s})\nwhy: cust file missing/invalid, or the store is locked by another run\nfix: check <home>/cust/{s}/cust.json\n", .{ @errorName(e), cust });
        return if (e == error.FileNotFound) 2 else 1;
    };
    if (!r.dry_run) {
        sche.finish(cx, &st, cust, "scan", r.code());
        watch.record(cx, .{ .ts = cx.nowMs(), .cust = cust, .job = "scan", .code = r.code(), .fetched = r.fetched, .added = r.added, .blocked = r.blocked, .failed = r.failed, .credits = r.credits, .ms = util.monoMs(cx.io) - t0 });
        if (watch.spike(cx, &st, cust) catch false) watch.alert(cx, &st, cust, "fetch volume spike");
        watch.ping(cx, r.code() == 0);
    }
    if (json) {
        const s = util.jsonStr(cx.gpa, r) catch return 1;
        defer cx.gpa.free(s);
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
    } else util.print(cx.io, "scan {s}{s}: fetched {d} · added {d} · dup {d} · 404 {d} · robots {d} · blocked {d} · failed {d} · refused {d} · over cap {d}\n", .{ cust, if (r.dry_run) " (dry-run)" else "", r.fetched, r.added, r.dup, r.not_found, r.robots_denied, r.blocked, r.failed, r.refused, r.over_cap });
    return r.code();
}

// ---- tests (mock site) ----
const site = @import("te-mock-site.zig");

fn testCx(arena: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8) ctx_mod.Ctx {
    var cx = ctx_mod.testCtx(arena, env, home);
    cx.mock = true;
    cx.cfg.public = .{ .user_agent = "zalochat-scrape/0.1 (test)", .allow_hosts = &.{}, .gap_ms = 1, .jitter_ms = 0, .timeout_s = 3, .body_cap_kb = 64, .daily_cap = 5, .robots_ttl_s = 60, .robots_cap_kb = 4 };
    return cx;
}

test "scan: twice = one row; raw file saved; audit has no secrets; cap holds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = testCx(arena.allocator(), &env, home);
    var st = store_mod.Store.init(cx.io, cx.gpa, home);
    var s = site.Site.init(std.testing.allocator);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var ub: [128]u8 = undefined;
    const u_ok = try arena.allocator().dupe(u8, srv.url(&ub, "/oa/ok"));
    try st.putCust(arena.allocator(), .{ .cust_id = "demo" });
    const r1 = try scanCust(&cx, &st, "demo", &.{u_ok}, false);
    try std.testing.expectEqual(@as(u32, 1), r1.added);
    const r2 = try scanCust(&cx, &st, "demo", &.{u_ok}, false);
    try std.testing.expectEqual(@as(u32, 0), r2.added);
    try std.testing.expectEqual(@as(u32, 1), r2.dup);
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("demo"));
    // raw file exists
    var fb: [200]u8 = undefined;
    const h = util.sha256Hex(@import("te-mock-site.zig").ok_html);
    const fp = try std.fmt.bufPrint(&fb, "{s}/cust/demo/files/{s}.html", .{ home, h });
    try std.testing.expect(util.exists(cx.io, fp));
    // cap 5 pages/day: 2 used so far (robots not counted as page) -> only 3 more
    const many = [_][]const u8{ u_ok, u_ok, u_ok, u_ok, u_ok };
    const r3 = try scanCust(&cx, &st, "demo", &many, false);
    try std.testing.expect(r3.over_cap >= 2);
    // dry-run writes nothing
    const before = try st.fetchesToday("demo", cx.nowMs());
    const rd = try scanCust(&cx, &st, "demo", &.{u_ok}, true);
    try std.testing.expect(rd.dry_run);
    try std.testing.expectEqual(before, try st.fetchesToday("demo", cx.nowMs()));
    // robots disallowed path: counted, not fetched
    const u_priv = try arena.allocator().dupe(u8, srv.url(&ub, "/private/x"));
    cx.cfg.public.daily_cap = 50;
    const rp = try scanCust(&cx, &st, "demo", &.{u_priv}, false);
    try std.testing.expectEqual(@as(u32, 1), rp.robots_denied);
    try std.testing.expectEqual(@as(u32, 0), s.hitsOf("/private/x"));
}

test "scan: block exits 3 and stops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = testCx(arena.allocator(), &env, home);
    var st = store_mod.Store.init(cx.io, cx.gpa, home);
    var s = site.Site.init(std.testing.allocator);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const url_429 = try arena.allocator().dupe(u8, srv.url(&b1, "/oa/429"));
    const url_ok = try arena.allocator().dupe(u8, srv.url(&b2, "/oa/ok"));
    try st.putCust(arena.allocator(), .{ .cust_id = "demo" });
    const r = try scanCust(&cx, &st, "demo", &.{ url_429, url_ok }, false);
    try std.testing.expectEqual(@as(u8, 3), r.code());
    try std.testing.expectEqual(@as(u32, 0), s.hitsOf("/oa/ok"));
    try std.testing.expectEqual(@as(usize, 0), try st.countRows("demo"));
}

test "scan: 403 origin + vendor -> row stored via vendor, same hash as own fetch" {
    const mv = @import("te-mock-vendor.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MK_S", mv.key);
    var cx = testCx(a, &env, home);
    cx.cfg.vendor.order = &.{"vs"};
    var st = store_mod.Store.init(cx.io, cx.gpa, home);
    var s = site.Site.init(std.testing.allocator);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var v = mv.Vend{};
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    const defs = [_]shape.VendorDef{.{ .id = "vs", .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{vsrv.port}), .auth = .query, .auth_name = "apikey", .key_env = "MK_S" }};
    cx.vendor_reg = .{ .defs = &defs };
    try st.putCust(a, .{ .cust_id = "demo" });
    var b1: [128]u8 = undefined;
    const url_403 = try a.dupe(u8, srv.url(&b1, "/oa/403"));
    const r = try scanCust(&cx, &st, "demo", &.{url_403}, false);
    try std.testing.expectEqual(@as(u32, 1), r.added);
    try std.testing.expectEqual(@as(u32, 1), r.via_vendor);
    const r2 = try scanCust(&cx, &st, "demo", &.{url_403}, false);
    try std.testing.expectEqual(@as(u32, 0), r2.added); // idempotent through vendors too
    // per-cust vendor ledger has our line, no key anywhere in the cust folder logs
    const led = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/demo/vendor_use.jsonl", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, led, "\"vendor\":\"vs\"") != null);
    const au = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/demo/audit.jsonl", .{home}), 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, au, mv.key) == null);
}

test "run guard: 3 failing runs pause the cust (DLQ); kill switch makes no calls; resume works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = testCx(a, &env, home);
    cx.fake_gap = true;
    cx.cfg.sche.max_fails = 3;
    cx.cfg.public.retry_5xx = 0;
    var st = store_mod.Store.init(cx.io, cx.gpa, home);
    var s = site.Site.init(std.testing.allocator);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var b: [128]u8 = undefined;
    const url_500 = try a.dupe(u8, srv.url(&b, "/oa/500"));
    try st.putCust(a, .{ .cust_id = "demo" });
    const av = [_][]const u8{ "--cust", "demo", "--url", url_500 };
    try std.testing.expectEqual(@as(u8, 1), run(&cx, &av, true));
    try std.testing.expectEqual(@as(u8, 1), run(&cx, &av, true));
    try std.testing.expectEqual(@as(u8, 1), run(&cx, &av, true));
    const hits = s.hitsOf("/oa/500");
    try std.testing.expectEqual(@as(u8, 3), run(&cx, &av, true)); // paused: refused
    try std.testing.expectEqual(hits, s.hitsOf("/oa/500"));
    try std.testing.expect(util.exists(cx.io, try std.fmt.allocPrint(a, "{s}/cust/demo/dlq-runs.jsonl", .{home})));
    try std.testing.expect(util.exists(cx.io, try std.fmt.allocPrint(a, "{s}/metrics.log", .{home})));
    try sche.resume_(&cx, &st, "demo");
    cx.cfg.sche.kill_switch = true;
    const total_before = s.total();
    try std.testing.expectEqual(@as(u8, 3), run(&cx, &av, true));
    try std.testing.expectEqual(total_before, s.total());
}
