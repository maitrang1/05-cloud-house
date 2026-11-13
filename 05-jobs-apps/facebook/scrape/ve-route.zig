// Router, vendor path only: Facebook data of other people is read logged out, through vendors, never by our own GET and never with a cookie.
// Ladder in config order (free first). Skips: breaker open, vendor off, quota at stop_pct, no endpoint for this kind. Stops for good on a challenge page.
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const guard = @import("co-guard.zig");
const regis = @import("ve-regis.zig");
const quota_mod = @import("ve-quota.zig");
const break_mod = @import("ve-break.zig");
const call = @import("ve-call.zig");

pub const Got = struct { body: []const u8, vendor: []const u8, credits: u32 };
pub const Outcome = union(enum) { ok: Got, no_vendor, blocked, cap_reached, guard_refused, failed };

pub const Router = struct {
    cx: *ctx_mod.Ctx,
    st: *const store_mod.Store,
    cust: []const u8,
    a: std.mem.Allocator,
    ladder: []const shape.VendorDef = &.{},
    quota: quota_mod.Quota,
    brk: break_mod.Breaker,
    max_calls: u32,
    calls: u32 = 0,
    credits: u32 = 0,
    hard_stop: bool = false, // a challenge page on any vendor ends the run

    pub fn init(cx: *ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, reg: ?regis.Registry, vendors_allowed: bool, max_calls: u32) Router {
        var r = Router{ .cx = cx, .st = st, .cust = cust, .a = a, .max_calls = max_calls, .quota = .{ .io = cx.io, .gpa = cx.gpa, .home = cx.home }, .brk = .{ .io = cx.io, .gpa = cx.gpa, .home = cx.home } };
        if (vendors_allowed) if (reg) |rg| {
            r.ladder = rg.ladder(a, cx.cfg.vendor.order) catch &.{};
        };
        return r;
    }

    fn note(self: *Router, url: []const u8, status: i64, why: []const u8) void {
        const red = guard.redactUrl(self.a, url) catch return;
        self.st.audit(self.cust, self.cx.nowMs(), "vendor", red, status, why);
    }

    pub fn get(self: *Router, kind: []const u8, url: []const u8) Outcome {
        if (self.hard_stop) return .blocked;
        if (self.ladder.len == 0) return .no_vendor;
        if (self.calls >= self.max_calls) return .cap_reached;
        // the target must pass our guard (allowed Facebook hosts, https) before any vendor sees it
        _ = guard.parseUrl(self.a, url, .{ .allow_hosts = self.cx.cfg.market.allow_hosts, .mock = self.cx.mock }) catch return .guard_refused;
        const cfgv = self.cx.cfg.vendor;
        const m = self.cx.cfg.market;
        const now = self.cx.nowMs();
        const env = call.Env{ .io = self.cx.io, .mock = self.cx.mock, .resolver = self.cx.resolver, .ua = m.user_agent, .timeout_s = m.timeout_s, .cap_bytes = @as(usize, m.body_cap_kb) * 1024 };
        var tried = false;
        for (self.ladder) |d0| {
            var d = d0;
            if (d.kinds.map.count() > 0) d.base = d.kinds.map.get(kind) orelse continue;
            if (self.brk.isDead(d.id) catch true) continue;
            if (self.brk.isOpen(d.id, now, cfgv.breaker_fails, cfgv.breaker_cool_s) catch true) continue;
            if (!(self.quota.allow(d, cfgv.stop_pct, now) catch false)) {
                self.note(url, 0, "quota_stop");
                continue;
            }
            const key = regis.keyOf(self.cx.env, d) orelse continue;
            tried = true;
            self.calls += 1;
            switch (call.call(self.a, env, d, key, url)) {
                .ok => |o| {
                    self.quota.record(d.id, self.cust, o.credits, now) catch {};
                    self.brk.ok(d.id) catch {};
                    self.credits +|= o.credits;
                    self.note(url, 200, d.id);
                    var lb: [96]u8 = undefined;
                    if (std.fmt.bufPrint(&lb, "{{\"ts\":{d},\"vendor\":\"{s}\",\"credits\":{d}}}", .{ now, d.id, o.credits })) |ln| self.st.appendLog(self.cust, "vendor_use.jsonl", ln) catch {} else |_| {}
                    return .{ .ok = .{ .body = o.body, .vendor = d.id, .credits = o.credits } };
                },
                .dead => {
                    self.brk.kill(d.id) catch {};
                    self.note(url, 401, "key_rejected_vendor_off");
                },
                .limited => {
                    self.brk.fail(d.id, now) catch {};
                    self.note(url, 429, "vendor_limited");
                },
                .failed => {
                    self.brk.fail(d.id, now) catch {};
                    self.note(url, 0, "vendor_failed");
                },
                .challenge => {
                    self.hard_stop = true;
                    self.note(url, 0, "challenge_stop");
                    return .blocked;
                },
            }
        }
        return if (tried) .failed else .no_vendor;
    }
};

// ---- tests: ladder falls through, dead key switches off, challenge stops the run, kinds pick the endpoint, guard first ----
const mv = @import("te-mock-vendor.zig");

fn mkDef(a: std.mem.Allocator, port: u16, id: []const u8, env_name: []const u8) !shape.VendorDef {
    return .{ .id = id, .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{port}), .auth = .query, .auth_name = "apikey", .key_env = env_name, .credit_header = "x-cost", .budget = 10 };
}

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    hb: [128]u8 = undefined,
    cx: ctx_mod.Ctx = undefined,
    fn up(self: *Rig) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.env = std.process.Environ.Map.init(std.testing.allocator);
        const home = try std.fmt.bufPrint(&self.hb, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
        try self.env.put("MK_A", mv.key);
        try self.env.put("MK_B", mv.key);
        self.cx = ctx_mod.testCtx(self.arena.allocator(), &self.env, home);
        self.cx.mock = true;
        self.cx.cfg.market.allow_hosts = &.{ "facebook.com", "www.facebook.com" };
    }
    fn down(self: *Rig) void {
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "route: first vendor dies, the next serves; dead key stays off; credits counted" {
    var r: Rig = undefined;
    try r.up();
    defer r.down();
    const a = r.arena.allocator();
    r.cx.cfg.vendor.order = &.{ "va", "vb" };
    var v1 = mv.Vend{ .cost = 2, .page = "{\"name\":\"x\"}" };
    const s1 = try v1.start(r.cx.io);
    defer s1.stop();
    var v2 = mv.Vend{ .cost = 3, .page = "{\"name\":\"y\"}" };
    const s2 = try v2.start(r.cx.io);
    defer s2.stop();
    try r.env.put("MK_A", "WRONGKEY"); // vendor A rejects the key
    const defs = [_]shape.VendorDef{ try mkDef(a, s1.port, "va", "MK_A"), try mkDef(a, s2.port, "vb", "MK_B") };
    const st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    var rt = Router.init(&r.cx, &st, a, "demo", .{ .defs = &defs }, true, 10);
    const o = rt.get("page", "https://www.facebook.com/example");
    try std.testing.expect(o == .ok);
    try std.testing.expectEqualStrings("vb", o.ok.vendor);
    try std.testing.expectEqual(@as(u32, 3), rt.credits);
    try std.testing.expectEqual(@as(u32, 1), v1.hits.load(.acquire));
    // A is off now: a second page goes straight to B
    _ = rt.get("page", "https://www.facebook.com/example2");
    try std.testing.expectEqual(@as(u32, 1), v1.hits.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), v2.hits.load(.acquire));
}

test "route: challenge stops the whole run; 429 trips toward the breaker; cap and guard" {
    var r: Rig = undefined;
    try r.up();
    defer r.down();
    const a = r.arena.allocator();
    r.cx.cfg.vendor.order = &.{"va"};
    var v1 = mv.Vend{ .page = "{}" };
    const s1 = try v1.start(r.cx.io);
    defer s1.stop();
    const defs = [_]shape.VendorDef{try mkDef(a, s1.port, "va", "MK_A")};
    const st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    var rt = Router.init(&r.cx, &st, a, "demo", .{ .defs = &defs }, true, 2);
    try std.testing.expect(rt.get("page", "https://evil.example.com/x") == .guard_refused);
    try std.testing.expect(rt.get("page", "http://www.facebook.com/x") == .guard_refused);
    try std.testing.expectEqual(@as(u32, 0), v1.hits.load(.acquire)); // a refused url never reaches a vendor
    v1.setMode(.limited);
    try std.testing.expect(rt.get("page", "https://www.facebook.com/a") == .failed);
    v1.setMode(.challenge);
    try std.testing.expect(rt.get("page", "https://www.facebook.com/b") == .blocked);
    try std.testing.expect(rt.get("page", "https://www.facebook.com/c") == .blocked); // stopped for good, no new call
    try std.testing.expectEqual(@as(u32, 2), v1.hits.load(.acquire));
    var rt2 = Router.init(&r.cx, &st, a, "demo", .{ .defs = &defs }, true, 0);
    try std.testing.expect(rt2.get("page", "https://www.facebook.com/a") == .cap_reached);
    var rt3 = Router.init(&r.cx, &st, a, "demo", .{ .defs = &defs }, false, 5);
    try std.testing.expect(rt3.get("page", "https://www.facebook.com/a") == .no_vendor);
}

test "route: a vendor with kinds is used only for the kinds it lists" {
    var r: Rig = undefined;
    try r.up();
    defer r.down();
    const a = r.arena.allocator();
    r.cx.cfg.vendor.order = &.{ "va", "vb" };
    var v1 = mv.Vend{ .page = "{\"from\":\"a\"}" };
    const s1 = try v1.start(r.cx.io);
    defer s1.stop();
    var v2 = mv.Vend{ .page = "{\"from\":\"b\"}" };
    const s2 = try v2.start(r.cx.io);
    defer s2.stop();
    var da = try mkDef(a, s1.port, "va", "MK_A");
    try da.kinds.map.put(a, "page", da.base); // A knows pages only
    const defs = [_]shape.VendorDef{ da, try mkDef(a, s2.port, "vb", "MK_B") };
    const st = store_mod.Store.init(r.cx.io, std.testing.allocator, r.cx.home);
    var rt = Router.init(&r.cx, &st, a, "demo", .{ .defs = &defs }, true, 10);
    const p = rt.get("page", "https://www.facebook.com/a");
    try std.testing.expectEqualStrings("va", p.ok.vendor);
    const it = rt.get("item", "https://www.facebook.com/marketplace/search?q=x");
    try std.testing.expectEqualStrings("vb", it.ok.vendor);
}
