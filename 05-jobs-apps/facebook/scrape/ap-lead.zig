// Lead Ads of the Page: forms, then each form's leads. Each lead arrives once (key = lead id).
const std = @import("std");
const shape = @import("rw-shape.zig");
const graph = @import("ap-graph.zig");
const rowm = @import("ap-row.zig");

pub fn run(j: *rowm.Job, out: *std.ArrayList(shape.Row)) !void {
    const forms = try j.g.pull(j.token, try j.path("forms", "page", j.page), j.fields("forms"), &.{}, null, null);
    for (forms) |f| {
        const fid = rowm.idOf(f);
        if (fid.len == 0) continue;
        try out.append(j.a, try j.row(fid, "form", f, &.{}, false));
        const leads = try j.g.pull(j.token, try j.path("leads", "form", fid), j.fields("leads"), &.{}, null, null);
        for (leads) |l| {
            const lid = rowm.idOf(l);
            if (lid.len == 0) continue;
            try out.append(j.a, try j.row(lid, "lead", l, &.{.{ "form", fid }}, true));
        }
    }
}
