// Run guard (NOT a scheduler - the hub fires jobs; see defs/hub-jobs.json): kill switch, per-cust pause after repeated failures, run log.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");

pub const Verdict = enum { go, killed, paused };

// kill switch = config flag OR a file <home>/KILL (an operator can drop it without editing config)
pub fn check(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, cust: []const u8) Verdict {
    if (cx.cfg.sche.kill_switch) return .killed;
    var buf: [512]u8 = undefined;
    const kp = std.fmt.bufPrint(&buf, "{s}/KILL", .{cx.home}) catch return .killed;
    if (util.exists(cx.io, kp)) return .killed;
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const pp = st.path(arena.allocator(), cust, "PAUSED") catch return .paused;
    if (util.exists(cx.io, pp)) return .paused;
    return .go;
}

// log a run result; N failures in a row -> DLQ line + PAUSED flag (state --resume clears it)
pub fn finish(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, cust: []const u8, job: []const u8, code: u8) void {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const now = cx.nowMs();
    const ln = std.fmt.allocPrint(a, "{d} {s} {d}", .{ now, job, code }) catch return;
    st.appendLog(cust, "runs.log", ln) catch return;
    if (code == 0) return;
    const txt = util.readAll(a, cx.io, st.path(a, cust, "runs.log") catch return, 16 * 1024 * 1024) catch return;
    var streak: u32 = 0;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |l| if (l.len > 0) lines.append(a, l) catch return;
    var i = lines.items.len;
    while (i > 0) : (i -= 1) {
        const l = lines.items[i - 1];
        const sp = std.mem.lastIndexOfScalar(u8, l, ' ') orelse break;
        const c = std.fmt.parseInt(u8, l[sp + 1 ..], 10) catch break;
        if (c == 0 or c == 3) break; // ok or a clean block stops the streak
        streak += 1;
    }
    if (streak >= cx.cfg.sche.max_fails) {
        const dl = std.fmt.allocPrint(a, "{{\"ts\":{d},\"job\":\"{s}\",\"fails\":{d},\"note\":\"paused after repeated failures\"}}", .{ now, job, streak }) catch return;
        st.appendLog(cust, "dlq-runs.jsonl", dl) catch {};
        const pp = st.path(a, cust, "PAUSED") catch return;
        util.writeAtomic(a, cx.io, pp, "paused\n") catch {};
    }
}

pub fn resume_(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, cust: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pp = try st.path(a, cust, "PAUSED");
    // keep history: clearing = rename the flag aside
    if (util.exists(cx.io, pp)) {
        const to = try std.fmt.allocPrint(a, "{s}.resumed-{d}", .{ pp, cx.nowMs() });
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(pp, cwd, to, cx.io);
    }
    // a marker line resets the failure streak
    try st.appendLog(cust, "runs.log", try std.fmt.allocPrint(a, "{d} resume 0", .{cx.nowMs()}));
}

test "kill switch (config and file) and pause after N failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(arena.allocator(), &env, home);
    cx.cfg.sche.max_fails = 3;
    const st = store_mod.Store.init(cx.io, cx.gpa, home);
    try st.ensure("demo");
    try std.testing.expect(check(&cx, &st, "demo") == .go);
    finish(&cx, &st, "demo", "scan", 1);
    finish(&cx, &st, "demo", "scan", 1);
    try std.testing.expect(check(&cx, &st, "demo") == .go);
    finish(&cx, &st, "demo", "scan", 1);
    try std.testing.expect(check(&cx, &st, "demo") == .paused);
    try std.testing.expect(check(&cx, &st, "other") == .go); // pause is per cust
    try resume_(&cx, &st, "demo");
    try std.testing.expect(check(&cx, &st, "demo") == .go);
    // a block (3) or ok (0) in between resets the streak
    finish(&cx, &st, "demo", "scan", 1);
    finish(&cx, &st, "demo", "scan", 3);
    finish(&cx, &st, "demo", "scan", 1);
    finish(&cx, &st, "demo", "scan", 1);
    try std.testing.expect(check(&cx, &st, "demo") == .go);
    cx.cfg.sche.kill_switch = true;
    try std.testing.expect(check(&cx, &st, "demo") == .killed);
    cx.cfg.sche.kill_switch = false;
    try util.writeAtomic(arena.allocator(), cx.io, try std.fmt.allocPrint(arena.allocator(), "{s}/KILL", .{home}), "x");
    try std.testing.expect(check(&cx, &st, "demo") == .killed);
}
