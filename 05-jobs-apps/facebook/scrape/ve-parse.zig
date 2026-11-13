// Vendor reply (JSON) -> rows. Field names are DATA (config market.kinds): per kind a list path, key candidates and out-field candidates.
// Unknown fields never reach a row. Same data = same hash, so a re-run adds nothing; a changed price/count adds a version.
const std = @import("std");
const cfg_mod = @import("co-cfg.zig");
const shape = @import("rw-shape.zig");

pub const Err = error{ BadReply, NoKind, OutOfMemory };

fn dig(v: std.json.Value, path: []const u8) ?std.json.Value {
    var cur = v;
    if (path.len == 0) return cur;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |k| {
        if (cur != .object) return null;
        cur = cur.object.get(k) orelse return null;
    }
    return cur;
}

fn firstOf(obj: std.json.Value, names: []const []const u8) ?std.json.Value {
    if (obj != .object) return null;
    for (names) |n| if (obj.object.get(n)) |x| if (x != .null) return x;
    return null;
}

// ids may arrive as numbers
fn keyText(a: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| if (s.len > 0 and s.len <= 512) s else null,
        .integer => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch null,
        else => null,
    };
}

fn capped(a: std.mem.Allocator, v: std.json.Value, cap: usize) !std.json.Value {
    switch (v) {
        .string => |s| return if (s.len > cap) .{ .string = try a.dupe(u8, s[0..cap]) } else v,
        else => return v,
    }
}

pub const Stats = struct { items: u32 = 0, skipped: u32 = 0 };

pub fn toRows(a: std.mem.Allocator, m: cfg_mod.Market, cust: []const u8, kind: []const u8, src_url: []const u8, body: []const u8, now: i64, out: *std.ArrayList(shape.Row)) Err!Stats {
    const kd = m.kinds.map.get(kind) orelse return Err.NoKind;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch return Err.BadReply;
    var list = dig(root, kd.list) orelse root;
    if (list == .object and kd.list.len == 0 or (list == .object and kd.list.len > 0 and dig(root, kd.list) == null)) {
        // common wrappers
        for ([_][]const u8{ "data", "items", "results" }) |w| if (list.object.get(w)) |x| if (x == .array) {
            list = x;
            break;
        };
    }
    var one: [1]std.json.Value = undefined;
    const items: []const std.json.Value = switch (list) {
        .array => |arr| arr.items,
        .object => blk: {
            one[0] = list;
            break :blk one[0..1];
        },
        else => return Err.BadReply,
    };
    var st = Stats{};
    for (items) |it| {
        if (it != .object) {
            st.skipped += 1;
            continue;
        }
        const kv = firstOf(it, kd.key) orelse {
            st.skipped += 1;
            continue;
        };
        const key = keyText(a, kv) orelse {
            st.skipped += 1;
            continue;
        };
        var o = std.json.ObjectMap.empty;
        var personal = false;
        var fit = kd.fields.map.iterator();
        while (fit.next()) |e| {
            const val = firstOf(it, e.value_ptr.*) orelse continue;
            const cap: usize = if (std.mem.eql(u8, e.key_ptr.*, "text")) m.text_cap else m.field_cap;
            o.put(a, e.key_ptr.*, try capped(a, val, cap)) catch return Err.OutOfMemory;
            for (kd.personal) |p| if (std.mem.eql(u8, p, e.key_ptr.*)) {
                personal = true;
            };
        }
        o.put(a, "src", .{ .string = src_url }) catch return Err.OutOfMemory;
        const r = shape.makeRow(a, cust, .public, key, kind, now, .{ .object = o }) catch return Err.OutOfMemory;
        out.append(a, shape.withTerms(r, 0, personal)) catch return Err.OutOfMemory;
        st.items += 1;
    }
    return st;
}

fn testMarket(a: std.mem.Allocator) !cfg_mod.Market {
    var w: [160]u8 = undefined;
    var n: usize = 0;
    const c = cfg_mod.load(a, std.testing.io, "00-config.json", &w, &n) catch unreachable;
    return c.market;
}

test "parse: page, posts with a wrapper, comments flagged personal, listing price versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try testMarket(a);
    var rows: std.ArrayList(shape.Row) = .empty;
    const s1 = try toRows(a, m, "demo", "page", "https://www.facebook.com/example", "{\"id\":\"100\",\"name\":\"Quan A\",\"followers_count\":1200,\"junk\":{\"x\":1}}", 5, &rows);
    try std.testing.expectEqual(@as(u32, 1), s1.items);
    try std.testing.expectEqualStrings("100", rows.items[0].key);
    try std.testing.expect(rows.items[0].data.object.get("junk") == null); // unknown field dropped
    try std.testing.expectEqual(@as(i64, 1200), rows.items[0].data.object.get("followers").?.integer);
    try std.testing.expect(!rows.items[0].personal);
    const s2 = try toRows(a, m, "demo", "post", "https://www.facebook.com/example", "{\"posts\":[{\"post_id\":\"p1\",\"text\":\"hi\",\"likes\":3},{\"post_id\":\"p2\",\"text\":\"yo\"},{\"nokey\":1}]}", 5, &rows);
    try std.testing.expectEqual(@as(u32, 2), s2.items);
    try std.testing.expectEqual(@as(u32, 1), s2.skipped);
    const s3 = try toRows(a, m, "demo", "cmnt", "u", "{\"data\":[{\"id\":7,\"message\":\"ok\",\"name\":\"An\"}]}", 5, &rows);
    try std.testing.expectEqual(@as(u32, 1), s3.items);
    const c = rows.items[rows.items.len - 1];
    try std.testing.expectEqualStrings("7", c.key);
    try std.testing.expect(c.personal);
    // same listing, same price = same hash; new price = new hash (a version, not a duplicate)
    var l1: std.ArrayList(shape.Row) = .empty;
    _ = try toRows(a, m, "demo", "item", "u", "[{\"id\":\"L1\",\"title\":\"Xe\",\"price\":100}]", 5, &l1);
    _ = try toRows(a, m, "demo", "item", "u", "[{\"id\":\"L1\",\"title\":\"Xe\",\"price\":100}]", 9, &l1);
    _ = try toRows(a, m, "demo", "item", "u", "[{\"id\":\"L1\",\"title\":\"Xe\",\"price\":90}]", 9, &l1);
    try std.testing.expectEqualStrings(l1.items[0].hash, l1.items[1].hash);
    try std.testing.expect(!std.mem.eql(u8, l1.items[0].hash, l1.items[2].hash));
}

test "parse: junk replies and unknown kinds are refused, long text is capped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = try testMarket(a);
    m.text_cap = 5;
    var rows: std.ArrayList(shape.Row) = .empty;
    try std.testing.expectError(Err.BadReply, toRows(a, m, "demo", "page", "u", "<html>nope</html>", 1, &rows));
    try std.testing.expectError(Err.NoKind, toRows(a, m, "demo", "zzz", "u", "{}", 1, &rows));
    try std.testing.expectError(Err.BadReply, toRows(a, m, "demo", "post", "u", "42", 1, &rows));
    _ = try toRows(a, m, "demo", "post", "u", "[{\"id\":\"1\",\"text\":\"abcdefghij\"}]", 1, &rows);
    try std.testing.expectEqualStrings("abcde", rows.items[0].data.object.get("text").?.string);
}
