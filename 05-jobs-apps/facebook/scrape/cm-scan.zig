// scan: market lane. For one cust: each target (kind + public url) -> vendor (logged out) -> rows (deduped) -> raw reply in Content -> audit.
// --dry-run = guard verdicts only, nothing is sent and nothing is written. Never an own GET to Facebook, never a cookie.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const guard = @import("co-guard.zig");
const route = @import("ve-route.zig");
const regis = @import("ve-regis.zig");
const vparse = @import("ve-parse.zig");
const meter = @import("rw-meter.zig");
const sche = @import("rw-sche.zig");
const watch = @import("rw-watch.zig");

pub const Result = struct {
    fetched: u32 = 0,
    credits: u32 = 0,
    added: u32 = 0,
    dup: u32 = 0,
    skipped: u32 = 0,
    blocked: u32 = 0,
    failed: u32 = 0,
    refused: u32 = 0,
    no_vendor: u32 = 0,
    over_cap: u32 = 0,
    dry_run: bool = false,

    pub fn code(self: Result) u8 {
        if (self.blocked > 0) return 3;
        if (self.failed > 0) return 1;
        if (self.refused > 0 or self.no_vendor > 0) return 2; // a url the guard refuses or no usable vendor key is a config problem
        return 0;
    }
};

pub fn scanCust(cx: *ctx_mod.Ctx, st: *store_mod.Store, cust_id: []const u8, targets_in: []const shape.Target, dry: bool) !Result {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cust = try st.getCust(a, cust_id);
    if (cx.cfg.legal.consent_required and !cust.consent) return error.NoConsent;
    const targets = if (targets_in.len > 0) targets_in else cust.targets;
    const cap = if (cust.daily_cap > 0) cust.daily_cap else cx.cfg.market.daily_cap;
    const now = cx.nowMs();
    const left = cap -| (try st.fetchesToday(cust_id, now));
    var res = Result{ .dry_run = dry };
    var reg: ?regis.Registry = cx.vendor_reg;
    if (reg == null and cust.vendors_allowed and cx.cfg.vendor.order.len > 0) {
        const rp = try cx.rel(a, cx.cfg.vendor.file);
        reg = regis.load(a, cx.io, rp, cx.mock) catch null;
        if (reg == null) st.audit(cust_id, now, "scan", "vendors", 0, "registry_unreadable");
    }
    var rt = route.Router.init(cx, st, a, cust_id, reg, cust.vendors_allowed, left);
    var batch: std.ArrayList(shape.Row) = .empty;
    for (targets) |t| {
        if (dry) {
            const red = guard.redactUrl(a, t.url) catch t.url;
            if (guard.parseUrl(a, t.url, .{ .allow_hosts = cx.cfg.market.allow_hosts, .mock = cx.mock })) |_| {
                util.print(cx.io, "  ok       {s} {s}\n", .{ t.kind, red });
            } else |e| {
                res.refused += 1;
                util.print(cx.io, "  REFUSED  {s} {s}  ({s})\n", .{ t.kind, red, @errorName(e) });
            }
            continue;
        }
        switch (rt.get(t.kind, t.url)) {
            .ok => |g| {
                var one: std.ArrayList(shape.Row) = .empty;
                const ps = vparse.toRows(a, cx.cfg.market, cust_id, t.kind, t.url, g.body, now, &one) catch {
                    res.failed += 1; // reply shape drifted: the vendor row or the kind map needs a look
                    st.audit(cust_id, now, "scan", "parse", 0, "reply_shape_changed");
                    continue;
                };
                res.fetched += 1;
                res.skipped += ps.skipped;
                try batch.appendSlice(a, one.items);
                const fname = try std.fmt.allocPrint(a, "{s}.json", .{util.sha256Hex(g.body)});
                try st.putFile(cust_id, fname, g.body);
            },
            .blocked => res.blocked += 1,
            .guard_refused => res.refused += 1,
            .cap_reached => res.over_cap += 1,
            .no_vendor => res.no_vendor += 1,
            .failed => res.failed += 1,
        }
    }
    if (!dry) {
        if (rt.calls > 0) try st.bumpFetches(cust_id, now, rt.calls);
        if (batch.items.len > 0) {
            const s = try st.upsert(cust_id, batch.items);
            res.added = s.added;
            res.dup = s.dup;
        }
    }
    res.credits = rt.credits;
    // usage: one entry per OK run; a failed or blocked run costs the cust nothing
    if (!dry and res.code() == 0 and (res.fetched > 0)) meter.record(st, cust_id, now, "scan", rt.calls, rt.credits) catch {};
    return res;
}

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: scan works for one cust\nfix: scrape scan --cust ID [--kind K --url U] [--dry-run]\n", .{});
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
    var one: [1]shape.Target = undefined;
    var targets: []const shape.Target = &.{};
    if (args.value(av, "--url")) |u| {
        one[0] = .{ .kind = args.value(av, "--kind") orelse "page", .url = u };
        targets = one[0..1];
    }
    const r = scanCust(cx, &st, cust, targets, args.has(av, "--dry-run")) catch |e| {
        if (e == error.NoConsent) {
            util.eprint(cx.io, "error: no consent for {s}\nwhy: scraped comments are personal data\nfix: scrape consent --cust {s} --grant\n", .{ cust, cust });
            return 2;
        }
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
    } else util.print(cx.io, "scan {s}{s}: fetched {d} · added {d} · dup {d} · skipped {d} · blocked {d} · failed {d} · refused {d} · no vendor {d} · over cap {d} · credits {d}\n", .{ cust, if (r.dry_run) " (dry-run)" else "", r.fetched, r.added, r.dup, r.skipped, r.blocked, r.failed, r.refused, r.no_vendor, r.over_cap, r.credits });
    return r.code();
}

// ---- tests ----
const mv = @import("te-mock-vendor.zig");

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    hb: [128]u8 = undefined,
    cx: ctx_mod.Ctx = undefined,
    v: mv.Vend = .{},
    srv: *@import("te-mini-srv.zig").Srv = undefined,
    defs: [1]shape.VendorDef = undefined,

    fn up(self: *Rig, page: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.env = std.process.Environ.Map.init(std.testing.allocator);
        const a = self.arena.allocator();
        const home = try std.fmt.bufPrint(&self.hb, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
        try self.env.put("MK_A", mv.key);
        self.cx = ctx_mod.testCtx(a, &self.env, home);
        self.cx.mock = true;
        self.cx.fake_gap = true;
        var w: [160]u8 = undefined;
        var n: usize = 0;
        const c = @import("co-cfg.zig").load(a, std.testing.io, "00-config.json", &w, &n) catch unreachable;
        self.cx.cfg.market = c.market;
        self.cx.cfg.vendor.order = &.{"va"};
        self.v = .{ .page = page, .cost = 2 };
        self.srv = try self.v.start(self.cx.io);
        self.defs[0] = .{ .id = "va", .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{self.srv.port}), .auth = .query, .auth_name = "apikey", .key_env = "MK_A", .credit_header = "x-cost", .budget = 100 };
        self.cx.vendor_reg = .{ .defs = &self.defs };
    }
    fn down(self: *Rig) void {
        self.srv.stop();
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "scan: page + posts through a vendor; second run adds nothing; usage metered once" {
    var r: Rig = undefined;
    try r.up("{\"id\":\"100\",\"name\":\"Quan A\",\"followers_count\":10}");
    defer r.down();
    const a = r.arena.allocator();
    var st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    try st.putCust(a, .{ .cust_id = "demo", .consent = true, .targets = &.{.{ .kind = "page", .url = "https://www.facebook.com/example" }} });
    const r1 = try scanCust(&r.cx, &st, "demo", &.{}, false);
    try std.testing.expectEqual(@as(u32, 1), r1.fetched);
    try std.testing.expectEqual(@as(u32, 1), r1.added);
    try std.testing.expectEqual(@as(u32, 2), r1.credits);
    try std.testing.expectEqual(@as(u8, 0), r1.code());
    const r2 = try scanCust(&r.cx, &st, "demo", &.{}, false);
    try std.testing.expectEqual(@as(u32, 0), r2.added);
    try std.testing.expectEqual(@as(u32, 1), r2.dup);
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("demo"));
    const m = try meter.month(&st, "demo", r.cx.nowMs());
    try std.testing.expectEqual(@as(u32, 2), m.runs);
    // a changed follower count is a new version, not a duplicate
    r.v.page = "{\"id\":\"100\",\"name\":\"Quan A\",\"followers_count\":11}";
    const r3 = try scanCust(&r.cx, &st, "demo", &.{}, false);
    try std.testing.expectEqual(@as(u32, 1), r3.added);
    try std.testing.expectEqual(@as(usize, 2), try st.countRows("demo"));
}

test "scan: dry-run sends nothing; guard refusals exit 2; dead key exits no-vendor; challenge exits 3" {
    var r: Rig = undefined;
    try r.up("{\"id\":\"1\"}");
    defer r.down();
    const a = r.arena.allocator();
    var st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    try st.putCust(a, .{ .cust_id = "demo", .consent = true });
    const bad = [_]shape.Target{ .{ .kind = "page", .url = "https://www.facebook.com/ok" }, .{ .kind = "page", .url = "https://evil.example.com/x" } };
    const d = try scanCust(&r.cx, &st, "demo", &bad, true);
    try std.testing.expectEqual(@as(u32, 1), d.refused);
    try std.testing.expectEqual(@as(u32, 0), r.v.hits.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), try st.countRows("demo"));
    const g = try scanCust(&r.cx, &st, "demo", bad[1..], false);
    try std.testing.expectEqual(@as(u8, 2), g.code());
    r.v.setMode(.challenge);
    const c = try scanCust(&r.cx, &st, "demo", bad[0..1], false);
    try std.testing.expectEqual(@as(u8, 3), c.code());
    try std.testing.expectEqual(@as(usize, 0), try st.countRows("demo")); // nothing from a blocked run
    r.v.setMode(.ok);
    try r.env.put("MK_A", "");
    const nv = try scanCust(&r.cx, &st, "demo", bad[0..1], false);
    try std.testing.expectEqual(@as(u32, 1), nv.no_vendor);
    try std.testing.expectEqual(@as(u8, 2), nv.code());
}

test "scan: a changed reply shape is failed (exit 1), not a silent empty run; daily cap holds" {
    var r: Rig = undefined;
    try r.up("<html>not json</html>");
    defer r.down();
    const a = r.arena.allocator();
    var st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    try st.putCust(a, .{ .cust_id = "demo", .consent = true, .daily_cap = 1 });
    const t = [_]shape.Target{ .{ .kind = "page", .url = "https://www.facebook.com/a" }, .{ .kind = "page", .url = "https://www.facebook.com/b" } };
    const x = try scanCust(&r.cx, &st, "demo", &t, false);
    try std.testing.expectEqual(@as(u8, 1), x.code());
    try std.testing.expectEqual(@as(u32, 1), x.over_cap); // second target hit the cap of 1
    try std.testing.expectEqual(@as(usize, 0), try st.countRows("demo"));
}

test "scan: no consent, no scan" {
    var r: Rig = undefined;
    try r.up("{\"id\":\"1\"}");
    defer r.down();
    const a = r.arena.allocator();
    var st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    try st.putCust(a, .{ .cust_id = "demo", .consent = false, .targets = &.{.{ .kind = "page", .url = "https://www.facebook.com/a" }} });
    try std.testing.expectError(error.NoConsent, scanCust(&r.cx, &st, "demo", &.{}, false));
    try std.testing.expectEqual(@as(u32, 0), r.v.hits.load(.acquire));
}
