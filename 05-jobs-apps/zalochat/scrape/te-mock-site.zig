// mock-site: fake public OA site. Paths: /oa/ok · /oa/missing(404) · /oa/redir · /oa/500 · /oa/429 · /oa/403 · /oa/challenge · /oa/gzip · /oa/big · /oa/slow · /private/* (robots-disallowed)
const std = @import("std");
const Io = std.Io;
const ms = @import("te-mini-srv.zig");

pub const ok_html =
    \\<html><head><title>Cua Hang Mau</title>
    \\<meta property="og:title" content="Cua Hang Mau"/>
    \\<meta property="og:description" content="Ban hang online &amp; giao nhanh"/>
    \\<meta property="og:image" content="https://img.example/a.jpg"/>
    \\<meta property="og:url" content="https://zalo.me/cuahangmau"/>
    \\</head><body><h1>Cua Hang Mau</h1><p>Lien he Zalo</p></body></html>
;

pub const Site = struct {
    gpa: std.mem.Allocator,
    mu: std.atomic.Value(bool) = .init(false),
    paths: std.ArrayList([]u8) = .empty,
    ua: [200]u8 = undefined,
    ua_len: usize = 0,
    robots: []const u8 = "User-agent: Googlebot\nDisallow: /private\n\nUser-agent: *\nDisallow: /private\n",
    robots_status: u16 = 200,

    pub fn init(gpa: std.mem.Allocator) Site {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Site) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.deinit(self.gpa);
    }
    pub fn start(self: *Site, io: Io) !*ms.Srv {
        return ms.Srv.start(io, handler, self);
    }
    fn lock(self: *Site) void {
        while (self.mu.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Site) void {
        self.mu.store(false, .release);
    }
    pub fn hitsOf(self: *Site, path: []const u8) u32 {
        self.lock();
        defer self.unlock();
        var n: u32 = 0;
        for (self.paths.items) |p| {
            const q = std.mem.indexOfScalar(u8, p, '?') orelse p.len;
            if (std.mem.eql(u8, p[0..q], path)) n += 1;
        }
        return n;
    }
    pub fn lastUa(self: *Site) []const u8 {
        return self.ua[0..self.ua_len];
    }
    pub fn total(self: *Site) usize {
        self.lock();
        defer self.unlock();
        return self.paths.items.len;
    }
};

fn handler(ctx: *anyopaque, a: std.mem.Allocator, req: ms.Request) ms.Reply {
    _ = a;
    const s: *Site = @ptrCast(@alignCast(ctx));
    s.lock();
    if (s.gpa.dupe(u8, req.path)) |d| s.paths.append(s.gpa, d) catch s.gpa.free(d) else |_| {}
    const ua = ms.headerOf(req.head, "user-agent");
    s.ua_len = @min(ua.len, s.ua.len);
    @memcpy(s.ua[0..s.ua_len], ua[0..s.ua_len]);
    s.unlock();
    const p = req.path;
    const eq = std.mem.eql;
    if (eq(u8, p, "/robots.txt")) return .{ .status = s.robots_status, .body = if (s.robots_status == 200) s.robots else "" };
    if (eq(u8, p, "/oa/ok")) return .{ .body = ok_html, .headers = "Content-Type: text/html; charset=utf-8\r\n" };
    if (eq(u8, p, "/oa/other")) return .{ .body = "<html><head><title>Other</title><meta property=\"og:title\" content=\"Other Shop\"/></head><body><h1>Other</h1></body></html>", .headers = "Content-Type: text/html\r\n" };
    if (eq(u8, p, "/oa/redir")) return .{ .status = 302, .headers = "Location: /final\r\n" };
    if (eq(u8, p, "/oa/500")) return .{ .status = 500, .body = "boom" };
    if (eq(u8, p, "/oa/429")) return .{ .status = 429, .headers = "Retry-After: 120\r\n" };
    if (eq(u8, p, "/oa/403")) return .{ .status = 403, .body = "no" };
    if (eq(u8, p, "/oa/challenge")) return .{ .body = "<html><title>Just a moment...</title><div class=\"g-recaptcha\"></div></html>" };
    if (eq(u8, p, "/oa/gzip")) return .{ .headers = "Content-Encoding: gzip\r\n", .body = "\x1f\x8b\x08\x00bomb" };
    if (eq(u8, p, "/oa/big")) return .{ .body = "y" ** 5000 };
    if (eq(u8, p, "/oa/slow")) return .{ .delay_ms = 4000, .body = "late" };
    if (std.mem.startsWith(u8, p, "/private")) return .{ .body = "secret" };
    return .{ .status = 404 };
}
