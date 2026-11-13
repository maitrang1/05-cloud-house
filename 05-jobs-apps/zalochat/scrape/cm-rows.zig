// rows --cust ID [--since CURSOR] [--limit N] [--push]: pull API (JSONL + next cursor) or push the next batch to the cust's webhook.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const shape = @import("rw-shape.zig");
const deliv = @import("rw-deliv.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: rows are per cust\nfix: scrape rows --cust ID [--since N] [--push]\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return 2;
    }
    const st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (args.has(av, "--push")) {
        const s = deliv.push(cx, &st, cust) catch |e| {
            util.eprint(cx.io, "error: push failed ({s})\nwhy: cust file missing or store busy\nfix: check cust.json and retry\n", .{@errorName(e)});
            return 1;
        };
        util.print(cx.io, "push {s}: {s} · rows {d} · cursor {d}->{d} · tries {d}\n", .{ cust, @tagName(s.outcome), s.rows, s.from, s.to, s.tries });
        return switch (s.outcome) {
            .delivered, .nothing_new => 0,
            .failed => 1,
            .no_webhook, .no_secret => 2,
        };
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const since = std.fmt.parseInt(usize, args.value(av, "--since") orelse "0", 10) catch {
        util.eprint(cx.io, "error: bad --since\nwhy: the cursor is a number\nfix: use the 'next' value of the last pull\n", .{});
        return 2;
    };
    const limit = std.fmt.parseInt(usize, args.value(av, "--limit") orelse "", 10) catch cx.cfg.deliv.pull_page;
    const pg = st.rowsSince(a, cust, since, limit) catch return 1;
    if (json) {
        const O = struct { next: usize, rows: []const shape.Row };
        const s = util.jsonStr(a, O{ .next = pg.next, .rows = pg.rows }) catch return 1;
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
        return 0;
    }
    for (pg.rows) |r| {
        const ln = shape.rowLine(a, r) catch return 1;
        util.printAll(cx.io, ln);
        util.printAll(cx.io, "\n");
    }
    util.eprint(cx.io, "next cursor: {d}\n", .{pg.next});
    return 0;
}
