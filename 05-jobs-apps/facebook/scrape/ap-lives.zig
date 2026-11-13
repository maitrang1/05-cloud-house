// The Page's own live videos, read only: list + status, then each live's comments. No create or end call exists in this app.
const std = @import("std");
const shape = @import("rw-shape.zig");
const graph = @import("ap-graph.zig");
const rowm = @import("ap-row.zig");

pub fn run(j: *rowm.Job, out: *std.ArrayList(shape.Row)) !void {
    const lives = try j.g.pull(j.token, try j.path("lives", "page", j.page), j.fields("lives"), &.{}, null, null);
    for (lives) |l| {
        const lid = rowm.idOf(l);
        if (lid.len == 0) continue;
        try out.append(j.a, try j.row(lid, "live", l, &.{}, false));
        const cms = try j.g.pull(j.token, try j.path("lcmts", "live", lid), j.fields("lcmts"), &.{}, null, null);
        for (cms) |c| {
            const cid = rowm.idOf(c);
            if (cid.len == 0) continue;
            try out.append(j.a, try j.row(cid, "lcmt", c, &.{.{ "live", lid }}, true));
        }
    }
}
