// =====================================================================
// Des: Talks to Cloud Monitoring: adds up this month's Cloud Run requests, vCPU-seconds and GiB-seconds, so the report can warn before the free grant runs out.
// Flo: for each of 3 metrics > time series for the month, summed > add the points
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, project id, month start, now
// Out: Use{reqs, vcpu, gibs}
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");
const http = @import("co-http.zig");
const date = @import("co-date.zig");

pub const Erro = error{MoniHttp};

const CF = .{ .metReqs = "run.googleapis.com/request_count", .metCpuz = "run.googleapis.com/container/cpu/allocation_time", .metMemo = "run.googleapis.com/container/memory/allocation_time", .alignSecs = 2678400 };

pub const Use = struct { reqs: f64 = 0, vcpu: f64 = 0, gibs: f64 = 0 };

// add up every point of every series in a timeSeries answer
pub fn sumPoints(val: std.json.Value) f64 {
    var total: f64 = 0;
    const series = gcp.obj(val, "timeSeries");
    if (series != .array) return 0;
    for (series.array.items) |ser| {
        const pts = gcp.obj(ser, "points");
        if (pts != .array) continue;
        for (pts.array.items) |pt| {
            const v = gcp.obj(gcp.obj(pt, "value"), "doubleValue");
            if (v == .float) total += v.float;
            if (v == .integer) total += @floatFromInt(v.integer);
            const n = gcp.obj(gcp.obj(pt, "value"), "int64Value");
            if (n != .null) total += @floatFromInt(gcp.int(n));
        }
    }
    return total;
}

// one metric, summed over the month
fn one(g: *gcp.Gcp, base: []const u8, proj: []const u8, metr: []const u8, from: []const u8, upto: []const u8) !f64 {
    const filt = try http.urlzEnco(g.a, try std.fmt.allocPrint(g.a, "metric.type=\"{s}\"", .{metr}));
    const urlz = try std.fmt.allocPrint(g.a, "{s}/v3/projects/{s}/timeSeries?filter={s}&interval.startTime={s}&interval.endTime={s}&aggregation.alignmentPeriod={d}s&aggregation.perSeriesAligner=ALIGN_SUM&aggregation.crossSeriesReducer=REDUCE_SUM", .{ base, proj, filt, try http.urlzEnco(g.a, from), try http.urlzEnco(g.a, upto), CF.alignSecs });
    const rep = try g.call(.GET, urlz, null);
    if (!rep.okay()) return error.MoniHttp;
    return sumPoints(rep.val);
}

// this month's use, from the 1st 00:00 UTC until now
pub fn usage(g: *gcp.Gcp, base: []const u8, proj: []const u8, nowz: i64) !Use {
    const from = try date.rfc3339(g.a, date.monthStart(nowz));
    const upto = try date.rfc3339(g.a, nowz);
    return .{ .reqs = try one(g, base, proj, CF.metReqs, from, upto), .vcpu = try one(g, base, proj, CF.metCpuz, from, upto), .gibs = try one(g, base, proj, CF.metMemo, from, upto) };
}

test "points are summed from int and double values" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const val = try std.json.parseFromSliceLeaky(std.json.Value, aren.allocator(), "{\"timeSeries\":[{\"points\":[{\"value\":{\"int64Value\":\"40\"}},{\"value\":{\"int64Value\":\"2\"}}]},{\"points\":[{\"value\":{\"doubleValue\":1.5}}]}]}", .{});
    try std.testing.expectApproxEqAbs(@as(f64, 43.5), sumPoints(val), 0.001);
    try std.testing.expectEqual(@as(f64, 0), sumPoints(.null));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
