// =====================================================================
// Des: Before a live publish, runs every app's tests in the work tree; the first red app stops the publish
// Flo: walk the work tree for build.zig (skip folders as in push) > run gate.cmd in each app folder > retry a red app up to gate.retr times > stop at the first still red
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: work tree path, Gate{ cmd, tmos_secs, retr }, skip folder names, a runner (real or a test double)
// Out: null = all green (or gate off) | Fail{ app, tail, tries }
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");

const CF = .{ .app_file = "build.zig", .tail_maxz = 600, .code_miss = 127, .code_kill = 255, .outp_maxz = 4 * 1024 * 1024 };

pub const Result = struct { code: u8, tail: []const u8 = "" };
pub const Run = *const fn (ctx: ?*anyopaque, dir: []const u8, argv: []const []const u8) Result;
pub const Fail = struct { app: []const u8, tail: []const u8, tries: u32 };

fn skipDir(skip: []const []const u8, name: []const u8) bool {
    for (skip) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

// app folders (relative, "." = the root itself), sorted so the order never changes between runs ----
pub fn apps(io: std.Io, a: std.mem.Allocator, from: []const u8, skip: []const []const u8) ![]const []const u8 {
    var src = try std.Io.Dir.cwd().openDir(io, from, .{ .iterate = true, .follow_symlinks = false });
    defer src.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var w = try src.walkSelectively(a);
    defer w.deinit();
    while (true) {
        const ent = (w.next(io) catch continue) orelse break;
        switch (ent.kind) {
            .directory => if (!skipDir(skip, ent.basename)) w.enter(io, ent) catch continue,
            .file => if (std.mem.eql(u8, ent.basename, CF.app_file)) {
                const d = std.fs.path.dirname(ent.path) orelse ".";
                try list.append(a, try a.dupe(u8, d));
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return list.items;
}

// the gate: null when green or off ----
pub fn gate(io: std.Io, a: std.mem.Allocator, g: conf.Gate, skip: []const []const u8, from: []const u8, run: Run, rctx: ?*anyopaque, say: *const fn (std.Io, []const u8) void) !?Fail {
    if (g.cmd.len == 0) return null;
    for (try apps(io, a, from, skip)) |app| {
        const dir = try std.fs.path.join(a, &.{ from, app });
        var tries: u32 = 0;
        while (true) {
            const r = run(rctx, dir, g.cmd);
            tries += 1;
            if (r.code == 0) break;
            if (tries > g.retr) return .{ .app = app, .tail = r.tail, .tries = tries };
            say(io, try std.fmt.allocPrint(a, "gate: {s} red, trying once more\n", .{app}));
        }
        say(io, try std.fmt.allocPrint(a, "gate: {s} green\n", .{app}));
    }
    return null;
}

// ---- the real runner: one child process with a deadline, in the app folder ----
pub const Real = struct { io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, tmos_secs: u32 };

pub fn realRun(ctx: ?*anyopaque, dir: []const u8, argv: []const []const u8) Result {
    const self: *Real = @ptrCast(@alignCast(ctx.?));
    const got = std.process.run(self.a, self.io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .environ_map = self.env,
        .stdout_limit = .limited(CF.outp_maxz),
        .stderr_limit = .limited(CF.outp_maxz),
        .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, self.tmos_secs) * std.time.ns_per_s), .clock = .awake } },
    }) catch |e| return .{ .code = if (e == error.FileNotFound) CF.code_miss else CF.code_kill, .tail = @errorName(e) };
    const code: u8 = switch (got.term) {
        .exited => |c| c,
        else => CF.code_kill,
    };
    const err = std.mem.trim(u8, got.stderr, " \r\n\t");
    return .{ .code = code, .tail = err[err.len -| CF.tail_maxz ..] };
}

// ---- tests: a scripted runner, a real temp tree ----
const Script = struct {
    seen: std.ArrayList([]const u8) = .empty,
    a: std.mem.Allocator,
    // app folder name that fails; failing_times = how many runs fail before it turns green
    bad: []const u8 = "",
    failing_times: u32 = 0,
    count: u32 = 0,

    fn run(ctx: ?*anyopaque, dir: []const u8, argv: []const []const u8) Result {
        _ = argv;
        const self: *Script = @ptrCast(@alignCast(ctx.?));
        self.seen.append(self.a, std.fs.path.basename(dir)) catch {};
        if (self.bad.len > 0 and std.mem.eql(u8, std.fs.path.basename(dir), self.bad)) {
            self.count += 1;
            if (self.count <= self.failing_times) return .{ .code = 1, .tail = "test boom" };
        }
        return .{ .code = 0 };
    }
};

fn quiet(_: std.Io, _: []const u8) void {}

fn tree(tmp: *std.testing.TmpDir) !void {
    const io = std.testing.io;
    for ([_][]const u8{ "v/beta", "v/alpha", "zig-out/ghost", "node_modules/x" }) |d| try tmp.dir.createDirPath(io, d);
    for ([_][]const u8{ "v/beta/build.zig", "v/alpha/build.zig", "zig-out/ghost/build.zig", "node_modules/x/build.zig", "readme.md" }) |f| try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });
}

test "apps: finds every folder with a build.zig, sorted, skipping the skip folders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(&tmp);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const got = try apps(std.testing.io, a, root, &.{ "zig-out", "node_modules" });
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("v/alpha", got[0]);
    try std.testing.expectEqualStrings("v/beta", got[1]);
}

test "gate: off with no command, green when all pass, stops at the first red app" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(&tmp);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const skip: []const []const u8 = &.{ "zig-out", "node_modules" };
    var s: Script = .{ .a = a };
    try std.testing.expect((try gate(std.testing.io, a, .{}, skip, root, Script.run, &s, quiet)) == null);
    try std.testing.expectEqual(@as(usize, 0), s.seen.items.len); // off: nothing runs
    const g: conf.Gate = .{ .cmd = &.{ "zig", "build", "test" }, .retr = 0 };
    try std.testing.expect((try gate(std.testing.io, a, g, skip, root, Script.run, &s, quiet)) == null);
    try std.testing.expectEqual(@as(usize, 2), s.seen.items.len);
    var red: Script = .{ .a = a, .bad = "alpha", .failing_times = 9 };
    const f = (try gate(std.testing.io, a, g, skip, root, Script.run, &red, quiet)).?;
    try std.testing.expectEqualStrings("v/alpha", f.app);
    try std.testing.expectEqualStrings("test boom", f.tail);
    try std.testing.expectEqual(@as(usize, 1), red.seen.items.len); // beta never ran: the first red stops the gate
}

test "gate: a red app is retried, a flake passes, a steady red fails after the last try" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(&tmp);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const skip: []const []const u8 = &.{ "zig-out", "node_modules" };
    const g: conf.Gate = .{ .cmd = &.{ "zig", "build", "test" }, .retr = 1 };
    var flaky: Script = .{ .a = a, .bad = "alpha", .failing_times = 1 };
    try std.testing.expect((try gate(std.testing.io, a, g, skip, root, Script.run, &flaky, quiet)) == null);
    var steady: Script = .{ .a = a, .bad = "alpha", .failing_times = 2 };
    const f = (try gate(std.testing.io, a, g, skip, root, Script.run, &steady, quiet)).?;
    try std.testing.expectEqual(@as(u32, 2), f.tries);
}

test "realRun: a missing tool says 127, a passing and a failing command give their exit codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var r: Real = .{ .io = std.testing.io, .a = a, .env = &env, .tmos_secs = 20 };
    try std.testing.expectEqual(@as(u8, 127), realRun(&r, ".", &.{"no-such-tool-xyz"}).code);
    try std.testing.expectEqual(@as(u8, 0), realRun(&r, ".", &.{ "zig", "version" }).code);
    try std.testing.expect(realRun(&r, ".", &.{ "zig", "no-such-subcommand" }).code != 0);
}
