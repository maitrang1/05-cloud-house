// =====================================================================
// Des: Runs the setup as a list of named steps. Each step checks first, acts only if missing, then verifies. Skips what the state file already marks done, and a human can type g, h, b or x while it waits.
// Flo: for each step > read its mark > if todo, run it > on success mark done > on a guided step, wait for g or a poll > on x, stop and save
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: an ordered list of Step rows (each with a run function)
// Out: updated state file, a final report (done/skipped/to-do/hand jobs/limits)
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const inpu = @import("co-input.zig");
const stat = @import("co-state.zig");

const CF = .{ .hintMaxz = 3 };

// what one step hands back
pub const Done = union(enum) {
    okay: []const u8, // note saved in the state file
    askd: []const u8, // done, and a human typed a value: counts as a hand job
    skip: []const u8, // reason, logged but not a failure
    wait: Guid, // needs the human; the engine blocks here
};

// a step that needs a click: the page to open, what to show, how to detect it
pub const Guid = struct {
    urlz: ?[]const u8 = null,
    clip: ?[]const u8 = null,
    line: [CF.hintMaxz][]const u8,
    poll: *const fn (ctx: *anyopaque) anyerror!bool,
    ctx: *anyopaque,
    hand: bool = true, // counts toward the hand-job total in the report
};

// one row the engine runs
pub const Row = struct {
    iden: []const u8,
    name: []const u8,
    hand: bool = false,
    runz: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!Done,
    ctx: *anyopaque,
};

pub const Stop = error{EngiStop};

pub const Engi = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stat: *stat.Stat,
    inpu: *inpu.Inpu,
    guid: struct { open: bool, clip: bool, poll: u32, wait: u32 },
    hand: u32 = 0,
    done: u32 = 0,
    skip: u32 = 0,

    // run every row in order; stop early on x, resume later skips what is already done
    pub fn runAll(self: *Engi, rows: []const Row) !void {
        for (rows) |row| try self.runOne(row);
    }

    // runs one row; exposed (not just via runAll) so a caller can interleave
    // its own side effects between specific steps, e.g. in an end-to-end test
    pub fn runOne(self: *Engi, row: Row) !void {
        if (self.stat.markGetz(row.iden) == .done) return;
        osyz.outz(self.io, "\n[{s}] {s}\n", .{ row.iden, row.name });
        const done = row.runz(row.ctx, self.gpa) catch |erro| {
            osyz.errz("  failed: {s}\n", .{@errorName(erro)});
            return erro;
        };
        switch (done) {
            .okay, .askd => |note| {
                try self.stat.markSetz(row.iden, .done, note, std.Io.Clock.real.now(self.io).toMilliseconds());
                try self.stat.save();
                self.done += 1;
                if (done == .askd) self.hand += 1;
                osyz.outz(self.io, "  done: {s}\n", .{note});
            },
            .skip => |reas| {
                try self.stat.markSetz(row.iden, .skip, reas, std.Io.Clock.real.now(self.io).toMilliseconds());
                try self.stat.save();
                self.skip += 1;
                osyz.outz(self.io, "  skipped: {s}\n", .{reas});
            },
            .wait => |guid| {
                if (guid.hand) self.hand += 1;
                try self.wait(row, guid);
            },
        }
    }

    // block on a guided step: open the page, show the hint, poll or take g/h/b/x
    fn wait(self: *Engi, row: Row, guid: Guid) !void {
        if (guid.urlz) |urlz| {
            if (self.guid.open) _ = osyz.urlzOpen(self.io, self.gpa, urlz);
            osyz.outz(self.io, "  open: {s}\n", .{urlz});
        }
        if (guid.clip) |text| {
            if (self.guid.clip) _ = osyz.clipSetz(self.io, text);
        }
        for (guid.line) |line| if (line.len > 0) osyz.outz(self.io, "  {s}\n", .{line});
        osyz.outz(self.io, "  waiting (g=done h=hint b=back x=stop): ", .{});

        var left: u64 = self.guid.wait;
        while (true) {
            if (try guid.poll(guid.ctx)) break;
            if (self.inpu.wait(self.guid.poll)) |line| {
                defer self.gpa.free(line);
                if (std.mem.eql(u8, line, "g")) break;
                if (std.mem.eql(u8, line, "x")) return Stop.EngiStop;
                if (std.mem.eql(u8, line, "h")) {
                    osyz.outz(self.io, "  hint: watch the page, then type g\n", .{});
                    continue;
                }
                if (std.mem.eql(u8, line, "b")) return; // caller re-runs this step
            }
            if (left <= self.guid.poll) return error.GuidTime;
            left -= self.guid.poll;
        }
        try self.stat.markSetz(row.iden, .done, "guided", std.Io.Clock.real.now(self.io).toMilliseconds());
        try self.stat.save();
        self.done += 1;
        osyz.outz(self.io, "  done\n", .{});
    }

    // final one-page report
    pub fn report(self: *Engi, rows: []const Row) void {
        var todo: u32 = 0;
        for (rows) |row| {
            if (self.stat.markGetz(row.iden) == .todo) todo += 1;
        }
        osyz.outz(self.io, "\n== report ==\ndone: {d}  skipped: {d}  to-do: {d}  hand jobs used: {d}\n", .{ self.done, self.skip, todo, self.hand });
    }
};

test "engine skips what the state already marks done, runs the rest" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buff: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmpz.dir.realPath(std.testing.io, &buff);
    const path = try std.fs.path.join(gpa, &.{ buff[0..size], "state.json" });

    var seen: u32 = 0;
    const Ctx = struct { seen: *u32 };
    var ctx = Ctx{ .seen = &seen };
    const runz = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator) anyerror!Done {
            _ = g;
            const self: *Ctx = @ptrCast(@alignCast(c));
            self.seen.* += 1;
            return .{ .okay = "ok" };
        }
    }.f;
    const rows = [_]Row{
        .{ .iden = "a", .name = "step a", .runz = runz, .ctx = &ctx },
        .{ .iden = "b", .name = "step b", .runz = runz, .ctx = &ctx },
    };

    var st1 = try stat.Stat.load(gpa, std.testing.io, path);
    try st1.markSetz("a", .done, "pre", 1);
    try st1.save();

    var queu = inpu.Inpu{ .io = std.testing.io };
    var engi = Engi{ .gpa = gpa, .io = std.testing.io, .stat = &st1, .inpu = &queu, .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 5 } };
    try engi.runAll(&rows);
    try std.testing.expectEqual(@as(u32, 1), seen); // only "b" ran
    try std.testing.expectEqual(@as(u32, 1), engi.done);
}

test "x stops the run inside a guided step" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buff: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmpz.dir.realPath(std.testing.io, &buff);
    const path = try std.fs.path.join(gpa, &.{ buff[0..size], "state.json" });

    const neve = struct {
        fn f(c: *anyopaque) anyerror!bool {
            _ = c;
            return false;
        }
    }.f;
    const runz = struct {
        fn f(c: *anyopaque, g: std.mem.Allocator) anyerror!Done {
            _ = c;
            _ = g;
            return .{ .wait = .{ .line = .{ "a", "b", "c" }, .poll = neve, .ctx = undefined } };
        }
    }.f;
    const rows = [_]Row{.{ .iden = "sign", .name = "sign up", .hand = true, .runz = runz, .ctx = undefined }};

    var st1 = try stat.Stat.load(gpa, std.testing.io, path);
    var queu = inpu.Inpu{ .io = std.testing.io };
    try queu.list.append(gpa, try gpa.dupe(u8, "x"));
    var engi = Engi{ .gpa = gpa, .io = std.testing.io, .stat = &st1, .inpu = &queu, .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 30 } };
    try std.testing.expectError(error.EngiStop, engi.runAll(&rows));
    try std.testing.expectEqual(@as(u32, 1), engi.hand);
    try std.testing.expectEqual(Mark.todo, st1.markGetz("sign"));
}

const Mark = stat.Mark;

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
