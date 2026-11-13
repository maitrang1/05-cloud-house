// Page insights: one row per metric per end_time (metric names come from config; Meta retires metrics, so they are data).
const std = @import("std");
const shape = @import("rw-shape.zig");
const graph = @import("ap-graph.zig");
const rowm = @import("ap-row.zig");

pub fn run(j: *rowm.Job, out: *std.ArrayList(shape.Row)) !void {
    const g = j.cx.cfg.graph;
    if (g.insights.len == 0) return;
    const metrics = try std.mem.join(j.a, ",", g.insights);
    const ps = [_]graph.Param{ .{ "metric", metrics }, .{ "period", g.insights_period } };
    const v = try j.g.get(j.token, try j.path("stats", "page", j.page), &ps);
    const data = if (v == .object) (v.object.get("data") orelse return graph.Err.BadJson) else return graph.Err.BadJson;
    if (data != .array) return graph.Err.BadJson;
    for (data.array.items) |m| {
        const name = graph.strOf(m, "name");
        const vals = if (m == .object) (m.object.get("values") orelse continue) else continue;
        if (vals != .array or name.len == 0) continue;
        for (vals.array.items) |pt| {
            const et = graph.strOf(pt, "end_time");
            const val = if (pt == .object) (pt.object.get("value") orelse continue) else continue;
            var o = std.json.ObjectMap.empty;
            try o.put(j.a, "metric", .{ .string = name });
            try o.put(j.a, "period", .{ .string = g.insights_period });
            try o.put(j.a, "end_time", .{ .string = et });
            try o.put(j.a, "value", val);
            const key = try std.fmt.allocPrint(j.a, "stat:{s}:{s}:{s}", .{ j.page, name, et });
            const exp = j.now + @as(i64, j.cx.cfg.legal.own_expire_days) * 86_400_000;
            const r = try shape.makeRow(j.a, j.cust, .private, key, "stat", j.now, .{ .object = o });
            try out.append(j.a, shape.withTerms(r, exp, false));
        }
    }
}
