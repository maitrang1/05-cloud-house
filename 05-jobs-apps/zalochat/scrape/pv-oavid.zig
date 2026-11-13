// Own OA articles + videos (list and status; links and metadata only, never media files). Official API, read only.
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const oapi = @import("pv-oapi.zig");

const keys = [_][]const u8{ "id", "title", "status", "type", "thumb", "cover", "create_date", "update_date", "link" };

pub fn syncArticles(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8) anyerror!u32 {
    const cust = try st.getCust(a, cust_id);
    if (cx.cfg.legal.consent_required and !cust.consent) return error.ConsentRequired;
    if (!cust.oa_enabled) return error.OaNotEnabled;
    var c = try oapi.Client.init(cx, st, a, cust_id);
    const o = cx.cfg.oa;
    var added: u32 = 0;
    var off: u32 = 0;
    var seen: u32 = 0;
    var rows: std.ArrayList(shape.Row) = .empty;
    const now = cx.nowMs();
    while (seen < o.max_articles) {
        const q = try std.fmt.allocPrint(a, "{{\"offset\":{d},\"limit\":{d}}}", .{ off, o.page_msgs });
        const d = c.call(o.paths.articles, q) catch |e| {
            if (e == oapi.Err.QuotaStop) break;
            return e;
        };
        const list = if (d == .object) (d.object.get("medias") orelse break) else break;
        if (list != .array or list.array.items.len == 0) break;
        for (list.array.items) |m| {
            const id = shape.strOf(m, "id");
            if (id.len == 0) continue;
            try rows.append(a, try shape.makeRow(a, cust_id, .private, try std.fmt.allocPrint(a, "oa:article:{s}", .{id}), "oa_article", now, try shape.pick(a, m, &keys)));
            seen += 1;
        }
        const s = try st.upsert(cust_id, rows.items);
        added += s.added;
        rows.clearRetainingCapacity();
        off += @intCast(list.array.items.len);
    }
    return added;
}

test "oavid: articles listed, rerun adds nothing" {
    var rig = oapi.Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    var c = try oapi.Client.init(&rig.cx, &rig.st, a, "alpha");
    _ = try c.authorizeUrl();
    try c.exchangeCode("GOODCODE");
    rig.cx.cfg.oa.page_msgs = 2;
    try std.testing.expectEqual(@as(u32, 3), try syncArticles(&rig.cx, &rig.st, a, "alpha"));
    try std.testing.expectEqual(@as(u32, 0), try syncArticles(&rig.cx, &rig.st, a, "alpha"));
    const pg = try rig.st.rowsSince(a, "alpha", 0, 10);
    try std.testing.expectEqualStrings("oa_article", pg.rows[0].kind);
}
