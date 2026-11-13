// state: app + config summary + hub jobs. With --cust ID: rows, today's fetches, month usage, pause flag. --resume clears a pause.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const meter = @import("rw-meter.zig");
const sche = @import("rw-sche.zig");
const deliv = @import("rw-deliv.zig");

pub const hub_jobs = [_][]const u8{ "zalochat-scan", "zalochat-oa-sync", "zalochat-vendor-probe", "zalochat-purge-old" };

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool, version: []const u8, mock: bool) u8 {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cust = args.value(av, "--cust");
    const st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (cust) |c| {
        if (!ctx_mod.validId(c)) {
            util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
            return 2;
        }
        if (args.has(av, "--resume")) {
            sche.resume_(cx, &st, c) catch return 1;
            util.print(cx.io, "{s}: resumed\n", .{c});
        }
    }
    const S = struct {
        app: []const u8,
        version: []const u8,
        mock: bool,
        home: []const u8,
        kill_switch: bool,
        side_enabled: bool,
        hub_jobs_on: u8,
        cust: ?[]const u8 = null,
        rows: ?usize = null,
        fetches_today: ?u32 = null,
        month_runs: ?u32 = null,
        month_pages: ?u64 = null,
        month_credits: ?u64 = null,
        delivered_cursor: ?usize = null,
        paused: ?bool = null,
    };
    var s = S{ .app = "zalochat-scrape", .version = version, .mock = mock, .home = cx.home, .kill_switch = cx.cfg.sche.kill_switch, .side_enabled = cx.cfg.side.enabled, .hub_jobs_on = 0 };
    if (cust) |c| {
        s.cust = c;
        s.rows = st.countRows(c) catch 0;
        s.fetches_today = st.fetchesToday(c, cx.nowMs()) catch 0;
        const m = meter.month(&st, c, cx.nowMs()) catch meter.Totals{};
        s.month_runs = m.runs;
        s.month_pages = m.pages;
        s.month_credits = m.credits;
        s.delivered_cursor = deliv.cursorOf(&st, a, c);
        s.paused = sche.check(cx, &st, c) == .paused;
    }
    if (json) {
        const t = util.jsonStr(a, s) catch return 1;
        util.printAll(cx.io, t);
        util.printAll(cx.io, "\n");
        return 0;
    }
    util.print(cx.io, "zalochat-scrape {s}{s}\nhome: {s}\nkill_switch: {}  personal_tier: {}\nhub jobs (all off): ", .{ version, if (mock) " [mock build]" else "", cx.home, cx.cfg.sche.kill_switch, cx.cfg.side.enabled });
    for (hub_jobs, 0..) |j, i| util.print(cx.io, "{s}{s}", .{ if (i > 0) ", " else "", j });
    util.printAll(cx.io, "\n");
    if (cust) |c| util.print(cx.io, "cust {s}: rows {d} · fetches today {d} · month runs {d} pages {d} credits {d} · delivered to cursor {d}{s}\n", .{ c, s.rows.?, s.fetches_today.?, s.month_runs.?, s.month_pages.?, s.month_credits.?, s.delivered_cursor.?, if (s.paused.?) " · PAUSED" else "" });
    return 0;
}
