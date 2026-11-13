// Channel / video post pages of OTHER creators, read through a vendor only, links + metadata only (never media files).
// OFF until a written 20-page proof passes (config chan.proof_pages / pass_pct). No pass -> stays off.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");
const shape = @import("rw-shape.zig");
const fetch = @import("pu-fetch.zig");
const parse = @import("pu-parse.zig");
const route = @import("ve-route.zig");
const regis = @import("ve-regis.zig");

pub const Proof = struct { ts: i64, vendor: []const u8, tried: u32, ok: u32, pass: bool };

fn proofPath(a: std.mem.Allocator, cx: *const ctx_mod.Ctx) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/chan-proof.json", .{cx.home});
}

pub fn enabled(cx: *const ctx_mod.Ctx) bool {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = util.readAll(a, cx.io, proofPath(a, cx) catch return false, 4096) catch return false;
    const p = std.json.parseFromSliceLeaky(Proof, a, t, .{}) catch return false;
    return p.pass;
}

// try each url through the vendor path; write the proof file (pass only with enough pages AND enough successes)
pub fn runProof(cx: *ctx_mod.Ctx, st: *const store_mod.Store, reg: regis.Registry, vendor_id: []const u8, urls: []const []const u8) !Proof {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var sess = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = cx.mock, .resolver = cx.resolver, .max_pages = @intCast(urls.len + 1) });
    sess.fake_gap = cx.fake_gap;
    const only = [_][]const u8{vendor_id};
    const saved = cx.cfg.vendor.order;
    cx.cfg.vendor.order = &only;
    defer cx.cfg.vendor.order = saved;
    var rt = route.Router.init(cx, st, a, "ops", &sess, reg, true);
    var ok: u32 = 0;
    for (urls) |u| {
        if (rt.getVendorOnly(u) == .ok) ok += 1;
    }
    const tried: u32 = @intCast(urls.len);
    const pass = tried >= cx.cfg.chan.proof_pages and ok * 100 >= tried * cx.cfg.chan.pass_pct;
    const p = Proof{ .ts = cx.nowMs(), .vendor = vendor_id, .tried = tried, .ok = ok, .pass = pass };
    try util.mkdirp(cx.io, cx.home);
    try util.writeAtomic(a, cx.io, try proofPath(a, cx), try util.jsonStr(a, p));
    return p;
}

pub const ScanErr = error{ChanOff};

// rows of kind chan_page for one cust; refuses while the proof is missing/failed
pub fn scanCust(cx: *ctx_mod.Ctx, st: *store_mod.Store, cust_id: []const u8, reg: regis.Registry, urls: []const []const u8) !u32 {
    if (!enabled(cx)) return ScanErr.ChanOff;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cust = try st.getCust(a, cust_id);
    var sess = fetch.Session.init(a, .{ .io = cx.io, .cfg = cx.cfg.public, .mock = cx.mock, .resolver = cx.resolver, .max_pages = @intCast(urls.len + 1) });
    sess.fake_gap = cx.fake_gap;
    var rt = route.Router.init(cx, st, a, cust_id, &sess, reg, cust.vendors_allowed);
    var batch: std.ArrayList(shape.Row) = .empty;
    for (urls) |u| {
        switch (rt.getVendorOnly(u)) {
            .ok => |pg| {
                var m = try parse.parse(a, u, pg.body, .{ .text_cap = cx.cfg.public.text_cap, .field_cap = cx.cfg.public.field_cap });
                m.page = "chan_page";
                m.text = ""; // links + metadata only
                try batch.append(a, try parse.toRow(a, cust_id, m, pg.fetched_ms));
            },
            else => {},
        }
    }
    if (batch.items.len == 0) return 0;
    const s = try st.upsert(cust_id, batch.items);
    return s.added;
}

// ---- tests ----
const site = @import("te-mock-site.zig");
const mv = @import("te-mock-vendor.zig");

test "chan: off without proof; proof needs 20 pages and 95%; pass turns it on" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MK_C", mv.key);
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.fake_gap = true;
    cx.cfg.public = .{ .user_agent = "t/1", .allow_hosts = &.{}, .gap_ms = 1, .jitter_ms = 0, .timeout_s = 3, .body_cap_kb = 64, .daily_cap = 100, .robots_ttl_s = 60, .robots_cap_kb = 4 };
    var st = store_mod.Store.init(cx.io, cx.gpa, home);
    var s = site.Site.init(std.testing.allocator);
    defer s.deinit();
    const srv = try s.start(cx.io);
    defer srv.stop();
    var v = mv.Vend{};
    const vsrv = try v.start(cx.io);
    defer vsrv.stop();
    const defs = [_]shape.VendorDef{.{ .id = "vc", .base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v/query", .{vsrv.port}), .auth = .query, .auth_name = "apikey", .key_env = "MK_C" }};
    const reg = regis.Registry{ .defs = &defs };
    try st.putCust(a, .{ .cust_id = "demo" });
    var b: [128]u8 = undefined;
    const good = try a.dupe(u8, srv.url(&b, "/oa/ok"));
    // off: no proof file
    try std.testing.expectError(ScanErr.ChanOff, scanCust(&cx, &st, "demo", reg, &.{good}));
    // too few pages -> fail
    const p1 = try runProof(&cx, &st, reg, "vc", &.{ good, good });
    try std.testing.expect(!p1.pass);
    try std.testing.expect(!enabled(&cx));
    // 20 pages but the vendor is down -> fail
    var urls: [20][]const u8 = undefined;
    for (&urls) |*u| u.* = good;
    v.setMode(.err);
    const p2 = try runProof(&cx, &st, reg, "vc", &urls);
    try std.testing.expect(!p2.pass and p2.ok == 0);
    // vendor healthy again (breaker opened during the failing proof: revive it)
    const brk = @import("ve-break.zig").Breaker{ .io = cx.io, .gpa = cx.gpa, .home = home };
    try brk.revive("vc");
    v.setMode(.ok);
    const p3 = try runProof(&cx, &st, reg, "vc", &urls);
    try std.testing.expect(p3.pass and p3.ok == 20);
    try std.testing.expect(enabled(&cx));
    cx.cfg.vendor.order = &.{"vc"};
    const added = try scanCust(&cx, &st, "demo", reg, &.{good});
    try std.testing.expectEqual(@as(u32, 1), added);
    var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena2.deinit();
    const pg = try st.rowsSince(arena2.allocator(), "demo", 0, 5);
    try std.testing.expectEqualStrings("chan_page", pg.rows[0].kind);
    try std.testing.expectEqual(@as(u32, 0), s.hitsOf("/oa/ok")); // origin never touched
}
