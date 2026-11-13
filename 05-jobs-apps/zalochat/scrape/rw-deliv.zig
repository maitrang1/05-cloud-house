// Delivery: signed webhook (HMAC-SHA256 over "<ts>.<body>"), retry with backoff, DLQ on failure; plus the pull page.
// At-least-once: the cursor moves only after a 2xx. Receivers dedupe by cust_id+key+hash.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const guard = @import("pu-guard.zig");
const net = @import("pu-net.zig");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub fn signBuf(secret: []const u8, ts: i64, body: []const u8) [71]u8 {
    var mac: [Hmac.mac_length]u8 = undefined;
    var h = Hmac.init(secret);
    var tb: [24]u8 = undefined;
    h.update(std.fmt.bufPrint(&tb, "{d}.", .{ts}) catch unreachable); // i64 fits 24 bytes
    h.update(body);
    h.final(&mac);
    const hex = std.fmt.bytesToHex(mac, .lower);
    var out: [71]u8 = undefined;
    @memcpy(out[0..7], "sha256=");
    @memcpy(out[7..], &hex);
    return out;
}

pub fn sign(a: std.mem.Allocator, secret: []const u8, ts: i64, body: []const u8) ![]u8 {
    return a.dupe(u8, &signBuf(secret, ts, body));
}

pub const VerifyErr = error{ BadSignature, Stale };

// receiver side (docs + tests): constant-time compare, reject old timestamps
pub fn verify(secret: []const u8, ts: i64, body: []const u8, sig: []const u8, now: i64, max_age_s: i64) VerifyErr!void {
    if (@abs(now - ts) > max_age_s * 1000) return VerifyErr.Stale;
    if (sig.len != 71) return VerifyErr.BadSignature; // "sha256=" + 64 hex
    const want = signBuf(secret, ts, body);
    if (!std.crypto.timing_safe.eql([71]u8, want, sig[0..71].*)) return VerifyErr.BadSignature;
}

pub const Outcome = enum { delivered, nothing_new, failed, no_webhook, no_secret };

pub const Summary = struct { outcome: Outcome, rows: u32 = 0, from: usize = 0, to: usize = 0, tries: u32 = 0 };

fn cursorPath(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) ![]u8 {
    return st.path(a, cust, "deliv.cursor");
}
pub fn cursorOf(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) usize {
    const t = util.readAll(a, st.io, cursorPath(st, a, cust) catch return 0, 64) catch return 0;
    return std.fmt.parseInt(usize, std.mem.trim(u8, t, " \n"), 10) catch 0;
}

const Payload = struct { cust_id: []const u8, from: usize, to: usize, rows: []const shape.Row };

pub fn push(cx: *ctx_mod.Ctx, st: *const store_mod.Store, cust_id: []const u8) !Summary {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cust = try st.getCust(a, cust_id);
    if (cust.webhook_url.len == 0) return .{ .outcome = .no_webhook };
    const secret = cx.envGet(cx.cfg.deliv.secret_env) orelse return .{ .outcome = .no_secret };
    const from = cursorOf(st, a, cust_id);
    const pg = try st.rowsSince(a, cust_id, from, cx.cfg.deliv.pull_page);
    if (pg.rows.len == 0) return .{ .outcome = .nothing_new, .from = from, .to = from };
    const body = try std.json.Stringify.valueAlloc(a, Payload{ .cust_id = cust_id, .from = from, .to = pg.next, .rows = pg.rows }, .{});
    const t = guard.parseUrl(a, cust.webhook_url, .{ .allow_hosts = &.{}, .mock = cx.mock, .any_host = true }) catch {
        st.audit(cust_id, cx.nowMs(), "deliv", "webhook", 0, "webhook_url_refused");
        return .{ .outcome = .failed, .from = from, .to = pg.next };
    };
    var tries: u32 = 0;
    var last_note: []const u8 = "";
    var last_status: i64 = 0;
    while (tries <= cx.cfg.deliv.retries) : (tries += 1) {
        if (tries > 0) {
            const back = @as(i64, cx.cfg.deliv.backoff_ms) << @intCast(@min(tries - 1, 8));
            if (!cx.fake_gap) util.sleepMs(cx.io, back);
        }
        const ts = cx.nowMs();
        const sig = try sign(a, secret, ts, body);
        const tsv = try std.fmt.allocPrint(a, "{d}", .{ts});
        const hs = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = cx.cfg.deliv.sig_header, .value = sig },
            .{ .name = "x-scrape-timestamp", .value = tsv },
            .{ .name = "x-scrape-cust", .value = cust_id },
        };
        const ip = guard.pin(cx.io, cx.resolver, t) catch {
            last_note = "dest_ip_refused";
            break; // a private destination is not retried
        };
        const resp = net.get(cx.io, a, t, ip, .{ .ua = cx.cfg.public.user_agent, .timeout_s = cx.cfg.public.timeout_s, .cap_bytes = 64 * 1024, .headers = &hs, .method = "POST", .body = body }) catch |e| {
            last_note = @errorName(e);
            last_status = 0;
            continue;
        };
        last_status = resp.status;
        if (resp.status >= 200 and resp.status < 300) {
            try util.writeAtomic(a, cx.io, try cursorPath(st, a, cust_id), try std.fmt.allocPrint(a, "{d}\n", .{pg.next}));
            st.audit(cust_id, cx.nowMs(), "deliv", "webhook", resp.status, "delivered");
            return .{ .outcome = .delivered, .rows = @intCast(pg.rows.len), .from = from, .to = pg.next, .tries = tries + 1 };
        }
        last_note = "bad_status";
        if (resp.status >= 400 and resp.status < 500 and resp.status != 408 and resp.status != 429) break; // receiver says no: do not hammer
    }
    // dead letter: record the range, keep the cursor so the next run retries it
    var lb: [256]u8 = undefined;
    if (std.fmt.bufPrint(&lb, "{{\"ts\":{d},\"from\":{d},\"to\":{d},\"status\":{d},\"note\":\"{s}\"}}", .{ cx.nowMs(), from, pg.next, last_status, last_note })) |ln| st.appendLog(cust_id, "dlq.jsonl", ln) catch {} else |_| {}
    st.audit(cust_id, cx.nowMs(), "deliv", "webhook", last_status, "dlq");
    return .{ .outcome = .failed, .rows = 0, .from = from, .to = pg.next, .tries = tries };
}

// ---- tests with a signing-checking receiver ----
const ms = @import("te-mini-srv.zig");

const Rcv = struct {
    secret: []const u8,
    status: u16 = 200,
    hits: std.atomic.Value(u32) = .init(0),
    verified: std.atomic.Value(u32) = .init(0),
    now: i64,
    last_body: [4096]u8 = undefined,
    last_len: usize = 0,
};

fn rcvHandler(ctx: *anyopaque, _: std.mem.Allocator, req: ms.Request) ms.Reply {
    const r: *Rcv = @ptrCast(@alignCast(ctx));
    _ = r.hits.fetchAdd(1, .acq_rel);
    const sig = ms.headerOf(req.head, "x-scrape-signature");
    const ts = std.fmt.parseInt(i64, ms.headerOf(req.head, "x-scrape-timestamp"), 10) catch return .{ .status = 400 };
    verify(r.secret, ts, req.body, sig, ts, 300) catch return .{ .status = 401, .body = "bad signature" };
    _ = r.verified.fetchAdd(1, .acq_rel);
    const n = @min(req.body.len, r.last_body.len);
    @memcpy(r.last_body[0..n], req.body[0..n]);
    r.last_len = n;
    return .{ .status = r.status };
}

test "sign/verify: good, tampered, wrong secret, stale" {
    const a = std.testing.allocator;
    const sig = try sign(a, "s3cret", 1000, "{\"x\":1}");
    defer a.free(sig);
    try verify("s3cret", 1000, "{\"x\":1}", sig, 1000, 300);
    try std.testing.expectError(VerifyErr.BadSignature, verify("s3cret", 1000, "{\"x\":2}", sig, 1000, 300));
    try std.testing.expectError(VerifyErr.BadSignature, verify("other", 1000, "{\"x\":1}", sig, 1000, 300));
    try std.testing.expectError(VerifyErr.Stale, verify("s3cret", 1000, "{\"x\":1}", sig, 1000 + 301_000, 300));
}

fn deliverRig(arena: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8, st: *store_mod.Store, port: u16, secret_set: bool) !ctx_mod.Ctx {
    if (secret_set) try env.put("HOOK_SECRET_T", "whsec_test");
    var cx = ctx_mod.testCtx(arena, env, home);
    cx.mock = true;
    cx.fake_gap = true;
    cx.cfg.deliv.secret_env = "HOOK_SECRET_T";
    cx.cfg.deliv.retries = 2;
    cx.cfg.deliv.pull_page = 2;
    cx.cfg.public.timeout_s = 3;
    cx.cfg.public.user_agent = "t/1";
    try st.putCust(arena, .{ .cust_id = "demo", .webhook_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/hook", .{port}) });
    return cx;
}

fn seedRows(a: std.mem.Allocator, st: *store_mod.Store, n: usize) !void {
    for (0..n) |i| {
        const d = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"t\":1}", .{});
        const r = try shape.makeRow(a, "demo", .public, try std.fmt.allocPrint(a, "k{d}", .{i}), "oa_page", 1, d);
        _ = try st.upsert("demo", &.{r});
    }
}

test "deliv: signed batch accepted, cursor advances page by page" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var rc = Rcv{ .secret = "whsec_test", .now = 0 };
    const srv = try ms.Srv.start(std.testing.io, rcvHandler, &rc);
    defer srv.stop();
    var st = store_mod.Store.init(std.testing.io, std.testing.allocator, home);
    var cx = try deliverRig(a, &env, home, &st, srv.port, true);
    try seedRows(a, &st, 3);
    const s1 = try push(&cx, &st, "demo");
    try std.testing.expect(s1.outcome == .delivered);
    try std.testing.expectEqual(@as(u32, 2), s1.rows);
    try std.testing.expect(std.mem.indexOf(u8, rc.last_body[0..rc.last_len], "\"cust_id\":\"demo\"") != null);
    const s2 = try push(&cx, &st, "demo");
    try std.testing.expectEqual(@as(u32, 1), s2.rows);
    try std.testing.expect((try push(&cx, &st, "demo")).outcome == .nothing_new);
    try std.testing.expectEqual(@as(u32, 2), rc.verified.load(.acquire));
}

test "deliv: dead receiver -> retries -> DLQ, cursor stays; recovery redelivers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var rc = Rcv{ .secret = "whsec_test", .now = 0, .status = 500 };
    const srv = try ms.Srv.start(std.testing.io, rcvHandler, &rc);
    defer srv.stop();
    var st = store_mod.Store.init(std.testing.io, std.testing.allocator, home);
    var cx = try deliverRig(a, &env, home, &st, srv.port, true);
    try seedRows(a, &st, 1);
    const s = try push(&cx, &st, "demo");
    try std.testing.expect(s.outcome == .failed);
    try std.testing.expectEqual(@as(u32, 3), rc.hits.load(.acquire)); // 1 + 2 retries
    const dlq = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/cust/demo/dlq.jsonl", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, dlq, "\"status\":500") != null);
    try std.testing.expectEqual(@as(usize, 0), cursorOf(&st, a, "demo"));
    rc.status = 200;
    try std.testing.expect((try push(&cx, &st, "demo")).outcome == .delivered);
}

test "deliv: wrong secret = receiver refuses (401) and no retry storm; 4xx stops; no secret or hook = skipped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var rc = Rcv{ .secret = "different", .now = 0 };
    const srv = try ms.Srv.start(std.testing.io, rcvHandler, &rc);
    defer srv.stop();
    var st = store_mod.Store.init(std.testing.io, std.testing.allocator, home);
    var cx = try deliverRig(a, &env, home, &st, srv.port, true);
    try seedRows(a, &st, 1);
    try std.testing.expect((try push(&cx, &st, "demo")).outcome == .failed);
    try std.testing.expectEqual(@as(u32, 1), rc.hits.load(.acquire));
    // no secret
    var env2 = std.process.Environ.Map.init(std.testing.allocator);
    defer env2.deinit();
    var cx2 = try deliverRig(a, &env2, home, &st, srv.port, false);
    try std.testing.expect((try push(&cx2, &st, "demo")).outcome == .no_secret);
    // no webhook
    try st.putCust(a, .{ .cust_id = "demo" });
    try std.testing.expect((try push(&cx, &st, "demo")).outcome == .no_webhook);
    // private destination refused
    try st.putCust(a, .{ .cust_id = "demo", .webhook_url = "https://10.0.0.1/hook" });
    try std.testing.expect((try push(&cx, &st, "demo")).outcome == .failed);
}
