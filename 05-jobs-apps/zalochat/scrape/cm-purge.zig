// purge --cust ID [--old] [--yes]: retention sweep or full offboard (dry run unless --yes)
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const legal = @import("pv-legal.zig");
const purger = @import("pv-purge.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const c = args.custArg(cx, av) orelse return 2;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (args.has(av, "--old")) {
        const s = legal.purgeOld(cx, &st, a, c) catch return 1;
        util.print(cx.io, "{s}: retention - kept {d}, dropped {d} private rows\n", .{ c, s.kept, s.dropped });
        return 0;
    }
    const n = purger.countCust(cx, &st, a, c) catch {
        util.eprint(cx.io, "error: no such cust\nwhy: no folder for {s}\nfix: check the id\n", .{c});
        return 2;
    };
    if (!args.has(av, "--yes")) {
        util.print(cx.io, "DRY RUN: would remove cust {s}: {d} rows, {d} files, secrets {s}, all logs. Cannot be undone.\nRun again with --yes to do it (dump first: scrape dump --cust {s}).\n", .{ c, n.rows, n.files, if (n.had_secrets) "yes" else "none", c });
        return 0;
    }
    const s = purger.purgeCust(cx, &st, a, c) catch |e| {
        util.eprint(cx.io, "error: purge failed ({s})\nwhy: a run holds the cust folder\nfix: stop runs for {s}, retry\n", .{ @errorName(e), c });
        return 1;
    };
    util.print(cx.io, "{s}: purged - {d} rows, {d} files, secrets {s}\n", .{ c, s.rows, s.files, if (s.had_secrets) "removed" else "none" });
    return 0;
}

