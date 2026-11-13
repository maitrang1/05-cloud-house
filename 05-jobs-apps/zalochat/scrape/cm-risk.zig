// risk --cust ID [--reset]: personal-tier drill state. Clean days pass it; any lock / dead session / rate limit cuts the tier.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const risk = @import("pv-risk.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: risk state is per cust\nfix: scrape risk --cust ID [--reset]\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (args.has(av, "--reset")) {
        risk.reset(&st, a, cust) catch return 1;
        util.print(cx.io, "{s}: risk state reset (drill starts again)\n", .{cust});
        return 0;
    }
    const s = risk.load(&st, a, cust);
    const v = risk.verdict(cx, s);
    util.print(cx.io, "{s}: {s} · clean days {d}/{d} · events {d}{s}\n", .{ cust, @tagName(v), s.ok_days, cx.cfg.side.risk_days, s.events, if (v == .cut) " · TIER CUT: stop using the personal tier for this account" else "" });
    return if (v == .cut) 3 else 0;
}
