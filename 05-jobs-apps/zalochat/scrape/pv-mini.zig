// Mini App stats: no scraping of the dashboard. The cust exports a CSV/JSON from their own dashboard; we turn it into `mini_stat` rows.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");

pub const max_bytes: usize = 5 * 1024 * 1024;
pub const max_rows: usize = 100_000;
pub const max_cols: usize = 50;

// RFC 4180-ish: quotes, "" escape, commas/newlines inside quotes
fn parseCsv(a: std.mem.Allocator, text: []const u8) ![][]const []const u8 {
    var rows: std.ArrayList([]const []const u8) = .empty;
    var row: std.ArrayList([]const u8) = .empty;
    var field: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var inq = false;
    var any = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (inq) {
            if (c == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    try field.append(a, '"');
                    i += 1;
                } else inq = false;
            } else try field.append(a, c);
            continue;
        }
        switch (c) {
            '"' => {
                inq = true;
                any = true;
            },
            ',' => {
                try row.append(a, try a.dupe(u8, field.items));
                field.clearRetainingCapacity();
                any = true;
            },
            '\r' => {},
            '\n' => {
                if (any or field.items.len > 0 or row.items.len > 0) {
                    try row.append(a, try a.dupe(u8, field.items));
                    if (row.items.len > max_cols) return error.TooManyColumns;
                    try rows.append(a, try row.toOwnedSlice(a));
                    if (rows.items.len > max_rows + 1) return error.TooManyRows;
                }
                field.clearRetainingCapacity();
                any = false;
            },
            else => {
                try field.append(a, c);
                any = true;
            },
        }
    }
    if (any or field.items.len > 0 or row.items.len > 0) {
        try row.append(a, try a.dupe(u8, field.items));
        try rows.append(a, try row.toOwnedSlice(a));
    }
    return rows.toOwnedSlice(a);
}

fn cellValue(a: std.mem.Allocator, w: *std.json.Stringify, s: []const u8) !void {
    _ = a;
    if (std.fmt.parseInt(i64, s, 10)) |n| return w.write(n) else |_| {}
    if (std.fmt.parseFloat(f64, s)) |f| {
        if (std.math.isFinite(f) and s.len > 0 and (std.ascii.isDigit(s[0]) or s[0] == '-' or s[0] == '.')) return w.write(f);
    } else |_| {}
    return w.write(s);
}

fn rowFrom(a: std.mem.Allocator, header: []const []const u8, cells: []const []const u8) !std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(a);
    var w: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try w.beginObject();
    for (header, 0..) |h, k| {
        try w.objectField(h);
        try cellValue(a, &w, if (k < cells.len) cells[k] else "");
    }
    try w.endObject();
    return std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{ .allocate = .alloc_always });
}

// import a CSV export file for one cust; key = mini:<first column value>. Returns rows added.
pub fn importFile(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, path: []const u8) anyerror!u32 {
    const cust = try st.getCust(a, cust_id);
    if (cx.cfg.legal.consent_required and !cust.consent) return error.ConsentRequired;
    const text = util.readAll(a, cx.io, path, max_bytes) catch |e| return if (e == error.StreamTooLong) error.FileTooBig else e;
    const t = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    const table = try parseCsv(a, t);
    if (table.len < 2) return error.EmptyExport;
    const header = table[0];
    for (header) |h| if (h.len == 0) return error.BadHeader;
    var batch: std.ArrayList(shape.Row) = .empty;
    const now = cx.nowMs();
    for (table[1..]) |cells| {
        if (cells.len == 0 or cells[0].len == 0) continue;
        const key = try std.fmt.allocPrint(a, "mini:{s}", .{cells[0]});
        try batch.append(a, try shape.makeRow(a, cust_id, .private, key, "mini_stat", now, try rowFrom(a, header, cells)));
    }
    const s = try st.upsert(cust_id, batch.items);
    return s.added;
}

test "mini: fixture export -> stat rows; rerun 0; quoted comma kept; numbers typed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(a, &env, home);
    var st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    try st.putCust(a, .{ .cust_id = "alpha", .consent = true });
    try std.testing.expectEqual(@as(u32, 3), try importFile(&cx, &st, a, "alpha", "te-mini-export.csv"));
    try std.testing.expectEqual(@as(u32, 0), try importFile(&cx, &st, a, "alpha", "te-mini-export.csv"));
    const pg = try st.rowsSince(a, "alpha", 0, 10);
    try std.testing.expectEqualStrings("mini_stat", pg.rows[0].kind);
    try std.testing.expectEqualStrings("/home, main", pg.rows[0].data.object.get("top page").?.string);
    try std.testing.expectEqual(@as(i64, 120), pg.rows[0].data.object.get("sessions").?.integer);
    try std.testing.expectEqual(@as(f64, 1500.5), pg.rows[0].data.object.get("revenue").?.float);
    // consent gate; empty/garbage files refused
    try st.putCust(a, .{ .cust_id = "alpha", .consent = false });
    try std.testing.expectError(error.ConsentRequired, importFile(&cx, &st, a, "alpha", "te-mini-export.csv"));
    try st.putCust(a, .{ .cust_id = "alpha", .consent = true });
    try util.writeAtomic(a, cx.io, try std.fmt.allocPrint(a, "{s}/empty.csv", .{home}), "date\n");
    try std.testing.expectError(error.EmptyExport, importFile(&cx, &st, a, "alpha", try std.fmt.allocPrint(a, "{s}/empty.csv", .{home})));
    try std.testing.expectError(error.FileNotFound, importFile(&cx, &st, a, "alpha", "nope.csv"));
}
