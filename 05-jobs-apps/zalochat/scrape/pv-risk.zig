// Risk drill state for the personal tier (unofficial = can get an account locked). It either survives the drill or is cut.
// Any dead session / lock / rate-limit event CUTS the tier for that cust until an operator resets it. Passing = N clean days.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");

pub const Event = enum { ok, dead, rate, down };
pub const State = struct { ok_days: u32 = 0, last_ok_day: i64 = -1, cut: bool = false, events: u32 = 0, last_event: []const u8 = "" };
pub const Verdict = enum { drilling, passed, cut };

fn path(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) ![]u8 {
    return st.path(a, cust, "risk.json");
}

pub fn load(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) State {
    const t = util.readAll(a, st.io, path(st, a, cust) catch return .{}, 4096) catch return .{};
    return std.json.parseFromSliceLeaky(State, a, t, .{ .allocate = .alloc_always }) catch .{};
}

pub fn verdict(cx: *const ctx_mod.Ctx, s: State) Verdict {
    if (s.cut) return .cut;
    return if (s.ok_days >= cx.cfg.side.risk_days) .passed else .drilling;
}

pub fn record(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, ev: Event) void {
    var s = load(st, a, cust);
    const day = @divFloor(cx.nowMs(), store_mod.day_ms);
    switch (ev) {
        .ok => if (s.last_ok_day != day) {
            s.ok_days += 1;
            s.last_ok_day = day;
        },
        .dead, .rate => {
            s.cut = true;
            s.events += 1;
            s.last_event = @tagName(ev);
        },
        .down => {}, // network trouble is not the account's fault
    }
    const t = util.jsonStr(a, s) catch return;
    util.writeAtomic(a, st.io, path(st, a, cust) catch return, t) catch {};
    if (ev == .dead or ev == .rate) st.audit(cust, cx.nowMs(), "risk", "personal", 0, "tier_cut");
}

pub fn reset(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) !void {
    try util.writeAtomic(a, st.io, try path(st, a, cust), "{}");
}

test "risk: clean days pass, one event cuts, reset reopens" {
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
    cx.cfg.side.risk_days = 3;
    const st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    try st.ensure("alpha");
    var d: i64 = 0;
    while (d < 3) : (d += 1) {
        cx.fake_now_ms = (100 + d) * store_mod.day_ms + 5;
        record(&cx, &st, a, "alpha", .ok);
        record(&cx, &st, a, "alpha", .ok); // same day twice counts once
        try std.testing.expect(verdict(&cx, load(&st, a, "alpha")) == if (d < 2) Verdict.drilling else Verdict.passed);
    }
    record(&cx, &st, a, "alpha", .down);
    try std.testing.expect(verdict(&cx, load(&st, a, "alpha")) == .passed);
    record(&cx, &st, a, "alpha", .dead);
    try std.testing.expect(verdict(&cx, load(&st, a, "alpha")) == .cut);
    try reset(&st, a, "alpha");
    try std.testing.expect(verdict(&cx, load(&st, a, "alpha")) == .drilling);
}
