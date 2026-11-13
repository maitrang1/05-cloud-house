// consent --cust ID --grant|--revoke · purge --cust ID [--old] [--yes] · dump --cust ID [--out DIR]
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const legal = @import("pv-legal.zig");

fn custOf(cx: *ctx_mod.Ctx, av: []const []const u8) ?[]const u8 {
    const c = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: this works on one cust\nfix: add --cust ID\n", .{});
        return null;
    };
    if (!ctx_mod.validId(c)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return null;
    }
    return c;
}

pub fn consent(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const c = custOf(cx, av) orelse return 2;
    const grant = args.has(av, "--grant");
    if (!grant and !args.has(av, "--revoke")) {
        util.eprint(cx.io, "error: --grant or --revoke needed\nwhy: consent is explicit\nfix: scrape consent --cust {s} --grant\n", .{c});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    legal.setConsent(cx, &st, arena.allocator(), c, grant) catch return 1;
    util.print(cx.io, "{s}: consent {s}\n", .{ c, if (grant) "granted" else "revoked (sync stops; run purge to remove data)" });
    return 0;
}

pub fn purge(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const c = custOf(cx, av) orelse return 2;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (args.has(av, "--old")) {
        const s = legal.purgeOld(cx, &st, a, c) catch return 1;
        util.print(cx.io, "{s}: retention - kept {d}, dropped {d} private rows\n", .{ c, s.kept, s.dropped });
        return 0;
    }
    const n = legal.countCust(cx, &st, a, c) catch {
        util.eprint(cx.io, "error: no such cust\nwhy: no folder for {s}\nfix: check the id\n", .{c});
        return 2;
    };
    if (!args.has(av, "--yes")) {
        util.print(cx.io, "DRY RUN: would remove cust {s}: {d} rows, {d} files, secrets {s}, all logs. Cannot be undone.\nRun again with --yes to do it (dump first: scrape dump --cust {s}).\n", .{ c, n.rows, n.files, if (n.had_secrets) "yes" else "none", c });
        return 0;
    }
    const s = legal.purgeCust(cx, &st, a, c) catch |e| {
        util.eprint(cx.io, "error: purge failed ({s})\nwhy: a run holds the cust folder\nfix: stop runs for {s}, retry\n", .{ @errorName(e), c });
        return 1;
    };
    util.print(cx.io, "{s}: purged - {d} rows, {d} files, secrets {s}\n", .{ c, s.rows, s.files, if (s.had_secrets) "removed" else "none" });
    return 0;
}

pub fn dump(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const c = custOf(cx, av) orelse return 2;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    const out = args.value(av, "--out") orelse (std.fmt.allocPrint(a, "{s}/dumps/{s}-{d}", .{ cx.home, c, cx.nowMs() }) catch return 1);
    const d = legal.dump(cx, &st, a, c, out) catch |e| {
        util.eprint(cx.io, "error: dump failed ({s})\nwhy: unreadable cust folder or no space\nfix: check the id and the disk\n", .{@errorName(e)});
        return 1;
    };
    const ok = legal.verifyDump(cx, a, out) catch false;
    util.print(cx.io, "{s}: dump {s} - {d} rows, {d} files, verify {s}. Secrets are never exported.\n", .{ c, d.dir, d.rows, d.files, if (ok) "OK" else "FAILED" });
    return if (ok) 0 else 1;
}
