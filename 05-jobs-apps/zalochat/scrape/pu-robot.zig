// robots.txt (RFC 9309 subset): pick the group for our UA token (else *), longest matching rule wins, Allow wins ties.
const std = @import("std");

pub const Rule = struct { allow: bool, pat: []const u8 };
pub const Rules = struct {
    rules: []const Rule = &.{},
    // 4xx robots = no rules (allow all); 5xx/unreachable = deny all
    deny_all: bool = false,

    pub fn allows(self: Rules, path: []const u8) bool {
        if (self.deny_all) return false;
        var best: ?Rule = null;
        for (self.rules) |r| {
            if (r.pat.len == 0) continue; // empty Disallow = allow all
            if (!match(r.pat, path)) continue;
            if (best == null or r.pat.len > best.?.pat.len or (r.pat.len == best.?.pat.len and r.allow)) best = r;
        }
        return if (best) |b| b.allow else true;
    }
};

// iterative wildcard match: `*` any run, `$` end anchor; pattern is a prefix match otherwise. O(len(p)*len(s)).
pub fn match(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (true) {
        if (p < pat.len and pat[p] == '$' and p + 1 == pat.len) return i == s.len;
        if (p == pat.len) return true; // prefix matched
        if (pat[p] == '*') {
            star = p;
            p += 1;
            mark = i;
            continue;
        }
        if (i < s.len and pat[p] == s[i]) {
            p += 1;
            i += 1;
            continue;
        }
        if (star) |st| {
            mark += 1;
            if (mark > s.len) return false;
            p = st + 1;
            i = mark;
            continue;
        }
        return false;
    }
}

fn tokenOf(ua: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, ua, "/ (") orelse ua.len;
    return ua[0..end];
}

pub fn parse(arena: std.mem.Allocator, text: []const u8, ua: []const u8) !Rules {
    const token = tokenOf(ua);
    var named: std.ArrayList(Rule) = .empty;
    var star: std.ArrayList(Rule) = .empty;
    var have_named = false;
    var in_named = false;
    var in_star = false;
    var in_agents = false; // previous lines were User-agent lines
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOfScalar(u8, line, '#')) |h| line = std.mem.trim(u8, line[0..h], " \t");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
            if (!in_agents) {
                in_named = false;
                in_star = false;
            }
            in_agents = true;
            if (std.ascii.eqlIgnoreCase(val, "*")) in_star = true else if (token.len > 0 and std.ascii.indexOfIgnoreCase(val, token) != null and val.len >= token.len and std.ascii.eqlIgnoreCase(val, token)) {
                in_named = true;
                have_named = true;
            }
            continue;
        }
        in_agents = false;
        const allow = std.ascii.eqlIgnoreCase(key, "allow");
        if (!allow and !std.ascii.eqlIgnoreCase(key, "disallow")) continue;
        const r = Rule{ .allow = allow, .pat = try arena.dupe(u8, val) };
        if (in_named) try named.append(arena, r);
        if (in_star) try star.append(arena, r);
    }
    return .{ .rules = if (have_named) named.items else star.items };
}

// status-based fallback: 2xx parse · 4xx allow all · 5xx / network fail deny all
pub fn forStatus(status: u16) ?Rules {
    if (status >= 400 and status < 500) return .{};
    if (status >= 500) return .{ .deny_all = true };
    return null;
}

test "wildcards and anchors" {
    try std.testing.expect(match("/a", "/abc"));
    try std.testing.expect(!match("/a", "/b"));
    try std.testing.expect(match("/*.pdf$", "/x/y.pdf"));
    try std.testing.expect(!match("/*.pdf$", "/x/y.pdf?z"));
    try std.testing.expect(match("/*a*a*a*b", "/aaaab"));
    try std.testing.expect(match("/", "/anything"));
    try std.testing.expect(!match("/fish$", "/fish/x"));
}

test "wildcard is not exponential" {
    const s = "/" ++ "a" ** 5000;
    try std.testing.expect(!match("/*a*a*a*a*a*a*a*a*a*a*b", s));
}

test "group choice: named beats *, only-Googlebot means allowed for us" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zalo = "User-agent: Googlebot\nDisallow: /private\n";
    const r1 = try parse(a, zalo, "zalochat-scrape/0.1 (x)");
    try std.testing.expect(r1.allows("/private/x"));
    const both = "User-agent: *\nDisallow: /\n\nUser-agent: zalochat-scrape\nAllow: /pub\nDisallow: /\n";
    const r2 = try parse(a, both, "zalochat-scrape/0.1");
    try std.testing.expect(r2.allows("/pub/1"));
    try std.testing.expect(!r2.allows("/other"));
    const star = "User-agent: *\nDisallow: /secret\nAllow: /secret/open\n";
    const r3 = try parse(a, star, "zalochat-scrape/0.1");
    try std.testing.expect(!r3.allows("/secret/x"));
    try std.testing.expect(r3.allows("/secret/open/1"));
    try std.testing.expect(r3.allows("/x"));
    const empty = try parse(a, "User-agent: *\nDisallow:\n", "z");
    try std.testing.expect(empty.allows("/anything"));
}

test "status fallback" {
    try std.testing.expect(forStatus(404).?.allows("/x"));
    try std.testing.expect(!forStatus(503).?.allows("/x"));
    try std.testing.expect(forStatus(200) == null);
}
