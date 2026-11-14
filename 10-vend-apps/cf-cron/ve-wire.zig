// =====================================================================
// Des: Steps 8-10: write the Schedule C wiring file, check the Worker answers, print the final report with quota use.
// Flo: write wire file > poll the route > report
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: shared run context
// Out: engine rows
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const engi = @import("co-engine.zig");
const ctxz = @import("co-ctx.zig");

const Ctx = ctxz.Ctx;

const CF = .{ .partExte = ".part", .msecSecs = 1000, .minuDay = 1440 };

// the file the Schedule layer reads for tick source C
const Wire = struct { slot: []const u8, layer: []const u8, worker: []const u8, url: []const u8, cron: []const u8, ticks_per_day: u32, no_retry: bool };

// ticks per day for a period in minutes
pub fn ticksDay(peri: u32) u32 {
    return CF.minuDay / peri;
}

fn wireSche(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const idsz = c.stat.data.idsz;
    if (idsz.workUrl.len == 0 or idsz.cronNow.len == 0) return error.NoUrl;
    const json = try std.json.Stringify.valueAlloc(gpa, Wire{ .slot = c.conf.wire.slot, .layer = c.conf.wire.laye, .worker = c.conf.cfla.scri, .url = idsz.workUrl, .cron = idsz.cronNow, .ticks_per_day = ticksDay(c.conf.cron.peri), .no_retry = true }, .{ .whitespace = .indent_2 });
    const path = try std.fs.path.join(gpa, &.{ c.root, c.conf.data.wire });
    const part = try std.mem.concat(gpa, u8, &.{ path, CF.partExte });
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = part, .data = json });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), part, std.Io.Dir.cwd(), path, c.io);
    return .{ .okay = try std.fmt.allocPrint(gpa, "tick source {s} wired: {s}", .{ c.conf.wire.slot, path }) };
}

// poll the Worker address until it answers 200; returns seconds, null on timeout
pub fn routeTime(c: *Ctx, gpa: std.mem.Allocator) !?u32 {
    const star = std.Io.Clock.awake.now(c.io).toMilliseconds();
    const limi: i64 = @as(i64, c.conf.rout.wait) * CF.msecSecs;
    while (true) {
        const resp = c.cfla.http.call(.{ .urlz = c.stat.data.idsz.workUrl }) catch null;
        if (resp) |r| {
            defer gpa.free(r.body);
            if (r.code == 200) return @intCast(@divTrunc(std.Io.Clock.awake.now(c.io).toMilliseconds() - star + CF.msecSecs - 1, CF.msecSecs));
        }
        if (std.Io.Clock.awake.now(c.io).toMilliseconds() - star >= limi) return null;
        try std.Io.sleep(c.io, .fromMilliseconds(@as(i64, c.conf.rout.poll) * CF.msecSecs), .awake);
    }
}

fn tickTest(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const secs = (try routeTime(c, gpa)) orelse return .{ .skip = try std.fmt.allocPrint(gpa, "no 200 within {d}s: a new route can need a few minutes, run again", .{c.conf.rout.wait}) };
    c.stat.data.idsz.routeSecs = secs;
    return .{ .okay = try std.fmt.allocPrint(gpa, "worker answered in {d}s; first tick can take up to 15 min after a change", .{secs}) };
}

// daily request use of the tick vs the free cap
fn cfcrFina(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const tick = ticksDay(c.conf.cron.peri);
    const perc = tick * 100 / c.conf.limi.reqs;
    const warn = if (perc >= c.conf.limi.warn) "  WARNING: near the free daily cap" else "";
    return .{ .okay = try std.fmt.allocPrint(gpa, "ticks/day {d} of {d} ({d}%){s}; cron triggers: this app uses 1 of {d} free; url {s}", .{ tick, c.conf.limi.reqs, perc, warn, c.conf.limi.trig, c.stat.data.idsz.workUrl }) };
}

pub fn rows(ctx: *Ctx) [3]engi.Row {
    return .{
        ctxz.row(ctx, "wire-sche", "Write the url as Schedule C", false, wireSche),
        ctxz.row(ctx, "tick-test", "Check the Worker answers", false, tickTest),
        ctxz.row(ctx, "cfcr-fina", "Final check and report", false, cfcrFina),
    };
}

test "ticks per day" {
    try std.testing.expectEqual(@as(u32, 288), ticksDay(5));
    try std.testing.expectEqual(@as(u32, 1440), ticksDay(1));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
