// =====================================================================
// Des: Walks the 20-row step list in order, running each one's action, saving the result, and stopping cleanly on a wait, a stop or a failure
// Flo: for each row (resume past done ones) > look up its action > call it (chec or acts) > print the outcome > save state > next, or stop
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, the step table (name -> function), a starting index (0 = from the top)
// Out: Report{ done, skipped, todo, stop_at } ; state.json after every step
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const ctxm = @import("app-ctx.zig");
const conf = @import("config-load.zig");
const state = @import("state-file.zig");
const Ctx = ctxm.Ctx;
const Mode = ctxm.Mode;
const Outc = ctxm.Outc;

pub const Action = fn (*Ctx, Mode) anyerror!Outc;

pub const Entry = struct { acts: []const u8, run: *const Action };

pub const Report = struct { done: u32 = 0, skipped: u32 = 0, todo: u32 = 0, stop_at: ?[]const u8 = null, code: u8 = 0 };

fn find(table: []const Entry, acts: []const u8) ?*const Action {
    for (table) |e| if (std.mem.eql(u8, e.acts, acts)) return e.run;
    return null;
}

// read-only sweep: every row's current state, no side effects, no vault prompt ----
pub fn plan(ctx: *Ctx, table: []const Entry) anyerror!void {
    for (ctx.steps.step) |row| {
        const saved = ctx.stat.getz(row.iden).stat;
        var tag: []const u8 = switch (saved) {
            .done => "done",
            .skipped => "skip",
            .todo => "todo",
        };
        if (saved == .todo) {
            const acti = find(table, row.acts) orelse {
                ctx.say("{d:0>2} [????] {s} - no action named '{s}'\n", .{ row.numb, row.name, row.acts });
                continue;
            };
            const outc = acti(ctx, .chec) catch |e| {
                // NoPass/VaultFail here just means "needs --live to check the vault", not a real error ----
                if (e == error.NoPass or e == error.VaultFail) {
                    ctx.say("{d:0>2} [todo] {s} - needs --live to check\n", .{ row.numb, row.name });
                } else {
                    ctx.say("{d:0>2} [err?] {s} - {s}\n", .{ row.numb, row.name, @errorName(e) });
                }
                continue;
            };
            tag = switch (outc) {
                .done => "done",
                .skip => "skip",
                .wait => "wait",
                .back, .stop => "wait",
                .fail => "fail",
            };
        }
        ctx.say("{d:0>2} [{s: <4}] {s}\n", .{ row.numb, tag, row.name });
    }
}

// live sweep: runs each row's real action, stops on the first wait/stop/fail ----
pub fn run(ctx: *Ctx, table: []const Entry, mode: Mode) anyerror!Report {
    var rep: Report = .{};
    var i: usize = 0;
    while (i < ctx.steps.step.len) {
        const row = ctx.steps.step[i];
        const saved = ctx.stat.getz(row.iden);
        if (saved.stat == .done) {
            rep.done += 1;
            i += 1;
            continue;
        }
        if (saved.stat == .skipped) {
            rep.skipped += 1;
            i += 1;
            continue;
        }
        const acti = find(table, row.acts) orelse {
            ctx.say("{d:0>2} {s}: no action named '{s}'\n", .{ row.numb, row.name, row.acts });
            rep.stop_at = row.iden;
            rep.code = 2;
            return rep;
        };
        ctx.say("{d:0>2} {s}\n", .{ row.numb, row.name });
        const outc = acti(ctx, mode) catch |e| {
            ctx.say("   error: {s}\n", .{@errorName(e)});
            rep.stop_at = row.iden;
            rep.code = 1;
            try ctx.stat.save(ctx.io);
            return rep;
        };
        switch (outc) {
            .done => |note| {
                ctx.say("   done: {s}\n", .{note});
                try ctx.stat.setz(row.iden, .done, note, ctx.nowSecs());
                try ctx.stat.save(ctx.io);
                rep.done += 1;
                i += 1;
            },
            .skip => |note| {
                ctx.say("   {s}\n", .{note});
                try ctx.stat.setz(row.iden, .skipped, note, ctx.nowSecs());
                try ctx.stat.save(ctx.io);
                rep.skipped += 1;
                i += 1;
            },
            .wait => |note| {
                ctx.say("   waiting: {s}\n", .{note});
                try ctx.stat.save(ctx.io);
                rep.stop_at = row.iden;
                rep.code = 4;
                return rep;
            },
            .back => {
                if (i > 0) i -= 1;
            },
            .stop => {
                try ctx.stat.save(ctx.io);
                rep.stop_at = row.iden;
                rep.code = 4;
                return rep;
            },
            .fail => |f| {
                @import("out-text.zig").fail(ctx.io, f.what, f.why, f.fix);
                try ctx.stat.save(ctx.io);
                rep.stop_at = row.iden;
                rep.code = f.code;
                return rep;
            },
        }
    }
    return rep;
}

test "unknown action stops the run with exit 2; a done row is skipped on resume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(a);
    var st: state.State = .{ .a = a, .path = "" };
    try st.setz("a", .done, "ok", 1);
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    const steps: conf.Steps = .{ .vend = "gith", .step = &.{
        .{ .numb = 0, .iden = "a", .kind = .auto, .acts = "known", .name = "A" },
        .{ .numb = 1, .iden = "b", .kind = .auto, .acts = "missing", .name = "B" },
    } };
    var c: Ctx = .{ .io = io, .a = a, .env = &env, .conf = .{}, .steps = steps, .stat = &st, .audi = &au, .home = "/h", .root = "/r", .conf_dirz = "" };
    const noop = struct {
        fn f(ctx: *Ctx, m: Mode) anyerror!Outc {
            _ = ctx;
            _ = m;
            return .{ .done = "x" };
        }
    }.f;
    const rep = try run(&c, &.{.{ .acts = "known", .run = noop }}, .acts);
    try std.testing.expectEqual(@as(u32, 1), rep.done);
    try std.testing.expectEqual(@as(u8, 2), rep.code);
    try std.testing.expectEqualStrings("b", rep.stop_at.?);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
