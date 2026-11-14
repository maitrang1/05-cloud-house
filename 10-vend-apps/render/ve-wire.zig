// =====================================================================
// Des: Steps 7-9: write the service url as Trigger C, time a cold start against the 202 window, print the final report.
// Flo: write wiring file > poll url + health until 200 > report done/skipped/to-do/hand jobs/quota
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: trigger-c.json, wake time in the state file, report lines
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const engi = @import("co-engine.zig");
const ctxz = @import("co-ctx.zig");
const http = @import("co-http.zig");

const Ctx = ctxz.Ctx;

const CF = .{ .partExte = ".part", .msecSecs = 1000, .hourDay = 24 };

// the file the Schedule layer reads for Trigger C
const Wire = struct { slot: []const u8, layer: []const u8, url: []const u8, health: []const u8, service: []const u8, plan: []const u8, cold_start: bool };

fn wireTrig(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const idsz = c.stat.data.idsz;
    if (idsz.servUrl.len == 0) return error.NoUrl;
    const json = try std.json.Stringify.valueAlloc(gpa, Wire{ .slot = c.conf.wire.slot, .layer = c.conf.wire.laye, .url = idsz.servUrl, .health = c.conf.rend.heal, .service = idsz.servId, .plan = c.conf.rend.plan, .cold_start = true }, .{ .whitespace = .indent_2 });
    const path = try std.fs.path.join(gpa, &.{ c.root, c.conf.data.wire });
    const part = try std.mem.concat(gpa, u8, &.{ path, CF.partExte });
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = part, .data = json });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), part, std.Io.Dir.cwd(), path, c.io);
    return .{ .okay = try std.fmt.allocPrint(gpa, "trigger {s} wired: {s}", .{ c.conf.wire.slot, path }) };
}

// poll until the health url answers 200; returns seconds, null on timeout
pub fn wakeTime(c: *Ctx, gpa: std.mem.Allocator) !?u32 {
    const urlz = try std.mem.concat(gpa, u8, &.{ c.stat.data.idsz.servUrl, c.conf.rend.heal });
    const star = std.Io.Clock.awake.now(c.io).toMilliseconds();
    const limi: i64 = @as(i64, c.conf.cold.wait) * CF.msecSecs;
    while (true) {
        const resp = c.rend.http.call(.{ .urlz = urlz }) catch null;
        if (resp) |r| {
            defer gpa.free(r.body);
            if (r.code == 200) return @intCast(@divTrunc(std.Io.Clock.awake.now(c.io).toMilliseconds() - star + CF.msecSecs - 1, CF.msecSecs));
        }
        if (std.Io.Clock.awake.now(c.io).toMilliseconds() - star >= limi) return null;
        try std.Io.sleep(c.io, .fromMilliseconds(@as(i64, c.conf.cold.poll) * CF.msecSecs), .awake);
    }
}

fn coldTest(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const secs = (try wakeTime(c, gpa)) orelse return .{ .skip = try std.fmt.allocPrint(gpa, "no 200 within {d}s: check the deploy in the dashboard, then run again", .{c.conf.cold.wait}) };
    c.stat.data.idsz.coldSecs = secs;
    const fits = secs <= c.conf.cold.wind;
    return .{ .okay = try std.fmt.allocPrint(gpa, "answered in {d}s (202 window {d}s): {s}", .{ secs, c.conf.cold.wind, if (fits) "fits" else "too slow, Schedule must retry" }) };
}

// worst case hours of the month for the free service vs the free pool
fn rendFina(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const hour = c.conf.limi.day * CF.hourDay * c.conf.rend.inst;
    const perc = hour * 100 / c.conf.limi.hour;
    const warn = if (perc >= c.conf.limi.warn) "  WARNING: near the free pool, idle spin-down is what keeps it lower" else "";
    return .{ .okay = try std.fmt.allocPrint(gpa, "free hours worst case {d} of {d} ({d}%){s}; url {s}", .{ hour, c.conf.limi.hour, perc, warn, c.stat.data.idsz.servUrl }) };
}

pub fn rows(ctx: *Ctx) [3]engi.Row {
    return .{
        ctxz.row(ctx, "wire-trig", "Write the url as Trigger C", false, wireTrig),
        ctxz.row(ctx, "cold-test", "Cold-start test vs the 202 window", false, coldTest),
        ctxz.row(ctx, "rend-fina", "Final check and report", false, rendFina),
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
