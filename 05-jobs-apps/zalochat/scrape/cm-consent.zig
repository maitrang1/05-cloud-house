// consent --cust ID --grant|--revoke
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const legal = @import("pv-legal.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const c = args.custArg(cx, av) orelse return 2;
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

