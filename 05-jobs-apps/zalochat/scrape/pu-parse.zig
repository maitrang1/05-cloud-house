// Hostile-HTML reader for public Zalo pages: one linear pass, no DOM, so no recursion and no blowup.
// Output is a flat Meta (title, og:*, description, canonical, h1, visible text). Same page -> same bytes -> same hash.
const std = @import("std");
const shape = @import("rw-shape.zig");

pub const Meta = struct {
    url: []const u8,
    page: []const u8, // oa_page | group_page
    title: []const u8 = "",
    og_title: []const u8 = "",
    description: []const u8 = "",
    image: []const u8 = "",
    og_url: []const u8 = "",
    canonical: []const u8 = "",
    h1: []const u8 = "",
    lang: []const u8 = "",
    text: []const u8 = "",
};

pub const Limits = struct { text_cap: usize = 4000, field_cap: usize = 500, tag_cap: usize = 8192 };

pub fn kindOf(url: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse return "oa_page";
    const rest = url[i + 3 ..];
    const sl = std.mem.indexOfScalar(u8, rest, '/') orelse return "oa_page";
    return if (std.mem.startsWith(u8, rest[sl..], "/g/")) "group_page" else "oa_page";
}

// ---- entities + utf8 ----
fn appendCp(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u21) !void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch {
        try out.appendSlice(a, "\xef\xbf\xbd");
        return;
    };
    try out.appendSlice(a, b[0..n]);
}

fn decodeInto(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, s, i, ';');
            if (semi != null and semi.? - i <= 10) {
                const name = s[i + 1 .. semi.?];
                var done = true;
                if (std.mem.eql(u8, name, "amp")) try out.append(a, '&') else if (std.mem.eql(u8, name, "lt")) try out.append(a, '<') else if (std.mem.eql(u8, name, "gt")) try out.append(a, '>') else if (std.mem.eql(u8, name, "quot")) try out.append(a, '"') else if (std.mem.eql(u8, name, "apos")) try out.append(a, '\'') else if (std.mem.eql(u8, name, "nbsp")) try out.append(a, ' ') else if (name.len > 1 and name[0] == '#') {
                    const cp: ?u21 = blk: {
                        const v = if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u32, name[2..], 16) catch break :blk null else std.fmt.parseInt(u32, name[1..], 10) catch break :blk null;
                        if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) break :blk null;
                        break :blk @intCast(v);
                    };
                    if (cp) |c| try appendCp(out, a, c) else try out.appendSlice(a, "\xef\xbf\xbd");
                } else done = false;
                if (done) {
                    i = semi.? + 1;
                    continue;
                }
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
}

// replace invalid UTF-8 with U+FFFD, drop control chars except \n \t
fn clean(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.appendSlice(a, "\xef\xbf\xbd");
            i += 1;
            continue;
        };
        if (i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try out.appendSlice(a, "\xef\xbf\xbd");
            i += 1;
            continue;
        }
        if (n == 1 and s[i] < 0x20 and s[i] != '\n' and s[i] != '\t') {
            i += 1;
            continue;
        }
        try out.appendSlice(a, s[i .. i + n]);
        i += n;
    }
}

// decode + clean + trim + cut at cap (on a char boundary)
fn tidy(a: std.mem.Allocator, raw: []const u8, cap: usize) ![]const u8 {
    var d: std.ArrayList(u8) = .empty;
    try decodeInto(&d, a, raw);
    var c: std.ArrayList(u8) = .empty;
    try clean(&c, a, d.items);
    // collapse whitespace
    var o: std.ArrayList(u8) = .empty;
    var sp = true;
    for (c.items) |ch| {
        if (ch == ' ' or ch == '\n' or ch == '\t') {
            if (!sp) try o.append(a, ' ');
            sp = true;
        } else {
            try o.append(a, ch);
            sp = false;
        }
    }
    var s = std.mem.trimEnd(u8, o.items, " ");
    if (s.len > cap) {
        var e = cap;
        while (e > 0 and (s[e] & 0xC0) == 0x80) e -= 1;
        s = s[0..e];
    }
    return s;
}

const Tag = struct { name: []const u8, attrs: []const u8, closing: bool, end: usize };

// result of trying to read a tag: a tag, not a tag (1 char of text), or an unterminated one (skip the scanned window: keeps total work linear)
const TagTry = union(enum) { tag: Tag, text, skip: usize };

// parse the tag at s[i]=='<'; null = not a tag (treat '<' as text)
fn readTag(s: []const u8, i: usize, cap: usize) TagTry {
    var j = i + 1;
    var closing = false;
    if (j < s.len and s[j] == '/') {
        closing = true;
        j += 1;
    }
    const ns = j;
    while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '-' or s[j] == ':')) j += 1;
    if (j == ns) return .text;
    const name = s[ns..j];
    const as = j;
    var q: u8 = 0;
    while (j < s.len) : (j += 1) {
        if (j - i > cap) return .{ .skip = j - i };
        const c = s[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else if (c == '"' or c == '\'') q = c else if (c == '>') {
            return .{ .tag = .{ .name = name, .attrs = s[as..j], .closing = closing, .end = j + 1 } };
        }
    }
    return .{ .skip = j - i };
}

fn attrOf(attrs: []const u8, want: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and (std.ascii.isWhitespace(attrs[i]) or attrs[i] == '/')) i += 1;
        const ns = i;
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '=' and attrs[i] != '/') i += 1;
        const name = attrs[ns..i];
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        var val: []const u8 = "";
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
            if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
                const q = attrs[i];
                i += 1;
                const vs = i;
                while (i < attrs.len and attrs[i] != q) i += 1;
                val = attrs[vs..i];
                if (i < attrs.len) i += 1;
            } else {
                const vs = i;
                while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) i += 1;
                val = attrs[vs..i];
            }
        }
        if (name.len > 0 and std.ascii.eqlIgnoreCase(name, want)) return val;
    }
    return null;
}

fn skipUntil(s: []const u8, from: usize, needle: []const u8) usize {
    return if (std.ascii.indexOfIgnoreCasePos(s, from, needle)) |p| p + needle.len else s.len;
}

fn isBlock(name: []const u8) bool {
    const b = [_][]const u8{ "p", "div", "br", "li", "ul", "ol", "tr", "td", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer", "title", "table" };
    for (b) |x| if (std.ascii.eqlIgnoreCase(name, x)) return true;
    return false;
}

pub fn parse(a: std.mem.Allocator, url: []const u8, html: []const u8, lim: Limits) !Meta {
    var m = Meta{ .url = url, .page = kindOf(url) };
    var text: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_title = false;
    var in_h1 = false;
    var title_buf: std.ArrayList(u8) = .empty;
    var h1_buf: std.ArrayList(u8) = .empty;
    var seen_h1 = false;
    // raw text budget: stop collecting once far past the cap (entities/spaces shrink it)
    const raw_cap = lim.text_cap * 4 + 1024;
    while (i < html.len) {
        if (html[i] != '<') {
            const nx = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            const seg = html[i..nx];
            if (in_title and title_buf.items.len < lim.field_cap * 4) try title_buf.appendSlice(a, seg);
            if (in_h1 and h1_buf.items.len < lim.field_cap * 4) try h1_buf.appendSlice(a, seg);
            if (text.items.len < raw_cap) try text.appendSlice(a, seg[0..@min(seg.len, raw_cap - text.items.len)]);
            i = nx;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            i = skipUntil(html, i + 4, "-->");
            continue;
        }
        if (i + 1 < html.len and (html[i + 1] == '!' or html[i + 1] == '?')) {
            i = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            if (i < html.len) i += 1;
            continue;
        }
        const tag = switch (readTag(html, i, lim.tag_cap)) {
            .tag => |t| t,
            .text => {
                if (text.items.len < raw_cap) try text.append(a, '<');
                i += 1;
                continue;
            },
            .skip => |n| {
                i += @max(n, 1); // unterminated tag soup: drop the window we already scanned
                continue;
            },
        };
        i = tag.end;
        const nm = tag.name;
        if (!tag.closing and (std.ascii.eqlIgnoreCase(nm, "script") or std.ascii.eqlIgnoreCase(nm, "style") or std.ascii.eqlIgnoreCase(nm, "noscript") or std.ascii.eqlIgnoreCase(nm, "template") or std.ascii.eqlIgnoreCase(nm, "svg"))) {
            const close = if (std.ascii.eqlIgnoreCase(nm, "script")) "</script" else if (std.ascii.eqlIgnoreCase(nm, "style")) "</style" else if (std.ascii.eqlIgnoreCase(nm, "noscript")) "</noscript" else if (std.ascii.eqlIgnoreCase(nm, "svg")) "</svg" else "</template";
            i = skipUntil(html, i, close);
            i = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            if (i < html.len) i += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(nm, "html") and !tag.closing) {
            if (attrOf(tag.attrs, "lang")) |l| m.lang = try tidy(a, l, 16);
        } else if (std.ascii.eqlIgnoreCase(nm, "title")) {
            in_title = !tag.closing and m.title.len == 0;
            if (tag.closing) m.title = try tidy(a, title_buf.items, lim.field_cap);
            if (tag.closing) title_buf.clearRetainingCapacity();
        } else if (std.ascii.eqlIgnoreCase(nm, "h1")) {
            if (!tag.closing and !seen_h1) {
                in_h1 = true;
            } else if (tag.closing and in_h1) {
                in_h1 = false;
                seen_h1 = true;
                m.h1 = try tidy(a, h1_buf.items, lim.field_cap);
            }
        } else if (std.ascii.eqlIgnoreCase(nm, "meta") and !tag.closing) {
            const content = attrOf(tag.attrs, "content") orelse "";
            const key = attrOf(tag.attrs, "property") orelse attrOf(tag.attrs, "name") orelse "";
            if (std.ascii.eqlIgnoreCase(key, "og:title") and m.og_title.len == 0) m.og_title = try tidy(a, content, lim.field_cap) else if (std.ascii.eqlIgnoreCase(key, "og:description") or std.ascii.eqlIgnoreCase(key, "description")) {
                if (m.description.len == 0 or std.ascii.eqlIgnoreCase(key, "og:description")) m.description = try tidy(a, content, lim.field_cap);
            } else if (std.ascii.eqlIgnoreCase(key, "og:image") and m.image.len == 0) m.image = try tidy(a, content, lim.field_cap) else if (std.ascii.eqlIgnoreCase(key, "og:url") and m.og_url.len == 0) m.og_url = try tidy(a, content, lim.field_cap);
        } else if (std.ascii.eqlIgnoreCase(nm, "link") and !tag.closing) {
            const rel = attrOf(tag.attrs, "rel") orelse "";
            if (std.ascii.eqlIgnoreCase(rel, "canonical") and m.canonical.len == 0) m.canonical = try tidy(a, attrOf(tag.attrs, "href") orelse "", lim.field_cap);
        }
        if (isBlock(nm) and text.items.len < raw_cap) try text.append(a, ' ');
    }
    if (m.title.len == 0 and title_buf.items.len > 0) m.title = try tidy(a, title_buf.items, lim.field_cap);
    m.text = try tidy(a, text.items, lim.text_cap);
    return m;
}

// Meta -> row data Value (typed struct -> json text -> Value; key order is fixed, so the hash is stable)
pub fn toData(a: std.mem.Allocator, m: Meta) !std.json.Value {
    const t = try std.json.Stringify.valueAlloc(a, m, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, a, t, .{ .allocate = .alloc_always });
}

pub fn toRow(a: std.mem.Allocator, cust: []const u8, m: Meta, fetched_ms: i64) !shape.Row {
    return shape.makeRow(a, cust, .public, m.url, m.page, fetched_ms, try toData(a, m));
}

// ---- tests ----
const site = @import("te-mock-site.zig");

test "fixture: oa page meta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), "https://zalo.me/cuahangmau", site.ok_html, .{});
    try std.testing.expectEqualStrings("oa_page", m.page);
    try std.testing.expectEqualStrings("Cua Hang Mau", m.og_title);
    try std.testing.expectEqualStrings("Ban hang online & giao nhanh", m.description);
    try std.testing.expectEqualStrings("https://img.example/a.jpg", m.image);
    try std.testing.expectEqualStrings("Cua Hang Mau", m.h1);
    try std.testing.expect(std.mem.indexOf(u8, m.text, "Lien he Zalo") != null);
    try std.testing.expectEqualStrings("group_page", kindOf("https://zalo.me/g/abc123"));
}

test "fixture: same page twice gives identical rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try toRow(a, "demo", try parse(a, "https://zalo.me/x", site.ok_html, .{}), 1);
    const r2 = try toRow(a, "demo", try parse(a, "https://zalo.me/x", site.ok_html, .{}), 999);
    try std.testing.expectEqualStrings(r1.hash, r2.hash);
}

test "hostile: scripts, comments, unterminated, entities, bad utf8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = "<html lang=\"vi\"><!-- <h1>hidden</h1> --><script>var x='<h1>no</h1>';</script><style>p{}</style>" ++
        "<title>T &#x1F600; &amp; &bogus; \xff\xfe</title><h1>Real &lt;b&gt;</h1><p>a &#0; &#xD800; &#99999999; b</p><div <broken";
    const m = try parse(a, "https://zalo.me/x", html, .{});
    try std.testing.expectEqualStrings("vi", m.lang);
    try std.testing.expectEqualStrings("Real <b>", m.h1);
    try std.testing.expect(std.mem.indexOf(u8, m.text, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, m.text, "no") == null or std.mem.indexOf(u8, m.text, "<h1>no") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(m.title));
    try std.testing.expect(std.unicode.utf8ValidateSlice(m.text));
    try std.testing.expect(std.mem.indexOf(u8, m.title, "\u{1F600}") != null);
    _ = try toData(a, m); // must serialize
}

test "hostile: 100k nested tags and 1MB of junk stay bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = try a.alloc(u8, 100_000 * 5);
    for (0..100_000) |k| @memcpy(deep[k * 5 ..][0..5], "<div>");
    const m = try parse(a, "https://zalo.me/x", deep, .{});
    try std.testing.expect(m.text.len <= 4000);
    const junk = try a.alloc(u8, 1 << 20);
    @memset(junk, '<');
    const m2 = try parse(a, "https://zalo.me/x", junk, .{});
    try std.testing.expect(m2.text.len <= 4000);
    const lt = try a.alloc(u8, 1 << 20);
    @memset(lt, 'a');
    lt[0] = '<';
    const m3 = try parse(a, "https://zalo.me/x", lt, .{});
    try std.testing.expect(m3.text.len <= 4000);
}

test "hostile: unterminated tag soup is linear time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = 1 << 20;
    const soup = try a.alloc(u8, n);
    for (soup, 0..) |*c, k| c.* = "<a "[k % 3];
    const t0 = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const m = try parse(a, "https://zalo.me/x", soup, .{});
    const dt = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - t0;
    try std.testing.expect(m.text.len <= 4000);
    try std.testing.expect(dt < 2000);
}

test "fuzz: mutated fixtures never crash and stay valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const base = site.ok_html;
    var k: usize = 0;
    while (k < 1500) : (k += 1) {
        var buf: [1024]u8 = undefined;
        const n = base.len;
        @memcpy(buf[0..n], base);
        const edits = rnd.intRangeAtMost(usize, 1, 12);
        for (0..edits) |_| buf[rnd.uintLessThan(usize, n)] = rnd.int(u8);
        const cut = rnd.intRangeAtMost(usize, n / 2, n);
        const m = try parse(arena.allocator(), "https://zalo.me/x", buf[0..cut], .{});
        try std.testing.expect(std.unicode.utf8ValidateSlice(m.text));
        try std.testing.expect(std.unicode.utf8ValidateSlice(m.title));
        try std.testing.expect(m.text.len <= 4000);
        _ = try toData(arena.allocator(), m);
    }
}
