// Router: own GET first; vendors only as fallback. A vendor never fetches a url our guard or robots would refuse.
// Fallback only for: 403 (origin blocks our IP), 5xx, timeout, network. NEVER for 429 (we respect the rate limit), a CAPTCHA/challenge page, or robots-denied.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const fetch = @import("pu-fetch.zig");
const guard = @import("pu-guard.zig");
const regis = @import("ve-regis.zig");
const quota_mod = @import("ve-quota.zig");
const break_mod = @import("ve-break.zig");
const call = @import("ve-call.zig");

pub const Via = enum { own, vendor };

pub const Router = struct {
    cx: *ctx_mod.Ctx,
    st: *const store_mod.Store,
    cust: []const u8,
    a: std.mem.Allocator,
    sess: *fetch.Session,
    ladder: []const shape.VendorDef = &.{},
    quota: quota_mod.Quota,
    brk: break_mod.Breaker,
    vendor_pages: u32 = 0,
    vendor_credits: u32 = 0,
    last_via: Via = .own,
    last_vendor: []const u8 = "",
    hard_stop: bool = false, // challenge seen on any path

    pub fn init(cx: *ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, sess: *fetch.Session, reg: ?regis.Registry, vendors_allowed: bool) Router {
        var r = Router{ .cx = cx, .st = st, .cust = cust, .a = a, .sess = sess, .quota = .{ .io = cx.io, .gpa = cx.gpa, .home = cx.home }, .brk = .{ .io = cx.io, .gpa = cx.gpa, .home = cx.home } };
        if (vendors_allowed) if (reg) |rg| {
            r.ladder = rg.ladder(a, cx.cfg.vendor.order) catch &.{};
        };
        return r;
    }

    fn note(self: *Router, url: []const u8, status: i64, why: []const u8) void {
        const red = guard.redactUrl(self.a, url) catch return;
        self.st.audit(self.cust, self.cx.nowMs(), "vendor", red, status, why);
    }

    fn vendorTry(self: *Router, url: []const u8) ?fetch.Outcome {
        const cfgv = self.cx.cfg.vendor;
        const now = self.cx.nowMs();
        // the target must pass our own guard + robots before any vendor sees it
        if (guard.parseUrl(self.a, url, .{ .allow_hosts = self.cx.cfg.public.allow_hosts, .mock = self.cx.mock })) |_| {} else |_| return null;
        if (!self.sess.robotsAllows(url)) return .robots_denied;
        const env = call.Env{ .io = self.cx.io, .mock = self.cx.mock, .resolver = self.cx.resolver, .ua = self.cx.cfg.public.user_agent, .timeout_s = self.cx.cfg.public.timeout_s, .cap_bytes = @as(usize, self.cx.cfg.public.body_cap_kb) * 1024 };
        for (self.ladder) |d| {
            if (self.brk.isDead(d.id) catch true) continue;
            if (self.brk.isOpen(d.id, now, cfgv.breaker_fails, cfgv.breaker_cool_s) catch true) continue;
            if (!(self.quota.allow(d, cfgv.stop_pct, now) catch false)) {
                self.note(url, 0, "quota_stop");
                continue;
            }
            const key = regis.keyOf(self.cx.env, d) orelse continue;
            const res = call.call(self.a, env, d, key, url);
            switch (res) {
                .ok => |o| {
                    self.quota.record(d.id, self.cust, o.credits, now) catch {};
                    self.brk.ok(d.id) catch {};
                    self.vendor_pages += 1;
                    self.vendor_credits +|= o.credits;
                    self.last_via = .vendor;
                    self.last_vendor = d.id;
                    self.note(url, 200, d.id);
                    var lb: [96]u8 = undefined;
                    if (std.fmt.bufPrint(&lb, "{{\"ts\":{d},\"vendor\":\"{s}\",\"credits\":{d}}}", .{ now, d.id, o.credits })) |ln| self.st.appendLog(self.cust, "vendor_use.jsonl", ln) catch {} else |_| {}
                    return .{ .ok = .{ .url = url, .status = 200, .body = o.body, .fetched_ms = now, .content_type = "text/html" } };
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
                    self.sess.stopped = true;
                    self.sess.stop_reason = "challenge_page";
                    self.note(url, 0, "challenge_stop");
                    return .{ .blocked = "challenge_page" };
                },
            }
        }
        return null;
    }

    // vendor path only (channel/video pages: no own GET). Same guard + robots + quota rules.
    pub fn getVendorOnly(self: *Router, url: []const u8) fetch.Outcome {
        self.last_via = .own;
        if (self.hard_stop) return .stopped;
        if (self.ladder.len == 0) return .net_fail;
        if (self.sess.pages + self.vendor_pages >= self.sess.p.max_pages) return .cap_reached;
        return self.vendorTry(url) orelse .net_fail;
    }

    pub fn get(self: *Router, url: []const u8) fetch.Outcome {
        self.last_via = .own;
        if (self.hard_stop) return .stopped;
        const o = self.sess.get(url);
        const via_vendor = switch (o) {
            .server_error, .timeout, .net_fail => true,
            .blocked => |why| std.mem.eql(u8, why, "forbidden"),
            .stopped => std.mem.eql(u8, self.sess.stop_reason, "forbidden"),
            else => false,
        };
        if (!via_vendor or self.ladder.len == 0) return o;
        if (self.sess.pages + self.vendor_pages >= self.sess.p.max_pages) return .cap_reached;
        return self.vendorTry(url) orelse o;
    }
};

// ---- tests: own blocked -> vendor; dead key switches off; 429 and CAPTCHA never go to vendors ----
const site = @import("te-mock-site.zig");
const mv = @import("te-mock-vendor.zig");

fn mkDef(a: std.mem.Allocator, port: u16, id: []const u8, env_name: []const u8) !shape.VendorDef {
    return .{ .id = id, .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{port}), .auth = .query, .auth_name = "apikey", .key_env = env_name, .credit_header = "x-cost", .budget = 10 };
}

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    hb: [128]u8 = undefined,

    fn home(self: *Rig) ![]const u8 {
        return std.fmt.bufPrint(&self.hb, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
    }
};

fn testPublic() @import("co-cfg.zig").Public {
    return .{ .user_agent = "zalochat-scrape/0.1 (test)", .allow_hosts = &.{}, .gap_ms = 1, .jitter_ms = 0, .timeout_s = 3, .body_cap_kb = 64, .daily_cap = 50, .robots_ttl_s = 60, .robots_cap_kb = 4 };
}

test "route: 403 on own GET falls through to vendor; 2nd url skips own GET" {
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
    try env.put("MK_A", mv.key);
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.cfg.public = testPublic();
    cx.cfg.vendor.order = &.{"va"};
    var s = site.Site.init(gpa);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var v = mv.Vend{ .cost = 2 };
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    const defs = [_]shape.VendorDef{try mkDef(a, vsrv.port, "va", "MK_A")};
    const st = store_mod.Store.init(cx.io, gpa, home);
    var sess = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = true, .max_pages = 20 });
    var rt = Router.init(&cx, &st, a, "demo", &sess, .{ .defs = &defs }, true);
    var ub: [128]u8 = undefined;
    const o = rt.get(srv.url(&ub, "/oa/403"));
    try std.testing.expect(o == .ok);
    try std.testing.expect(rt.last_via == .vendor);
    try std.testing.expectEqual(@as(u64, 2), try rt.quota.used("va", quota_mod.ymOf(cx.nowMs())));
    // second url: own path is stopped (forbidden) -> straight to vendor, origin never touched for it
    const o2 = rt.get(srv.url(&ub, "/oa/ok"));
    try std.testing.expect(o2 == .ok);
    try std.testing.expectEqual(@as(u32, 0), s.hitsOf("/oa/ok"));
    // robots still enforced for the vendor path
    const o3 = rt.get(srv.url(&ub, "/private/x"));
    try std.testing.expect(o3 == .robots_denied);
    try std.testing.expectEqual(@as(u32, 2), v.hits.load(.acquire));
}

test "route: 429 and challenge never reach a vendor" {
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
    try env.put("MK_A", mv.key);
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.cfg.public = testPublic();
    cx.cfg.vendor.order = &.{"va"};
    var s = site.Site.init(gpa);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var v = mv.Vend{};
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    const defs = [_]shape.VendorDef{try mkDef(a, vsrv.port, "va", "MK_A")};
    const st = store_mod.Store.init(cx.io, gpa, home);
    var ub: [128]u8 = undefined;
    var sess = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = true, .max_pages = 20 });
    var rt = Router.init(&cx, &st, a, "demo", &sess, .{ .defs = &defs }, true);
    try std.testing.expect(rt.get(srv.url(&ub, "/oa/429")) == .blocked);
    try std.testing.expect(rt.get(srv.url(&ub, "/oa/ok")) == .stopped);
    var sess2 = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = true, .max_pages = 20 });
    var rt2 = Router.init(&cx, &st, a, "demo", &sess2, .{ .defs = &defs }, true);
    try std.testing.expect(rt2.get(srv.url(&ub, "/oa/challenge")) == .blocked);
    try std.testing.expectEqual(@as(u32, 0), v.hits.load(.acquire));
}

test "route: dead key switches vendor off; next vendor serves; quota stop skips" {
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
    try env.put("MK_BAD", "WRONGKEY");
    try env.put("MK_GOOD", mv.key);
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.cfg.public = testPublic();
    cx.cfg.vendor.order = &.{ "vbad", "vgood" };
    var s = site.Site.init(gpa);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var v = mv.Vend{};
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    const defs = [_]shape.VendorDef{ try mkDef(a, vsrv.port, "vbad", "MK_BAD"), try mkDef(a, vsrv.port, "vgood", "MK_GOOD") };
    const st = store_mod.Store.init(cx.io, gpa, home);
    var sess = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = true, .max_pages = 40 });
    var rt = Router.init(&cx, &st, a, "demo", &sess, .{ .defs = &defs }, true);
    var ub: [128]u8 = undefined;
    try std.testing.expect(rt.get(srv.url(&ub, "/oa/500")) == .ok); // own 5xx (after retry) -> vbad dead -> vgood
    try std.testing.expect(try rt.brk.isDead("vbad"));
    try std.testing.expectEqualStrings("vgood", rt.last_vendor);
    const hits_after_first = v.hits.load(.acquire);
    // second url: vbad is off (no call), only vgood
    try std.testing.expect(rt.get(srv.url(&ub, "/oa/500")) == .ok);
    try std.testing.expectEqual(hits_after_first + 1, v.hits.load(.acquire));
    // vendors not allowed for this cust -> no fallback
    var sess2 = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = true, .max_pages = 40 });
    var rt2 = Router.init(&cx, &st, a, "demo", &sess2, .{ .defs = &defs }, false);
    try std.testing.expect(rt2.get(srv.url(&ub, "/oa/500")) == .server_error);
}
