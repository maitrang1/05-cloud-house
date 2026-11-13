// probe <vendor> <url> [--dry-run]: one real call to one vendor with the key from its env var. Records credits. Exit 3 = key dead / limited / challenge (drift).
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const guard = @import("co-guard.zig");
const regis = @import("ve-regis.zig");
const call = @import("ve-call.zig");
const quota_mod = @import("ve-quota.zig");
const break_mod = @import("ve-break.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    _ = json;
    if (av.len < 2) {
        util.eprint(cx.io, "error: usage\nwhy: probe needs a vendor id and a url\nfix: scrape probe <vendor> <url> [--kind K] [--dry-run] [--revive]\n", .{});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const reg = cx.vendor_reg orelse regis.load(a, cx.io, cx.rel(a, cx.cfg.vendor.file) catch return 1, cx.mock) catch {
        util.eprint(cx.io, "error: vendor file unreadable\nwhy: {s}\nfix: restore df-scrape-vendors.json\n", .{cx.cfg.vendor.file});
        return 2;
    };
    const d0 = reg.find(av[0]) orelse {
        util.eprint(cx.io, "error: unknown vendor '{s}'\nwhy: not in the registry\nfix: add a row to df-scrape-vendors.json\n", .{av[0]});
        return 2;
    };
    var d = d0;
    if (args.value(av, "--kind")) |k| if (d0.kinds.map.get(k)) |b| {
        d.base = b;
    };
    const brk = break_mod.Breaker{ .io = cx.io, .gpa = cx.gpa, .home = cx.home };
    if (args.has(av, "--revive")) {
        brk.revive(d.id) catch return 1;
        util.print(cx.io, "{s}: revived (breaker + dead flag cleared)\n", .{d.id});
    }
    // the target must pass our guard: a vendor is never a way around the allowlist
    _ = guard.parseUrl(a, av[1], .{ .allow_hosts = cx.cfg.market.allow_hosts, .mock = cx.mock }) catch |e| {
        util.eprint(cx.io, "error: url refused ({s})\nwhy: not an allowed public https url\nfix: use a facebook.com page\n", .{@errorName(e)});
        return 2;
    };
    const key = regis.keyOf(cx.env, d) orelse {
        util.eprint(cx.io, "error: no key\nwhy: env var {s} is empty\nfix: export {s}=... (never put the key in a file)\n", .{ d.key_env, d.key_env });
        return 2;
    };
    if (args.has(av, "--dry-run")) {
        const b = call.build(a, d, "***", av[1]) catch return 1;
        util.print(cx.io, "{s} {s}\n", .{ b.method, b.url });
        for (b.headers) |h| util.print(cx.io, "  {s}: {s}\n", .{ h.name, if (std.ascii.eqlIgnoreCase(h.name, "content-type")) h.value else "***" });
        return 0;
    }
    const env = call.Env{ .io = cx.io, .mock = cx.mock, .resolver = cx.resolver, .ua = cx.cfg.market.user_agent, .timeout_s = cx.cfg.market.timeout_s, .cap_bytes = @as(usize, cx.cfg.market.body_cap_kb) * 1024 };
    const res = call.call(a, env, d, key, av[1]);
    const q = quota_mod.Quota{ .io = cx.io, .gpa = cx.gpa, .home = cx.home };
    switch (res) {
        .ok => |o| {
            q.record(d.id, "ops", o.credits, cx.nowMs()) catch {};
            util.print(cx.io, "{s}: ok · {d} bytes · {d} credits\n", .{ d.id, o.body.len, o.credits });
            return 0;
        },
        .dead => {
            brk.kill(d.id) catch {};
            util.eprint(cx.io, "error: {s} rejected the key\nwhy: wrong or expired key (vendor now OFF)\nfix: set a valid {s}, then probe --revive\n", .{ d.id, d.key_env });
            return 3;
        },
        .limited => {
            util.eprint(cx.io, "error: {s} says limit reached\nwhy: plan or rate exhausted\nfix: wait or switch vendor\n", .{d.id});
            return 3;
        },
        .challenge => {
            util.eprint(cx.io, "error: {s} returned a captcha page\nwhy: the target blocks it too\nfix: none - we never solve captchas\n", .{d.id});
            return 3;
        },
        .failed => {
            util.eprint(cx.io, "error: {s} call failed\nwhy: network, 5xx or reply shape changed\nfix: check the registry row (reply path, base url)\n", .{d.id});
            return 1;
        },
    }
}
