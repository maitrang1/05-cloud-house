// Messenger inbox of the cust's own Page: conversations newest first, stop at the last seen update, then each changed chat's messages.
const std = @import("std");
const shape = @import("rw-shape.zig");
const graph = @import("ap-graph.zig");
const rowm = @import("ap-row.zig");
const util = @import("co-util.zig");

const Mark = struct { seen: []const u8 };
fn atMark(p: ?*anyopaque, item: std.json.Value) bool {
    const m: *const Mark = @ptrCast(@alignCast(p.?));
    if (m.seen.len == 0) return false;
    return std.mem.order(u8, graph.strOf(item, "updated_time"), m.seen) != .gt;
}

fn markName(j: *const rowm.Job) ![]u8 {
    return std.fmt.allocPrint(j.a, "mark-inbox-{s}.txt", .{j.page});
}

pub fn run(j: *rowm.Job, out: *std.ArrayList(shape.Row)) !void {
    const mp = try j.st.path(j.a, j.cust, try std.fmt.allocPrint(j.a, "files/{s}", .{try markName(j)}));
    const seen = std.mem.trim(u8, util.readAll(j.a, j.cx.io, mp, 256) catch "", " \r\n");
    var m = Mark{ .seen = seen };
    const convs = try j.g.pull(j.token, try j.path("inbox", "page", j.page), j.fields("inbox"), &.{}, atMark, &m);
    for (convs) |cv| {
        const cid = rowm.idOf(cv);
        if (cid.len == 0) continue;
        const msgs = try j.g.pull(j.token, try j.path("msgs", "conv", cid), j.fields("msgs"), &.{}, null, null);
        for (msgs) |mg| {
            const mid = rowm.idOf(mg);
            if (mid.len == 0) continue;
            try out.append(j.a, try j.row(mid, "chat", mg, &.{.{ "conv", cid }}, true));
        }
    }
    // move the mark only after the whole pull worked
    if (convs.len > 0) {
        const newest = graph.strOf(convs[0], "updated_time");
        if (newest.len > 0) try j.st.putFile(j.cust, try markName(j), newest);
    }
}
