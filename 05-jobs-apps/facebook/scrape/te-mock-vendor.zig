// mock-vendor: fake scraping API. Routes /v/query /v/header /v/bearer /v/basic /v/body /v/json. Key = TESTKEY.
// Knobs: mode (ok|dead|limited|err|challenge), cost header value, page body.
const std = @import("std");
const Io = std.Io;
const ms = @import("te-mini-srv.zig");


pub const Mode = enum(u8) { ok, dead, limited, err, challenge };
pub const key = "TESTKEY";

pub const Vend = struct {
    mode: std.atomic.Value(u8) = .init(0),
    hits: std.atomic.Value(u32) = .init(0),
    cost: u32 = 0, // sent as x-cost when > 0
    page: []const u8 = "{}",
    last_target: [300]u8 = undefined,
    last_len: usize = 0,

    pub fn start(self: *Vend, io: Io) !*ms.Srv {
        return ms.Srv.start(io, handler, self);
    }
    pub fn setMode(self: *Vend, m: Mode) void {
        self.mode.store(@intFromEnum(m), .release);
    }
    pub fn target(self: *Vend) []const u8 {
        return self.last_target[0..self.last_len];
    }
};

fn pctDecode(out: []u8, s: []const u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < out.len) {
        if (s[i] == '%' and i + 2 < s.len + 0 and i + 2 <= s.len - 1) {
            out[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch '?';
            i += 3;
        } else {
            out[n] = s[i];
            i += 1;
        }
        n += 1;
    }
    return out[0..n];
}

fn queryParam(q: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return "";
}

fn handler(ctx: *anyopaque, a: std.mem.Allocator, req: ms.Request) ms.Reply {
    const v: *Vend = @ptrCast(@alignCast(ctx));
    _ = v.hits.fetchAdd(1, .acq_rel);
    const qi = std.mem.indexOfScalar(u8, req.path, '?');
    const path = if (qi) |i| req.path[0..i] else req.path;
    const q = if (qi) |i| req.path[i + 1 ..] else "";
    var tbuf: [300]u8 = undefined;
    var got_key: []const u8 = "";
    var target: []const u8 = "";
    if (std.mem.eql(u8, path, "/v/query")) {
        got_key = queryParam(q, "apikey");
        target = pctDecode(&tbuf, queryParam(q, "url"));
    } else if (std.mem.eql(u8, path, "/v/header") or std.mem.eql(u8, path, "/v/json")) {
        got_key = ms.headerOf(req.head, "x-api-key");
        target = pctDecode(&tbuf, queryParam(q, "url"));
    } else if (std.mem.eql(u8, path, "/v/bearer")) {
        const h = ms.headerOf(req.head, "authorization");
        got_key = if (std.mem.startsWith(u8, h, "Bearer ")) h[7..] else "";
        target = pctDecode(&tbuf, queryParam(q, "url"));
    } else if (std.mem.eql(u8, path, "/v/basic")) {
        const h = ms.headerOf(req.head, "authorization");
        if (std.mem.startsWith(u8, h, "Basic ")) {
            var dec: [64]u8 = undefined;
            const n = std.base64.standard.Decoder.calcSizeForSlice(h[6..]) catch 0;
            if (n <= dec.len) {
                std.base64.standard.Decoder.decode(dec[0..n], h[6..]) catch {};
                const raw = dec[0..n];
                got_key = raw[0 .. std.mem.indexOfScalar(u8, raw, ':') orelse raw.len];
                got_key = a.dupe(u8, got_key) catch "";
            }
        }
        target = pctDecode(&tbuf, queryParam(q, "url"));
    } else if (std.mem.eql(u8, path, "/v/body")) {
        const p = std.json.parseFromSliceLeaky(std.json.Value, a, req.body, .{}) catch return .{ .status = 400 };
        if (p.object.get("token")) |t| got_key = if (t == .string) t.string else "";
        if (p.object.get("url")) |t| target = if (t == .string) t.string else "";
    } else return .{ .status = 404 };
    const n = @min(target.len, v.last_target.len);
    @memcpy(v.last_target[0..n], target[0..n]);
    v.last_len = n;
    const mode: Mode = @enumFromInt(v.mode.load(.acquire));
    if (mode == .dead or !std.mem.eql(u8, got_key, key)) return .{ .status = 401, .body = "invalid key" };
    if (mode == .limited) return .{ .status = 429, .body = "slow down" };
    if (mode == .err) return .{ .status = 500, .body = "boom" };
    const hdr: []const u8 = if (v.cost > 0) std.fmt.allocPrint(a, "x-cost: {d}\r\n", .{v.cost}) catch "" else "";
    if (mode == .challenge) return .{ .headers = hdr, .body = "<html>Just a moment...<div class=\"g-recaptcha\"></div></html>" };
    if (std.mem.eql(u8, path, "/v/json")) {
        const j = std.json.Stringify.valueAlloc(a, .{ .data = .{ .html = v.page } }, .{}) catch return .{ .status = 500 };
        return .{ .headers = hdr, .body = j };
    }
    return .{ .headers = hdr, .body = v.page };
}
