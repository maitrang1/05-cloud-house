// The Page's own posts and their comments.
const std = @import("std");
const shape = @import("rw-shape.zig");
const graph = @import("ap-graph.zig");
const rowm = @import("ap-row.zig");

pub fn run(j: *rowm.Job, out: *std.ArrayList(shape.Row)) !void {
    const posts = try j.g.pull(j.token, try j.path("feed", "page", j.page), j.fields("feed"), &.{}, null, null);
    for (posts) |p| {
        const pid = rowm.idOf(p);
        if (pid.len == 0) continue;
        try out.append(j.a, try j.row(pid, "post", p, &.{}, false));
        const cms = try j.g.pull(j.token, try j.path("cmts", "post", pid), j.fields("cmts"), &.{}, null, null);
        for (cms) |c| {
            const cid = rowm.idOf(c);
            if (cid.len == 0) continue;
            try out.append(j.a, try j.row(cid, "cmnt", c, &.{.{ "post", pid }}, true));
        }
    }
}
