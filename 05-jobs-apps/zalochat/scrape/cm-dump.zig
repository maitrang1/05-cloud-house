// dump --cust ID [--out DIR]: export rows, files, logs + manifest (never secrets)
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const legal = @import("pv-dump.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const c = args.custArg(cx, av) orelse return 2;
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
