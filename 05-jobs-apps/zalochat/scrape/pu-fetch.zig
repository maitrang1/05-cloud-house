// Polite GET session for one cust: guard -> robots (once) -> gap+jitter -> capped GET -> classify. Never follows redirects.
// A block or CAPTCHA stops the whole session (stop_on_block); we never solve or dodge one.
const std = @import("std");
const Io = std.Io;
const cfg_mod = @import("co-cfg.zig");
const util = @import("co-util.zig");
const guard = @import("pu-guard.zig");
const net = @import("pu-net.zig");
const robot = @import("pu-robot.zig");

pub const Outcome = union(enum) {
    ok: Page,
    not_found,
    robots_denied,
    blocked: []const u8, // reason; session stopped
    redirect: struct { status: u16, location: []const u8 },
    server_error: u16,
    too_big,
    encoded,
    timeout,
    net_fail,
    guard_refused: guard.GuardErr,
    cap_reached,
    stopped, // an earlier block stopped this session
};

pub const Page = struct { url: []const u8, status: u16, body: []const u8, fetched_ms: i64, content_type: []const u8 };

pub const Params = struct {
    io: Io,
    cfg: cfg_mod.Public,
    mock: bool = false,
    resolver: guard.Resolver = .{},
    max_pages: u32, // pages this session may fetch (daily cap minus used)
};

pub const Audit = *const fn (ctx: ?*anyopaque, url: []const u8, status: i64, note: []const u8) void;

const RobotsEntry = struct { rules: robot.Rules, at_ms: i64 };

pub const Session = struct {
    p: Params,
    arena: std.mem.Allocator, // session lifetime
    robots: std.StringHashMapUnmanaged(RobotsEntry) = .empty,
    last_ms: std.StringHashMapUnmanaged(i64) = .empty,
    pages: u32 = 0,
    stopped: bool = false,
    stop_reason: []const u8 = "",
    audit: ?Audit = null,
    audit_ctx: ?*anyopaque = null,
    fake_gap: bool = false, // tests: skip real sleeping
    guard_err: ?guard.GuardErr = null,

    pub fn init(arena: std.mem.Allocator, p: Params) Session {
        return .{ .p = p, .arena = arena };
    }

    fn note(self: *Session, url: []const u8, status: i64, why: []const u8) void {
        const f = self.audit orelse return;
        const red = guard.redactUrl(self.arena, url) catch return;
        f(self.audit_ctx, red, status, why);
    }

    fn gap(self: *Session, host: []const u8) void {
        if (self.fake_gap) return;
        const now = util.monoMs(self.p.io);
        var jit: u32 = 0;
        if (self.p.cfg.jitter_ms > 0) {
            var rb: [4]u8 = undefined;
            self.p.io.random(&rb);
            jit = std.mem.readInt(u32, &rb, .little) % (self.p.cfg.jitter_ms + 1);
        }
        if (self.last_ms.get(host)) |last| {
            const due = last + self.p.cfg.gap_ms + jit;
            if (due > now) util.sleepMs(self.p.io, due - now);
        }
    }

    fn touch(self: *Session, host: []const u8) void {
        self.last_ms.put(self.arena, host, util.monoMs(self.p.io)) catch {};
    }

    fn rawGet(self: *Session, t: guard.Target, path: []const u8, cap: usize) net.Err!net.Resp {
        const ip = guard.pin(self.p.io, self.p.resolver, t) catch |e| {
            self.guard_err = e;
            return net.Err.Connect;
        };
        var t2 = t;
        t2.path = path;
        return net.get(self.p.io, self.arena, t2, ip, .{ .ua = self.p.cfg.user_agent, .timeout_s = self.p.cfg.timeout_s, .cap_bytes = cap });
    }

    fn loadRobots(self: *Session, t: guard.Target) robot.Rules {
        const now = util.monoMs(self.p.io);
        if (self.robots.get(t.host)) |e| {
            if (now - e.at_ms < @as(i64, self.p.cfg.robots_ttl_s) * 1000) return e.rules;
        }
        self.gap(t.host);
        const resp = self.rawGet(t, "/robots.txt", @as(usize, self.p.cfg.robots_cap_kb) * 1024);
        self.touch(t.host);
        var rules: robot.Rules = .{ .deny_all = true };
        if (resp) |r| {
            if (robot.forStatus(r.status)) |fb| {
                rules = fb;
            } else if (r.status >= 200 and r.status < 300) {
                rules = robot.parse(self.arena, r.body, self.p.cfg.user_agent) catch .{ .deny_all = true };
            } else rules = .{ .deny_all = true }; // 3xx on robots: not followed, treat as unreachable
            self.note(t.host, r.status, "robots");
        } else |e| {
            // robots body over the cap = unreadable = deny; network fail = deny
            self.note(t.host, 0, @errorName(e));
        }
        self.robots.put(self.arena, t.host, .{ .rules = rules, .at_ms = now }) catch {};
        return rules;
    }

    // robots verdict for a url without fetching the page (used when only vendors are left)
    pub fn robotsAllows(self: *Session, url: []const u8) bool {
        const t = guard.parseUrl(self.arena, url, .{ .allow_hosts = self.p.cfg.allow_hosts, .mock = self.p.mock }) catch return false;
        return self.loadRobots(t).allows(t.path);
    }

    pub fn get(self: *Session, url: []const u8) Outcome {
        if (self.stopped) return .stopped;
        if (self.pages >= self.p.max_pages) return .cap_reached;
        const t = guard.parseUrl(self.arena, url, .{ .allow_hosts = self.p.cfg.allow_hosts, .mock = self.p.mock }) catch |e| {
            self.note(url, 0, @errorName(e));
            return .{ .guard_refused = e };
        };
        const rules = self.loadRobots(t);
        if (!rules.allows(pathOnly(t.path))) {
            self.note(url, 0, "robots_denied");
            return .robots_denied;
        }
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            self.gap(t.host);
            self.guard_err = null;
            const resp = self.rawGet(t, t.path, @as(usize, self.p.cfg.body_cap_kb) * 1024);
            self.touch(t.host);
            if (resp) |r| {
                self.pages += 1;
                self.note(url, r.status, "");
                return self.classify(url, r, attempt);
            } else |e| {
                self.note(url, 0, @errorName(e));
                if (self.guard_err) |g| return .{ .guard_refused = g };
                switch (e) {
                    error.TooBig => return .too_big,
                    error.Encoded => return .encoded,
                    error.Timeout => return .timeout,
                    else => {
                        if (attempt < self.p.cfg.retry_5xx) continue;
                        return .net_fail;
                    },
                }
            }
        }
    }

    fn classify(self: *Session, url: []const u8, r: net.Resp, attempt: u32) Outcome {
        if (r.status == 429 or r.status == 403 or r.cf_mitigated or (r.status == 503 and looksChallenge(r.body))) {
            return self.block(if (r.status == 429) "rate_limited" else if (r.status == 403) "forbidden" else "challenge_page");
        }
        if (r.status >= 300 and r.status < 400) return .{ .redirect = .{ .status = r.status, .location = r.location } };
        if (r.status == 404 or r.status == 410) return .not_found;
        if (r.status >= 500) {
            if (attempt < self.p.cfg.retry_5xx) {
                // honor a short Retry-After, else the normal gap applies on the next loop
                if (r.retry_after_s > 0 and r.retry_after_s <= 10 and !self.fake_gap) util.sleepMs(self.p.io, @as(i64, r.retry_after_s) * 1000);
                return self.retry(url);
            }
            return .{ .server_error = r.status };
        }
        if (r.status >= 200 and r.status < 300) {
            if (looksChallenge(r.body)) return self.block("challenge_page");
            return .{ .ok = .{ .url = url, .status = r.status, .body = r.body, .fetched_ms = util.nowMs(self.p.io), .content_type = r.content_type } };
        }
        return .{ .server_error = r.status };
    }

    fn retry(self: *Session, url: []const u8) Outcome {
        // one more pass through get() would re-run robots; call a lean second attempt
        self.pages -= 1;
        const saved = self.p.cfg.retry_5xx;
        self.p.cfg.retry_5xx = 0;
        defer self.p.cfg.retry_5xx = saved;
        return self.get(url);
    }

    fn block(self: *Session, why: []const u8) Outcome {
        if (self.p.cfg.stop_on_block) {
            self.stopped = true;
            self.stop_reason = why;
        }
        return .{ .blocked = why };
    }
};

fn pathOnly(p: []const u8) []const u8 {
    return p; // robots patterns match path + query
}

// markers of a bot wall / captcha. We detect and STOP; we never solve.
pub fn looksChallenge(body: []const u8) bool {
    const head = body[0..@min(body.len, 8192)];
    const marks = [_][]const u8{ "cf-challenge", "Just a moment...", "g-recaptcha", "h-captcha", "hcaptcha", "Attention Required! | Cloudflare", "captcha-delivery", "px-captcha", "/cdn-cgi/challenge-platform" };
    for (marks) |m| if (std.ascii.indexOfIgnoreCase(head, m) != null) return true;
    return false;
}

// ---- tests with the loopback mock-site ----
const ms = @import("te-mini-srv.zig");
const site = @import("te-mock-site.zig");

fn params(io: Io, max: u32) Params {
    return .{ .io = io, .mock = true, .max_pages = max, .cfg = .{ .user_agent = "zalochat-scrape/0.1 (test)", .allow_hosts = &.{}, .gap_ms = 1, .jitter_ms = 0, .timeout_s = 3, .body_cap_kb = 2, .daily_cap = 10, .robots_ttl_s = 60, .robots_cap_kb = 4, .stop_on_block = true, .retry_5xx = 1 } };
}

test "fetch: ok page, robots fetched once, UA sent" {
    var st = site.Site.init(std.testing.allocator);
    defer st.deinit();
    const srv = try st.start(std.testing.io);
    defer srv.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Session.init(arena.allocator(), params(std.testing.io, 10));
    s.fake_gap = true;
    var ub: [128]u8 = undefined;
    const o1 = s.get(srv.url(&ub, "/oa/ok"));
    try std.testing.expect(o1 == .ok);
    try std.testing.expect(std.mem.indexOf(u8, o1.ok.body, "og:title") != null);
    const o2 = s.get(srv.url(&ub, "/oa/ok"));
    try std.testing.expect(o2 == .ok);
    try std.testing.expectEqual(@as(u32, 1), st.hitsOf("/robots.txt"));
    try std.testing.expectEqual(@as(u32, 2), st.hitsOf("/oa/ok"));
    try std.testing.expect(std.mem.indexOf(u8, st.lastUa(), "zalochat-scrape") != null);
}

test "fetch: disallowed path never requested" {
    var st = site.Site.init(std.testing.allocator);
    defer st.deinit();
    const srv = try st.start(std.testing.io);
    defer srv.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Session.init(arena.allocator(), params(std.testing.io, 10));
    s.fake_gap = true;
    var ub: [128]u8 = undefined;
    try std.testing.expect(s.get(srv.url(&ub, "/private/x")) == .robots_denied);
    try std.testing.expectEqual(@as(u32, 0), st.hitsOf("/private/x"));
}

test "fetch: 404, redirect, 5xx retry, big, gzip, timeout" {
    var st = site.Site.init(std.testing.allocator);
    defer st.deinit();
    const srv = try st.start(std.testing.io);
    defer srv.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Session.init(arena.allocator(), params(std.testing.io, 50));
    s.fake_gap = true;
    var ub: [128]u8 = undefined;
    try std.testing.expect(s.get(srv.url(&ub, "/oa/missing")) == .not_found);
    const rd = s.get(srv.url(&ub, "/oa/redir"));
    try std.testing.expect(rd == .redirect and rd.redirect.status == 302);
    try std.testing.expectEqual(@as(u32, 0), st.hitsOf("/final")); // never followed
    const e5 = s.get(srv.url(&ub, "/oa/500"));
    try std.testing.expect(e5 == .server_error);
    try std.testing.expectEqual(@as(u32, 2), st.hitsOf("/oa/500")); // 1 try + 1 retry
    try std.testing.expect(s.get(srv.url(&ub, "/oa/big")) == .too_big);
    try std.testing.expect(s.get(srv.url(&ub, "/oa/gzip")) == .encoded);
    s.p.cfg.timeout_s = 1;
    try std.testing.expect(s.get(srv.url(&ub, "/oa/slow")) == .timeout);
}

test "fetch: a block stops the session; later calls make no request" {
    var st = site.Site.init(std.testing.allocator);
    defer st.deinit();
    const srv = try st.start(std.testing.io);
    defer srv.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Session.init(arena.allocator(), params(std.testing.io, 50));
    s.fake_gap = true;
    var ub: [128]u8 = undefined;
    const b = s.get(srv.url(&ub, "/oa/429"));
    try std.testing.expect(b == .blocked);
    try std.testing.expect(s.get(srv.url(&ub, "/oa/ok")) == .stopped);
    try std.testing.expectEqual(@as(u32, 0), st.hitsOf("/oa/ok"));
    // captcha page on 200 also blocks
    var s2 = Session.init(arena.allocator(), params(std.testing.io, 50));
    s2.fake_gap = true;
    try std.testing.expect(s2.get(srv.url(&ub, "/oa/challenge")) == .blocked);
    var s3 = Session.init(arena.allocator(), params(std.testing.io, 50));
    s3.fake_gap = true;
    try std.testing.expect(s3.get(srv.url(&ub, "/oa/403")) == .blocked);
}

test "fetch: daily cap and guard refusals" {
    var st = site.Site.init(std.testing.allocator);
    defer st.deinit();
    const srv = try st.start(std.testing.io);
    defer srv.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Session.init(arena.allocator(), params(std.testing.io, 1));
    s.fake_gap = true;
    var ub: [128]u8 = undefined;
    try std.testing.expect(s.get(srv.url(&ub, "/oa/ok")) == .ok);
    try std.testing.expect(s.get(srv.url(&ub, "/oa/ok")) == .cap_reached);
    var s2 = Session.init(arena.allocator(), params(std.testing.io, 5));
    s2.fake_gap = true;
    const g = s2.get("http://10.0.0.1/x");
    try std.testing.expect(g == .guard_refused);
}

test "fetch: robots 5xx denies everything; gap is honored" {
    var st = site.Site.init(std.testing.allocator);
    defer st.deinit();
    st.robots_status = 503;
    const srv = try st.start(std.testing.io);
    defer srv.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Session.init(arena.allocator(), params(std.testing.io, 5));
    s.fake_gap = true;
    var ub: [128]u8 = undefined;
    try std.testing.expect(s.get(srv.url(&ub, "/oa/ok")) == .robots_denied);
    try std.testing.expectEqual(@as(u32, 0), st.hitsOf("/oa/ok"));
    // gap: two real requests 150 ms apart
    var st2 = site.Site.init(std.testing.allocator);
    defer st2.deinit();
    const srv2 = try st2.start(std.testing.io);
    defer srv2.stop();
    var p = params(std.testing.io, 5);
    p.cfg.gap_ms = 150;
    var s2 = Session.init(arena.allocator(), p);
    const t0 = util.monoMs(std.testing.io);
    _ = s2.get(srv2.url(&ub, "/oa/ok"));
    _ = s2.get(srv2.url(&ub, "/oa/ok"));
    try std.testing.expect(util.monoMs(std.testing.io) - t0 >= 280); // robots + 2 pages = 3 requests, 2 gaps
}
