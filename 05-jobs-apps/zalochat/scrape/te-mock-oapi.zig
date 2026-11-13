// mock-oapi: fake Zalo OA API + OAuth. App secret = APPSECRET, good auth code = GOODCODE.
// Knobs: followers count, expire_now() (access token dies -> -216), refresh_dead, quota_stop.
const std = @import("std");
const Io = std.Io;
const ms = @import("te-mini-srv.zig");

pub const Oapi = struct {
    mu: std.atomic.Value(bool) = .init(false),
    gen: u32 = 1, // current token generation
    access_ok: bool = true,
    refresh_dead: bool = false,
    quota_stop: bool = false,
    followers: u32 = 120,
    msgs_per_chat: u32 = 25,
    calls: u32 = 0,
    refreshes: u32 = 0,
    profile_calls: u32 = 0,
    code_used: bool = false,
    last_verifier: [64]u8 = undefined,
    last_verifier_len: usize = 0,

    pub fn start(self: *Oapi, io: Io) !*ms.Srv {
        return ms.Srv.start(io, handler, self);
    }
    fn lock(self: *Oapi) void {
        while (self.mu.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Oapi) void {
        self.mu.store(false, .release);
    }
    pub fn expireNow(self: *Oapi) void {
        self.lock();
        defer self.unlock();
        self.access_ok = false;
    }
    pub fn accessToken(self: *Oapi, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "ACCESS-{d}", .{self.gen}) catch "";
    }
    pub fn refreshToken(self: *Oapi, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "REFRESH-{d}", .{self.gen}) catch "";
    }
};

fn formGet(body: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return "";
}

fn pctDec(a: std.mem.Allocator, s: []const u8) []const u8 {
    var o: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len + 1 and i + 2 <= s.len - 1 + 0) {
            o.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch '?') catch return "";
            i += 3;
        } else {
            o.append(a, s[i]) catch return "";
            i += 1;
        }
    }
    return o.items;
}

fn tokenReply(a: std.mem.Allocator, o: *Oapi) ms.Reply {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const body = std.fmt.allocPrint(a, "{{\"access_token\":\"{s}\",\"refresh_token\":\"{s}\",\"expires_in\":\"90000\"}}", .{ o.accessToken(&b1), o.refreshToken(&b2) }) catch return .{ .status = 500 };
    return .{ .body = body, .headers = "Content-Type: application/json\r\n" };
}

fn handler(ctx: *anyopaque, a: std.mem.Allocator, req: ms.Request) ms.Reply {
    const o: *Oapi = @ptrCast(@alignCast(ctx));
    o.lock();
    defer o.unlock();
    o.calls += 1;
    const qi = std.mem.indexOfScalar(u8, req.path, '?');
    const path = if (qi) |i| req.path[0..i] else req.path;
    const q = if (qi) |i| req.path[i + 1 ..] else "";
    const json_h = "Content-Type: application/json\r\n";
    if (std.mem.eql(u8, path, "/v4/oa/access_token")) {
        if (!std.mem.eql(u8, ms.headerOf(req.head, "secret_key"), "APPSECRET")) return .{ .body = "{\"error\":-101,\"error_name\":\"invalid secret\"}", .headers = json_h };
        const grant = formGet(req.body, "grant_type");
        if (std.mem.eql(u8, grant, "authorization_code")) {
            if (!std.mem.eql(u8, formGet(req.body, "code"), "GOODCODE") or o.code_used) return .{ .body = "{\"error\":-118,\"error_name\":\"invalid code\"}", .headers = json_h };
            const v = formGet(req.body, "code_verifier");
            o.last_verifier_len = @min(v.len, o.last_verifier.len);
            @memcpy(o.last_verifier[0..o.last_verifier_len], v[0..o.last_verifier_len]);
            if (v.len == 0) return .{ .body = "{\"error\":-118,\"error_name\":\"no verifier\"}", .headers = json_h };
            o.code_used = true;
            o.access_ok = true;
            return tokenReply(a, o);
        }
        var rb: [32]u8 = undefined;
        if (o.refresh_dead or !std.mem.eql(u8, formGet(req.body, "refresh_token"), o.refreshToken(&rb))) return .{ .body = "{\"error\":-118,\"error_name\":\"refresh token invalid or used\"}", .headers = json_h };
        o.gen += 1; // single use: old refresh token is now dead
        o.refreshes += 1;
        o.access_ok = true;
        return tokenReply(a, o);
    }
    var ab: [32]u8 = undefined;
    const want = o.accessToken(&ab);
    if (!o.access_ok or !std.mem.eql(u8, ms.headerOf(req.head, "access_token"), want)) return .{ .body = "{\"error\":-216,\"message\":\"Access token is invalid\"}", .headers = json_h };
    // data={json}
    const data_enc = formGet(q, "data");
    const data = pctDec(a, data_enc);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, if (data.len > 0) data else "{}", .{}) catch return .{ .body = "{\"error\":-201,\"message\":\"bad data\"}", .headers = json_h };
    const off: u32 = if (parsed == .object) (if (parsed.object.get("offset")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0) else 0;
    const cnt: u32 = if (parsed == .object) (if (parsed.object.get("count")) |v| (if (v == .integer) @intCast(v.integer) else 10) else 10) else 10;
    if (std.mem.eql(u8, path, "/v2.0/oa/getoa")) return .{ .body = "{\"error\":0,\"message\":\"Success\",\"data\":{\"oa_id\":\"4242\",\"name\":\"Test OA\",\"description\":\"demo\",\"avatar\":\"https://img.example/oa.png\"}}", .headers = json_h };
    if (std.mem.eql(u8, path, "/v2.0/oa/quota/message")) {
        if (o.quota_stop) return .{ .body = "{\"error\":-223,\"message\":\"quota exceeded\"}", .headers = json_h };
        return .{ .body = "{\"error\":0,\"data\":{\"daily\":1000,\"used\":3}}", .headers = json_h };
    }
    if (std.mem.eql(u8, path, "/v2.0/oa/getfollowers")) {
        if (o.quota_stop) return .{ .body = "{\"error\":-223,\"message\":\"quota exceeded\"}", .headers = json_h };
        var l: std.ArrayList(u8) = .empty;
        l.print(a, "{{\"error\":0,\"data\":{{\"total\":{d},\"followers\":[", .{o.followers}) catch return .{ .status = 500 };
        var i = off;
        var first = true;
        while (i < o.followers and i < off + cnt) : (i += 1) {
            if (!first) l.append(a, ',') catch {};
            first = false;
            l.print(a, "{{\"user_id\":\"u{d}\"}}", .{i + 1}) catch {};
        }
        l.appendSlice(a, "]}}") catch {};
        return .{ .body = l.items, .headers = json_h };
    }
    if (std.mem.eql(u8, path, "/v2.0/oa/getprofile")) {
        o.profile_calls += 1;
        const uid = if (parsed == .object) (if (parsed.object.get("user_id")) |v| (if (v == .string) v.string else "") else "") else "";
        return .{ .body = std.fmt.allocPrint(a, "{{\"error\":0,\"data\":{{\"user_id\":\"{s}\",\"display_name\":\"User {s}\",\"avatar\":\"https://img.example/{s}.png\"}}}}", .{ uid, uid, uid }) catch "", .headers = json_h };
    }
    if (std.mem.eql(u8, path, "/v2.0/oa/listrecentchat") or std.mem.eql(u8, path, "/v2.0/oa/conversation")) {
        const total = o.msgs_per_chat;
        var l: std.ArrayList(u8) = .empty;
        l.appendSlice(a, "{\"error\":0,\"data\":[") catch {};
        var i = off;
        var first = true;
        while (i < total and i < off + cnt) : (i += 1) {
            if (!first) l.append(a, ',') catch {};
            first = false;
            l.print(a, "{{\"message_id\":\"m{d}\",\"from_id\":\"u1\",\"to_id\":\"4242\",\"type\":\"text\",\"message\":\"hello {d}\",\"time\":{d}}}", .{ i + 1, i + 1, 1780000000000 + @as(u64, i) * 1000 }) catch {};
        }
        l.appendSlice(a, "]}") catch {};
        return .{ .body = l.items, .headers = json_h };
    }
    if (std.mem.eql(u8, path, "/v2.0/article/getslice")) {
        var l: std.ArrayList(u8) = .empty;
        l.appendSlice(a, "{\"error\":0,\"data\":{\"total\":3,\"medias\":[") catch {};
        var i = off;
        var first = true;
        while (i < 3 and i < off + cnt) : (i += 1) {
            if (!first) l.append(a, ',') catch {};
            first = false;
            l.print(a, "{{\"id\":\"a{d}\",\"title\":\"Article {d}\",\"status\":\"show\",\"thumb\":\"https://img.example/a{d}.png\"}}", .{ i + 1, i + 1, i + 1 }) catch {};
        }
        l.appendSlice(a, "]}}") catch {};
        return .{ .body = l.items, .headers = json_h };
    }
    return .{ .status = 404 };
}
