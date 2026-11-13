// mock-graph: fake Graph API + OAuth. App secret = APPSECRET. Good code = GOODCODE. Page token PAGETOK1 (page P1).
// Dead token DEADTOK -> 190 · BLOCKTOK -> 368 · RATETOK -> 4. Every token call must carry a right appsecret_proof, else error 100.
const std = @import("std");
const Io = std.Io;
const ms = @import("te-mini-srv.zig");
const graph = @import("ap-graph.zig");

pub const secret = "APPSECRET";
pub const code = "GOODCODE";
pub const page_tok = "PAGETOK1";
pub const user_long = "USERTOKLONG";

pub const Edge = struct { path: []const u8, items: []const []const u8 };

// fixtures: items are JSON texts, two per page so cursors get used
pub const edges = [_]Edge{
    .{ .path = "me/accounts", .items = &.{"{\"id\":\"P1\",\"name\":\"Page One\",\"access_token\":\"PAGETOK1\",\"extra_new_field\":1}"} },
    .{ .path = "P1/conversations", .items = &.{
        "{\"id\":\"C1\",\"updated_time\":\"2026-11-10T10:00:00+0000\",\"message_count\":3}",
        "{\"id\":\"C2\",\"updated_time\":\"2026-11-09T10:00:00+0000\",\"message_count\":1}",
        "{\"id\":\"C3\",\"updated_time\":\"2026-11-08T10:00:00+0000\",\"message_count\":1}",
    } },
    .{ .path = "C1/messages", .items = &.{
        "{\"id\":\"M1\",\"created_time\":\"2026-11-10T10:00:00+0000\",\"from\":{\"id\":\"U100\",\"name\":\"An\"},\"message\":\"xin chao\"}",
        "{\"id\":\"M2\",\"created_time\":\"2026-11-10T09:00:00+0000\",\"from\":{\"id\":\"U100\",\"name\":\"An\"},\"sticker\":\"https://x/s.png\"}",
        "{\"id\":\"M3\",\"created_time\":\"2026-11-10T08:00:00+0000\",\"from\":{\"id\":\"U100\",\"name\":\"An\"},\"attachments\":{\"data\":[{\"type\":\"appointment_booking_v9\",\"payload\":{\"x\":1}}]}}",
    } },
    .{ .path = "C2/messages", .items = &.{"{\"id\":\"M4\",\"created_time\":\"2026-11-09T10:00:00+0000\",\"from\":{\"id\":\"U200\",\"name\":\"Binh\"},\"message\":\"gia?\"}"} },
    .{ .path = "C3/messages", .items = &.{"{\"id\":\"M5\",\"created_time\":\"2026-11-08T10:00:00+0000\",\"from\":{\"id\":\"U300\",\"name\":\"Chi\"},\"message\":\"ok\"}"} },
    .{ .path = "P1/published_posts", .items = &.{
        "{\"id\":\"P1_1\",\"message\":\"Khai truong\",\"created_time\":\"2026-11-10T07:00:00+0000\",\"permalink_url\":\"https://www.facebook.com/P1/posts/1\"}",
        "{\"id\":\"P1_2\",\"message\":\"Giam gia\",\"created_time\":\"2026-11-09T07:00:00+0000\",\"permalink_url\":\"https://www.facebook.com/P1/posts/2\"}",
    } },
    .{ .path = "P1_1/comments", .items = &.{"{\"id\":\"K1\",\"message\":\"hay qua\",\"created_time\":\"2026-11-10T08:00:00+0000\",\"from\":{\"id\":\"U100\",\"name\":\"An\"},\"like_count\":2}"} },
    .{ .path = "P1_2/comments", .items = &.{} },
    .{ .path = "P1/leadgen_forms", .items = &.{"{\"id\":\"F1\",\"name\":\"Dang ky\",\"status\":\"ACTIVE\",\"leads_count\":2}"} },
    .{ .path = "F1/leads", .items = &.{
        "{\"id\":\"LD1\",\"created_time\":\"2026-11-10T06:00:00+0000\",\"field_data\":[{\"name\":\"email\",\"values\":[\"a@example.com\"]}]}",
        "{\"id\":\"LD2\",\"created_time\":\"2026-11-10T05:00:00+0000\",\"field_data\":[{\"name\":\"email\",\"values\":[\"b@example.com\"]}]}",
    } },
    .{ .path = "P1/live_videos", .items = &.{"{\"id\":\"L1\",\"status\":\"LIVE\",\"title\":\"Ban hang\",\"creation_time\":\"2026-11-10T12:00:00+0000\",\"live_views\":5}"} },
    .{ .path = "L1/comments", .items = &.{
        "{\"id\":\"LK1\",\"message\":\"gia bao nhieu\",\"created_time\":\"2026-11-10T12:01:00+0000\",\"from\":{\"id\":\"U400\",\"name\":\"Dung\"}}",
        "{\"id\":\"LK2\",\"message\":\"ship khong\",\"created_time\":\"2026-11-10T12:02:00+0000\",\"from\":{\"id\":\"U500\",\"name\":\"Em\"}}",
    } },
    .{ .path = "P1/insights", .items = &.{
        "{\"name\":\"page_media_view\",\"period\":\"day\",\"values\":[{\"value\":120,\"end_time\":\"2026-11-10T08:00:00+0000\"}]}",
        "{\"name\":\"page_follows\",\"period\":\"day\",\"values\":[{\"value\":3400,\"end_time\":\"2026-11-10T08:00:00+0000\"}]}",
    } },
};

pub const Mock = struct {
    hits: std.atomic.Value(u32) = .init(0),
    usage_pct: std.atomic.Value(u32) = .init(0),
    bad_proofs: std.atomic.Value(u32) = .init(0),
    version: []const u8 = "v26.0",
    per_page: usize = 2,

    pub fn start(self: *Mock, io: Io) !*ms.Srv {
        return ms.Srv.start(io, handler, self);
    }
};

fn param(q: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return "";
}

fn errBody(c: i64, msg: []const u8) ms.Reply {
    return .{ .status = 400, .body = std.fmt.allocPrint(std.heap.page_allocator, "{{\"error\":{{\"message\":\"{s}\",\"type\":\"OAuthException\",\"code\":{d}}}}}", .{ msg, c }) catch "" };
}

fn handler(ctx: *anyopaque, a: std.mem.Allocator, req: ms.Request) ms.Reply {
    const m: *Mock = @ptrCast(@alignCast(ctx));
    _ = m.hits.fetchAdd(1, .acq_rel);
    const qi = std.mem.indexOfScalar(u8, req.path, '?');
    const full = if (qi) |i| req.path[0..i] else req.path;
    const q = if (qi) |i| req.path[i + 1 ..] else "";
    if (full.len < 2 or full[0] != '/') return .{ .status = 404 };
    const rest = full[1..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .{ .status = 404 };
    if (!std.mem.eql(u8, rest[0..slash], m.version)) return errBody(2635, "unknown version");
    const path = rest[slash + 1 ..];
    var hdr_buf: [96]u8 = undefined;
    const pctn = m.usage_pct.load(.acquire);
    const hdr: []const u8 = if (pctn > 0) (std.fmt.bufPrint(&hdr_buf, "X-App-Usage: {{\"call_count\":{d},\"total_time\":1,\"total_cputime\":1}}\r\n", .{pctn}) catch "") else "";
    const hdr_c = a.dupe(u8, hdr) catch "";

    if (std.mem.eql(u8, path, "oauth/access_token")) {
        if (!std.mem.eql(u8, param(q, "client_secret"), secret)) return errBody(1, "bad secret");
        if (std.mem.eql(u8, param(q, "grant_type"), "fb_exchange_token")) {
            if (!std.mem.eql(u8, param(q, "fb_exchange_token"), "USERTOKSHORT")) return errBody(190, "bad token");
            return .{ .headers = hdr_c, .body = "{\"access_token\":\"" ++ user_long ++ "\",\"token_type\":\"bearer\"}" };
        }
        if (!std.mem.eql(u8, param(q, "code"), code)) return errBody(100, "bad code");
        return .{ .headers = hdr_c, .body = "{\"access_token\":\"USERTOKSHORT\",\"token_type\":\"bearer\"}" };
    }
    const tok = param(q, "access_token");
    const proof = param(q, "appsecret_proof");
    const want = graph.proofHex(secret, tok);
    if (!std.mem.eql(u8, proof, &want)) {
        _ = m.bad_proofs.fetchAdd(1, .acq_rel);
        return errBody(100, "appsecret_proof invalid");
    }
    if (std.mem.eql(u8, tok, "DEADTOK")) return errBody(190, "token expired");
    if (std.mem.eql(u8, tok, "BLOCKTOK")) return errBody(368, "temporarily blocked");
    if (std.mem.eql(u8, tok, "RATETOK")) return errBody(4, "too many calls");
    const ok_tok = std.mem.eql(u8, tok, page_tok) or std.mem.eql(u8, tok, user_long);
    if (!ok_tok) return errBody(190, "invalid token");
    if (std.mem.endsWith(u8, path, "/subscribed_apps")) return .{ .headers = hdr_c, .body = "{\"success\":true}" };
    for (edges) |e| {
        if (!std.mem.eql(u8, e.path, path)) continue;
        const start = std.fmt.parseInt(usize, param(q, "after"), 10) catch 0;
        const end = @min(start + m.per_page, e.items.len);
        var b: std.ArrayList(u8) = .empty;
        b.appendSlice(a, "{\"data\":[") catch return .{ .status = 500 };
        var i = start;
        while (i < end) : (i += 1) {
            if (i > start) b.append(a, ',') catch {};
            b.appendSlice(a, e.items[i]) catch {};
        }
        b.appendSlice(a, "]") catch {};
        if (end < e.items.len) b.print(a, ",\"paging\":{{\"cursors\":{{\"before\":\"0\",\"after\":\"{d}\"}},\"next\":\"https://graph.facebook.com/next\"}}", .{end}) catch {};
        b.appendSlice(a, "}") catch {};
        return .{ .headers = hdr_c, .body = b.items };
    }
    return errBody(803, "no such edge");
}

// shipped 00-config.json (paths, fields, kinds) for tests; callers override bases and caps
pub fn shipped(a: std.mem.Allocator) @import("co-cfg.zig").Config {
    var w: [160]u8 = undefined;
    var n: usize = 0;
    return @import("co-cfg.zig").load(a, std.testing.io, "00-config.json", &w, &n) catch unreachable;
}
