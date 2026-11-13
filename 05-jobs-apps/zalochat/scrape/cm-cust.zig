// cust --cust ID [--add-url U]... [--webhook URL] [--vendors on|off] [--retention-days N] [--daily-cap N] [--show]
// Creates or edits the cust file so nobody hand-edits JSON. Consent is separate (consent --grant).
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const guard = @import("pu-guard.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const id = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: a cust needs an id\nfix: scrape cust --cust ID --add-url https://zalo.me/NAME\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(id)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ - (max 64)\nfix: use a safe id\n", .{});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    var c = st.getCust(a, id) catch shape.Cust{ .cust_id = id };
    var urls: std.ArrayList([]const u8) = .empty;
    urls.appendSlice(a, c.urls) catch return 1;
    const add = args.all(a, av, "--add-url") catch return 1;
    for (add) |u| {
        _ = guard.parseUrl(a, u, .{ .allow_hosts = cx.cfg.public.allow_hosts, .mock = cx.mock }) catch |e| {
            util.eprint(cx.io, "error: url refused ({s})\nwhy: only public https pages on the allowed Zalo hosts\nfix: use https://zalo.me/NAME\n", .{@errorName(e)});
            return 2;
        };
        var dup = false;
        for (urls.items) |x| if (std.mem.eql(u8, x, u)) {
            dup = true;
        };
        if (!dup) urls.append(a, u) catch return 1;
    }
    c.urls = urls.items;
    if (args.value(av, "--webhook")) |w| {
        if (w.len > 0) _ = guard.parseUrl(a, w, .{ .allow_hosts = &.{}, .mock = cx.mock, .any_host = true }) catch |e| {
            util.eprint(cx.io, "error: webhook refused ({s})\nwhy: it must be a public https:443 address\nfix: use your https endpoint\n", .{@errorName(e)});
            return 2;
        };
        c.webhook_url = w;
    }
    if (args.value(av, "--vendors")) |v| c.vendors_allowed = std.mem.eql(u8, v, "on");
    if (args.value(av, "--retention-days")) |v| c.retention_days = std.fmt.parseInt(u32, v, 10) catch {
        util.eprint(cx.io, "error: bad --retention-days\nwhy: a whole number of days\nfix: e.g. --retention-days 90\n", .{});
        return 2;
    };
    if (args.value(av, "--daily-cap")) |v| c.daily_cap = std.fmt.parseInt(u32, v, 10) catch {
        util.eprint(cx.io, "error: bad --daily-cap\nwhy: a whole number of pages\nfix: e.g. --daily-cap 200\n", .{});
        return 2;
    };
    if (!args.has(av, "--show")) st.putCust(a, c) catch |e| {
        util.eprint(cx.io, "error: cannot save ({s})\nwhy: the home folder is not writable\nfix: check SCRAPE_HOME\n", .{@errorName(e)});
        return 1;
    };
    util.print(cx.io, "{s}: {d} url(s) · webhook {s} · vendors {s} · consent {s}\n", .{ c.cust_id, c.urls.len, if (c.webhook_url.len > 0) "set" else "none", if (c.vendors_allowed) "on" else "off", if (c.consent) "yes" else "NO" });
    return 0;
}

test "cust: create, add urls (deduped, guarded), set webhook" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.cfg.public.allow_hosts = &.{"zalo.me"};
    try std.testing.expectEqual(@as(u8, 0), run(&cx, &.{ "--cust", "acme", "--add-url", "https://zalo.me/a", "--add-url", "https://zalo.me/a", "--webhook", "https://hooks.example.com/x" }));
    const st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    const c = try st.getCust(a, "acme");
    try std.testing.expectEqual(@as(usize, 1), c.urls.len);
    try std.testing.expectEqualStrings("https://hooks.example.com/x", c.webhook_url);
    try std.testing.expectEqual(@as(u8, 2), run(&cx, &.{ "--cust", "acme", "--add-url", "https://evil.com/a" }));
    try std.testing.expectEqual(@as(u8, 2), run(&cx, &.{ "--cust", "acme", "--webhook", "https://10.0.0.1/x" }));
    try std.testing.expectEqual(@as(u8, 0), run(&cx, &.{ "--cust", "acme", "--vendors", "off", "--daily-cap", "50" }));
    const c2 = try st.getCust(a, "acme");
    try std.testing.expect(!c2.vendors_allowed and c2.daily_cap == 50 and c2.urls.len == 1);
}
