// =====================================================================
// Des: Runs the setup as a list of named steps from the step data. Each action checks first, acts only if missing, verifies, and the engine saves the mark. A guided step waits for the human and re-runs its action.
// Flo: for each row > skip if done > run action > done / skip / fail / wait > on wait: open page, show hint, poll or take g h b x > re-run the action > save state
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, step table (action name -> function)
// Out: Report{done, skipped, stop_at, code}; updated state file
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const conf = @import("co-cfg.zig");
const osyz = @import("co-os.zig");

const Ctx = ctxm.Ctx;

const CF = .{ .hintMaxz = 3, .exitFail = 1, .exitUsag = 2, .exitHand = 4 };

// why a step cannot go on: what / why / fix, one line each
pub const Fail = struct { what: []const u8, why: []const u8, fix: []const u8, code: u8 = CF.exitFail };

// a step that needs a click: the page to open, what to show, how to detect it
pub const Guid = struct {
    urlz: ?[]const u8 = null,
    clip: ?[]const u8 = null,
    lines: [CF.hintMaxz][]const u8 = .{ "", "", "" },
    poll: *const fn (*Ctx) anyerror!bool,
};

// what one action hands back
pub const Outc = union(enum) {
    done: []const u8,
    skip: []const u8,
    wait: Guid,
    fail: Fail,
};

pub const Action = fn (*Ctx) anyerror!Outc;

pub const Entry = struct { acts: []const u8, run: *const Action };

pub const Report = struct { done: u32 = 0, skipped: u32 = 0, stop_at: ?[]const u8 = null, code: u8 = 0 };

// how a guided wait ended
const Guided = enum { okay, stop, back };

fn find(table: []const Entry, acts: []const u8) ?*const Action {
    for (table) |item| if (std.mem.eql(u8, item.acts, acts)) return item.run;
    return null;
}

// print the failure as three short lines
pub fn failShow(ctx: *Ctx, fail: Fail) void {
    ctx.lastFail = std.fmt.allocPrint(ctx.a, "{s} | {s} | {s}", .{ fail.what, fail.why, fail.fix }) catch "";
    ctx.say("   failed: {s}\n   why: {s}\n   fix: {s}\n", .{ fail.what, fail.why, fail.fix });
    osyz.errz("failed: {s}\nwhy: {s}\nfix: {s}\n", .{ fail.what, fail.why, fail.fix });
}

// block on a guided step: open the page, show the hint, poll or take g/h/b/x
fn guide(ctx: *Ctx, guid: Guid) !Guided {
    const gcfg = ctx.conf.guid;
    if (guid.urlz) |urlz| {
        if (gcfg.open) _ = osyz.urlzOpen(ctx.io, ctx.a, urlz);
        ctx.say("   open: {s}\n", .{urlz});
    }
    if (guid.clip) |text| if (gcfg.clip) {
        _ = osyz.clipSetz(ctx.io, text);
    };
    for (guid.lines) |text| if (text.len > 0) ctx.say("   {s}\n", .{text});
    ctx.say("   waiting (g=done h=hint b=back x=stop): \n", .{});
    var left: u64 = gcfg.wait;
    while (true) {
        if (try guid.poll(ctx)) return .okay;
        if (ctx.line.wait(gcfg.poll)) |text| {
            if (std.mem.eql(u8, text, "g")) return .okay;
            if (std.mem.eql(u8, text, "x")) return .stop;
            if (std.mem.eql(u8, text, "b")) return .back;
            if (std.mem.eql(u8, text, "h")) ctx.say("   hint: finish the page, then type g\n", .{});
        }
        if (left <= gcfg.poll) return error.GuidTime;
        left -= gcfg.poll;
    }
}

// read-only: every row with its saved mark
pub fn plan(ctx: *Ctx) void {
    var hand: u32 = 0;
    for (ctx.steps.step) |row| {
        const mark = ctx.st.getz(row.iden).stat;
        const tag: []const u8 = switch (mark) {
            .done => "done",
            .skipped => "skip",
            .todo => "todo",
        };
        const kind: []const u8 = if (std.mem.eql(u8, row.kind, "guide")) "hand" else if (std.mem.eql(u8, row.kind, "ask")) "ask " else "auto";
        if (row.hand != 0) hand += 1;
        ctx.say("{d:0>2} [{s}] {s} {s}\n", .{ row.numb, tag, kind, row.name });
    }
    ctx.say("hand jobs in the list: {d}\n", .{hand});
}

// live sweep: runs each row's action, stops on the first stop or failure
pub fn run(ctx: *Ctx, table: []const Entry) !Report {
    var rep: Report = .{};
    for (ctx.steps.step) |row| {
        const saved = ctx.st.getz(row.iden).stat;
        if (saved == .done) {
            rep.done += 1;
            continue;
        }
        if (saved == .skipped) {
            rep.skipped += 1;
            continue;
        }
        const acti = find(table, row.acts) orelse {
            failShow(ctx, .{ .what = row.name, .why = "no action is named like that in the table", .fix = "fix df-steps.json (acts) or the table", .code = CF.exitUsag });
            rep.stop_at = row.iden;
            rep.code = CF.exitUsag;
            return rep;
        };
        ctx.say("\n{d:0>2} {s}\n", .{ row.numb, row.name });
        ctx.au.step = row.iden;
        var waits: u8 = 0;
        while (true) {
            const outc = acti(ctx) catch |erro| {
                failShow(ctx, .{ .what = row.name, .why = @errorName(erro), .fix = "see the audit log, then re-run: it resumes here" });
                try ctx.st.save(ctx.io);
                rep.stop_at = row.iden;
                rep.code = CF.exitFail;
                return rep;
            };
            switch (outc) {
                .done => |note| {
                    ctx.say("   done: {s}\n", .{note});
                    try ctx.st.setz(row.iden, .done, note, ctx.nowSecs());
                    try ctx.st.save(ctx.io);
                    rep.done += 1;
                },
                .skip => |note| {
                    ctx.say("   skipped: {s}\n", .{note});
                    try ctx.st.setz(row.iden, .skipped, note, ctx.nowSecs());
                    try ctx.st.save(ctx.io);
                    rep.skipped += 1;
                },
                .fail => |fail| {
                    failShow(ctx, fail);
                    try ctx.st.save(ctx.io);
                    rep.stop_at = row.iden;
                    rep.code = fail.code;
                    return rep;
                },
                .wait => |guid| {
                    if (waits == 0) ctx.handled += 1;
                    waits += 1;
                    if (waits > 2) {
                        failShow(ctx, .{ .what = row.name, .why = "still not detected after you confirmed", .fix = "do the page step again, then re-run" });
                        rep.stop_at = row.iden;
                        rep.code = CF.exitHand;
                        return rep;
                    }
                    const how = guide(ctx, guid) catch |erro| {
                        failShow(ctx, .{ .what = row.name, .why = @errorName(erro), .fix = "re-run, it resumes here", .code = CF.exitHand });
                        rep.stop_at = row.iden;
                        rep.code = CF.exitHand;
                        return rep;
                    };
                    switch (how) {
                        .stop => {
                            ctx.say("   stopped by you\n", .{});
                            rep.stop_at = row.iden;
                            rep.code = CF.exitHand;
                            return rep;
                        },
                        .back => waits = 0,
                        .okay => try ctx.handMark(row.iden),
                    }
                    continue;
                },
            }
            break;
        }
    }
    return rep;
}

// the closing report line
pub fn report(ctx: *Ctx, rep: Report) void {
    var todo: u32 = 0;
    for (ctx.steps.step) |row| {
        if (ctx.st.getz(row.iden).stat == .todo) todo += 1;
    }
    ctx.say("\n== report ==\ndone: {d}  skipped: {d}  to-do: {d}  hand jobs used: {d}\n", .{ rep.done, rep.skipped, todo, ctx.handled });
}

test "engine skips done rows, runs the rest, and stops on a failure with its code" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const a = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmpz.dir.realPath(std.testing.io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "state.json" });
    var st = try @import("co-state.zig").load(std.testing.io, a, path);
    try st.setz("a", .done, "pre", 1);
    var au: @import("co-audit.zig").Audi = .{ .io = std.testing.io, .path = "/dev/null/none", .fail = true };
    var diag = conf.Diag{};
    const cfg = try conf.confLoad(a, std.testing.io, "00-config.json", &diag);
    var ln = @import("co-line.zig").Inpu{ .io = std.testing.io };
    var env = std.process.Environ.Map.init(a);
    const steps: conf.Steps = .{ .vers = 1, .vend = "ggcr", .step = &.{
        .{ .numb = 0, .iden = "a", .kind = "auto", .acts = "ok", .hand = 0, .name = "A", .need = "", .done = "" },
        .{ .numb = 1, .iden = "b", .kind = "auto", .acts = "ok", .hand = 0, .name = "B", .need = "", .done = "" },
        .{ .numb = 2, .iden = "c", .kind = "auto", .acts = "bad", .hand = 0, .name = "C", .need = "", .done = "" },
        .{ .numb = 3, .iden = "d", .kind = "auto", .acts = "ok", .hand = 0, .name = "D", .need = "", .done = "" },
    } };
    var ctx: Ctx = .{ .a = a, .io = std.testing.io, .conf = &cfg, .steps = steps, .st = &st, .au = &au, .http = undefined, .tool = undefined, .auth = undefined, .gcp = undefined, .line = &ln, .env = &env, .root = "" };
    const okay = struct {
        fn f(_: *Ctx) anyerror!Outc {
            return .{ .done = "x" };
        }
    }.f;
    const bad = struct {
        fn f(_: *Ctx) anyerror!Outc {
            return .{ .fail = .{ .what = "w", .why = "y", .fix = "f", .code = 3 } };
        }
    }.f;
    const rep = try run(&ctx, &.{ .{ .acts = "ok", .run = okay }, .{ .acts = "bad", .run = bad } });
    try std.testing.expectEqual(@as(u8, 3), rep.code);
    try std.testing.expectEqual(@as(u32, 2), rep.done);
    try std.testing.expectEqualStrings("c", rep.stop_at.?);
    try std.testing.expectEqual(@import("co-state.zig").Mark.done, st.getz("b").stat);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
