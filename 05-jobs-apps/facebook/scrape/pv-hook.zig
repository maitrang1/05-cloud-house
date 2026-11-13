// Webhook receiver + data-deletion callback. The host (Ggc Run) calls these with the raw request; this app opens no port.
// Events: verify X-Hub-Signature-256 on the RAW body, store (replay-safe), then the host answers 200.
// Deletion: verify signed_request, purge that user's rows in every cust, return {url, confirmation_code}.
const std = @import("std");
const H = std.crypto.auth.hmac.sha2.HmacSha256;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const legal = @import("pv-legal.zig");
const oauth = @import("pv-oauth.zig");

pub const Err = error{ NoSecret, BadSignature, BadBody, BadAlgorithm, OutOfMemory };

fn secretOf(cx: *const ctx_mod.Ctx) Err![]const u8 {
    return cx.envGet(cx.cfg.graph.app_secret_env) orelse Err.NoSecret;
}

pub fn macHex(secret: []const u8, data: []const u8) [64]u8 {
    var m: [H.mac_length]u8 = undefined;
    H.create(&m, data, secret);
    return std.fmt.bytesToHex(m, .lower);
}

// constant-time compare of two hex strings of equal length
fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var d: u8 = 0;
    for (a, b) |x, y| d |= x ^ y;
    return d == 0;
}

// GET subscribe handshake: returns the challenge to echo, or null (host answers 403)
pub fn challenge(cx: *const ctx_mod.Ctx, mode: []const u8, token: []const u8, chal: []const u8) ?[]const u8 {
    const want = cx.envGet(cx.cfg.hook.verify_env) orelse return null;
    if (!std.mem.eql(u8, mode, "subscribe")) return null;
    if (!same(token, want) or token.len != want.len) return null;
    return chal;
}

pub fn verifySig(secret: []const u8, body: []const u8, header: []const u8) bool {
    const pre = "sha256=";
    if (!std.mem.startsWith(u8, header, pre)) return false;
    const mac = macHex(secret, body);
    return same(header[pre.len..], &mac);
}

pub const Event = struct { stored: u32 = 0, dup: u32 = 0, unknown_page: u32 = 0 };

pub fn handleEvent(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, body: []const u8, sig_header: []const u8) Err!Event {
    const secret = try secretOf(cx);
    if (!verifySig(secret, body, sig_header)) return Err.BadSignature;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch return Err.BadBody;
    if (v != .object) return Err.BadBody;
    const entries = v.object.get("entry") orelse return Err.BadBody;
    if (entries != .array) return Err.BadBody;
    var res = Event{};
    const now = cx.nowMs();
    for (entries.array.items) |e| {
        if (e != .object) continue;
        const pid = if (e.object.get("id")) |i| (if (i == .string) i.string else "") else "";
        const cust = oauth.ownerOf(cx, a, pid) orelse {
            res.unknown_page += 1;
            continue;
        };
        // a purged cust, or one without consent, stores nothing
        const cu = st.getCust(a, cust) catch {
            res.unknown_page += 1;
            continue;
        };
        if (cx.cfg.legal.consent_required and !cu.consent) {
            res.unknown_page += 1;
            continue;
        }
        var o = e.object.clone(a) catch return Err.OutOfMemory;
        o.put(a, "page", .{ .string = pid }) catch return Err.OutOfMemory;
        const text = std.json.Stringify.valueAlloc(a, e, .{}) catch return Err.OutOfMemory;
        const hx = util.sha256Hex(text);
        const key = std.fmt.allocPrint(a, "hook:{s}", .{hx[0..32]}) catch return Err.OutOfMemory;
        const r0 = shape.makeRow(a, cust, .private, key, "event", now, .{ .object = o }) catch return Err.OutOfMemory;
        const exp = now + @as(i64, cx.cfg.legal.own_expire_days) * store_mod.day_ms;
        const r = shape.withTerms(r0, exp, true);
        const s = st.upsert(cust, &.{r}) catch return Err.BadBody;
        res.stored += s.added;
        res.dup += s.dup;
    }
    return res;
}

pub const Deletion = struct { url: []const u8, confirmation_code: []const u8, rows: u32 };

pub fn deletion(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, signed_request: []const u8) Err!Deletion {
    const secret = try secretOf(cx);
    const dot = std.mem.indexOfScalar(u8, signed_request, '.') orelse return Err.BadBody;
    const sig_b64 = signed_request[0..dot];
    const payload_b64 = signed_request[dot + 1 ..];
    const D = std.base64.url_safe_no_pad.Decoder;
    var sig_raw: [H.mac_length]u8 = undefined;
    const sl = D.calcSizeForSlice(sig_b64) catch return Err.BadBody;
    if (sl != sig_raw.len) return Err.BadSignature;
    D.decode(&sig_raw, sig_b64) catch return Err.BadBody;
    const sig_hex = std.fmt.bytesToHex(sig_raw, .lower);
    const want = macHex(secret, payload_b64);
    if (!same(&sig_hex, &want)) return Err.BadSignature;
    const pl = D.calcSizeForSlice(payload_b64) catch return Err.BadBody;
    const pbuf = a.alloc(u8, pl) catch return Err.OutOfMemory;
    D.decode(pbuf, payload_b64) catch return Err.BadBody;
    const pj = std.json.parseFromSliceLeaky(std.json.Value, a, pbuf, .{}) catch return Err.BadBody;
    if (pj != .object) return Err.BadBody;
    const alg = if (pj.object.get("algorithm")) |x| (if (x == .string) x.string else "") else "";
    if (!std.ascii.eqlIgnoreCase(alg, "HMAC-SHA256")) return Err.BadAlgorithm;
    const uid = if (pj.object.get("user_id")) |x| (if (x == .string) x.string else "") else "";
    if (uid.len == 0) return Err.BadBody;
    const removed = legal.purgeUser(cx, st, a, uid) catch 0;
    // the confirmation code is stable for the same user (a retry gets the same code); the log never holds the user id
    const ch = util.sha256Hex(std.fmt.allocPrint(a, "del:{s}:{s}", .{ secret, uid }) catch return Err.OutOfMemory);
    const code = a.dupe(u8, ch[0..16]) catch return Err.OutOfMemory;
    const line = std.fmt.allocPrint(a, "{{\"ts\":{d},\"code\":\"{s}\",\"rows\":{d}}}", .{ cx.nowMs(), code, removed }) catch return Err.OutOfMemory;
    util.mkdirp(cx.io, cx.home) catch {};
    util.appendLine(cx.io, std.fmt.allocPrint(a, "{s}/deletions.jsonl", .{cx.home}) catch return Err.OutOfMemory, line) catch {};
    const url = std.fmt.allocPrint(a, "{s}?code={s}", .{ cx.cfg.hook.status_url, code }) catch return Err.OutOfMemory;
    return .{ .url = url, .confirmation_code = code, .rows = removed };
}

// status page lookup: true when that code was processed
pub fn deletionDone(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, code: []const u8) bool {
    const t = util.readAll(a, cx.io, std.fmt.allocPrint(a, "{s}/deletions.jsonl", .{cx.home}) catch return false, 64 * 1024 * 1024) catch return false;
    const needle = std.fmt.allocPrint(a, "\"code\":\"{s}\"", .{code}) catch return false;
    return code.len > 0 and std.mem.indexOf(u8, t, needle) != null;
}

// ---- tests ----
fn signedReq(a: std.mem.Allocator, secret: []const u8, payload_json: []const u8) ![]u8 {
    const E = std.base64.url_safe_no_pad.Encoder;
    const pb = try a.alloc(u8, E.calcSize(payload_json.len));
    _ = E.encode(pb, payload_json);
    var m: [H.mac_length]u8 = undefined;
    H.create(&m, pb, secret);
    const sb = try a.alloc(u8, E.calcSize(m.len));
    _ = E.encode(sb, &m);
    return std.fmt.allocPrint(a, "{s}.{s}", .{ sb, pb });
}

test "hook: handshake, forged signature refused, replay gives one row, unknown page ignored" {
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
    try env.put("FACE_HOOK_VERIFY", "vt1");
    var cx = ctx_mod.testCtx(a, &env, home);
    var st = store_mod.Store.init(cx.io, gpa, home);
    try st.putCust(a, .{ .cust_id = "acme", .consent = true });
    try std.testing.expectEqualStrings("42", challenge(&cx, "subscribe", "vt1", "42").?);
    try std.testing.expect(challenge(&cx, "subscribe", "bad", "42") == null);
    try std.testing.expect(challenge(&cx, "other", "vt1", "42") == null);
    try util.mkdirp(cx.io, home);
    try util.writeAtomic(a, cx.io, try std.fmt.allocPrint(a, "{s}/pages.json", .{home}), "{\"P1\":\"acme\"}");
    const body = "{\"object\":\"page\",\"entry\":[{\"id\":\"P1\",\"time\":1,\"messaging\":[{\"sender\":{\"id\":\"U100\"}}]},{\"id\":\"P9\",\"time\":1}]}";
    const good = try std.fmt.allocPrint(a, "sha256={s}", .{macHex("S3CRET", body)});
    const forged = try std.fmt.allocPrint(a, "sha256={s}", .{macHex("WRONG", body)});
    try std.testing.expectError(Err.BadSignature, handleEvent(&cx, &st, a, body, forged));
    try std.testing.expectError(Err.BadSignature, handleEvent(&cx, &st, a, body, "nope"));
    const r1 = try handleEvent(&cx, &st, a, body, good);
    try std.testing.expectEqual(@as(u32, 1), r1.stored);
    try std.testing.expectEqual(@as(u32, 1), r1.unknown_page);
    const r2 = try handleEvent(&cx, &st, a, body, good); // replay
    try std.testing.expectEqual(@as(u32, 0), r2.stored);
    try std.testing.expectEqual(@as(u32, 1), r2.dup);
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("acme"));
    // consent revoked: events are dropped, nothing stored
    try st.putCust(a, .{ .cust_id = "acme", .consent = false });
    const r3 = try handleEvent(&cx, &st, a, "{\"entry\":[{\"id\":\"P1\",\"time\":2}]}", try std.fmt.allocPrint(a, "sha256={s}", .{macHex("S3CRET", "{\"entry\":[{\"id\":\"P1\",\"time\":2}]}")}));
    try std.testing.expectEqual(@as(u32, 0), r3.stored);
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("acme"));
    // a body changed after signing is refused
    try std.testing.expectError(Err.BadSignature, handleEvent(&cx, &st, a, "{\"entry\":[]}", good));
}

test "hook: deletion callback purges one user everywhere and returns url + code" {
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
    cx.cfg.hook.user_keys = &.{ "user_id", "psid" };
    cx.cfg.hook.status_url = "https://app.example.com/deletion";
    var st = store_mod.Store.init(cx.io, gpa, home);
    const d1 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"M1\",\"from\":{\"id\":\"U100\",\"name\":\"An\"}}", .{});
    const d2 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"M2\",\"from\":{\"id\":\"U200\",\"name\":\"Binh\"}}", .{});
    const d3 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"id\":\"M3\",\"psid\":\"U100\"}", .{});
    _ = try st.upsert("acme", &.{ try shape.makeRow(a, "acme", .private, "M1", "chat", 1, d1), try shape.makeRow(a, "acme", .private, "M2", "chat", 1, d2) });
    _ = try st.upsert("beta", &.{try shape.makeRow(a, "beta", .private, "M3", "chat", 1, d3)});
    const sr = try signedReq(a, "S3CRET", "{\"algorithm\":\"HMAC-SHA256\",\"issued_at\":1,\"user_id\":\"U100\"}");
    const d = try deletion(&cx, &st, a, sr);
    try std.testing.expectEqual(@as(u32, 2), d.rows);
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("acme"));
    try std.testing.expectEqual(@as(usize, 0), try st.countRows("beta"));
    try std.testing.expectEqual(@as(usize, 16), d.confirmation_code.len);
    try std.testing.expect(std.mem.endsWith(u8, d.url, d.confirmation_code));
    try std.testing.expect(deletionDone(&cx, a, d.confirmation_code));
    try std.testing.expect(!deletionDone(&cx, a, "0000000000000000"));
    // the log never holds the user id
    const lg = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/deletions.jsonl", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, lg, "U100") == null);
    // a retry gets the same code; unknown user still gets a valid code
    const d2r = try deletion(&cx, &st, a, sr);
    try std.testing.expectEqualStrings(d.confirmation_code, d2r.confirmation_code);
    // forged, wrong algorithm, junk
    const forged = try signedReq(a, "WRONG", "{\"algorithm\":\"HMAC-SHA256\",\"user_id\":\"U200\"}");
    try std.testing.expectError(Err.BadSignature, deletion(&cx, &st, a, forged));
    const alg = try signedReq(a, "S3CRET", "{\"algorithm\":\"none\",\"user_id\":\"U200\"}");
    try std.testing.expectError(Err.BadAlgorithm, deletion(&cx, &st, a, alg));
    try std.testing.expectError(Err.BadBody, deletion(&cx, &st, a, "junk"));
    try std.testing.expectEqual(@as(usize, 1), try st.countRows("acme"));
}
