// Shared by the own-Page pullers: one job context + the row builder (adds page id, expiry and the personal flag).
const std = @import("std");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const graph = @import("ap-graph.zig");

pub const Job = struct {
    cx: *ctx_mod.Ctx,
    st: *const store_mod.Store,
    g: *graph.Client,
    a: std.mem.Allocator,
    cust: []const u8,
    page: []const u8,
    token: []const u8,
    now: i64,

    // config path template with one placeholder filled in: "{page}/conversations" + page -> "P1/conversations"
    pub fn path(self: *const Job, name: []const u8, ph: []const u8, val: []const u8) graph.Err![]const u8 {
        const t = self.cx.cfg.graph.paths.map.get(name) orelse return graph.Err.Api;
        const needle = std.fmt.allocPrint(self.a, "{{{s}}}", .{ph}) catch return graph.Err.OutOfMemory;
        return std.mem.replaceOwned(u8, self.a, t, needle, val) catch return graph.Err.OutOfMemory;
    }
    pub fn fields(self: *const Job, name: []const u8) []const u8 {
        return self.cx.cfg.graph.fields.map.get(name) orelse "id";
    }

    // Graph item -> private row. Unknown fields stay (raw); page id added; expiry from legal.own_expire_days.
    pub fn row(self: *const Job, key: []const u8, kind: []const u8, item: std.json.Value, extra: []const [2][]const u8, personal: bool) !shape.Row {
        if (item != .object) return error.BadItem;
        var o = try item.object.clone(self.a);
        try o.put(self.a, "page", .{ .string = self.page });
        for (extra) |e| try o.put(self.a, e[0], .{ .string = e[1] });
        const r = try shape.makeRow(self.a, self.cust, .private, key, kind, self.now, .{ .object = o });
        const exp = self.now + @as(i64, self.cx.cfg.legal.own_expire_days) * store_mod.day_ms;
        return shape.withTerms(r, exp, personal);
    }
};

pub fn idOf(v: std.json.Value) []const u8 {
    return graph.strOf(v, "id");
}
