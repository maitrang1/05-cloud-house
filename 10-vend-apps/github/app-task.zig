// =====================================================================
// Des: Local test and build - lists the app folders, gives each a short name, matches what you typed to apps, makes the jobs and runs them; nothing runs unless you pick apps
// Flo: walk the work tree for build.zig > match --app names (or --app-all) > make test or build jobs > run each in its folder (retry a red job) > report every job
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: work tree path, Task config, skip folder names, app names, optional target, a runner (real or a test double)
// Out: Outcome{ ok count, red jobs, green job indexes } ; the same short names name the cloud workflow files and release tags
// Run: not run directly - imported by root-main.zig and github-ci.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const seen = @import("edit-seen.zig");

const CF = .{ .app_file = "build.zig", .tail_maxz = 600, .code_miss = 127, .code_kill = 255, .outp_maxz = 4 * 1024 * 1024 };

pub const Result = struct { code: u8, tail: []const u8 = "" };
pub const Run = *const fn (ctx: ?*anyopaque, dir: []const u8, argv: []const []const u8) Result;
// name = the app, key = what `--app-edit` remembers it under (app|test, app|build:target) ----
pub const Job = struct { label: []const u8, path: []const u8, argv: []const []const u8, name: []const u8 = "", key: []const u8 = "" };
pub const Fail = struct { label: []const u8, tail: []const u8, tries: u32 };
pub const Outcome = struct { ok: u32 = 0, bad: []const Fail = &.{}, green: []const u32 = &.{} };

fn skipDir(skip: []const []const u8, name: []const u8) bool {
    for (skip) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

// app folders (relative to the tree), sorted so the order never changes between runs; the tree root itself is never an app ----
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
                const d = std.fs.path.dirname(ent.path) orelse continue;
                try list.append(a, try slashed(a, d));
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

fn slashed(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

// a folder path with slashes turned into dashes (10-vend-apps/github > 10-vend-apps-github) ----
pub fn flat(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try a.dupe(u8, std.mem.trim(u8, path, "/\\"));
    std.mem.replaceScalar(u8, out, '/', '-');
    std.mem.replaceScalar(u8, out, '\\', '-');
    return out;
}

pub const Named = struct { path: []const u8, name: []const u8 };

// the last n folder names of a path, joined with dashes ----
fn tail(a: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
    const p = std.mem.trim(u8, path, "/");
    var start: usize = p.len;
    var cuts: usize = 0;
    while (start > 0) : (start -= 1) {
        if (p[start - 1] == '/') {
            cuts += 1;
            if (cuts == n) break;
        }
    }
    return flat(a, p[start..]);
}

// every app's short name: its last folder (github); two apps with the same last folder both take their last two (facebook-scrape); a clash that is left, or a name with odd characters (it lands in YAML and shell), stops everything ----
pub fn namesAll(a: std.mem.Allocator, paths: []const []const u8) ![]const Named {
    var out: std.ArrayList(Named) = .empty;
    for (paths) |p| {
        const one = try tail(a, p, 1);
        var clash = false;
        for (paths) |o| if (!std.mem.eql(u8, o, p) and std.mem.eql(u8, try tail(a, o, 1), one)) {
            clash = true;
        };
        try out.append(a, .{ .path = p, .name = if (clash) try tail(a, p, 2) else one });
    }
    for (out.items, 0..) |x, i| {
        for (x.name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return error.BadName;
        for (out.items[0..i]) |y| if (std.mem.eql(u8, x.name, y.name)) return error.NameClash;
    }
    return out.items;
}

pub const Pick = union(enum) { ok: Named, none, many: []const Named };

// a query picks one app: its short name, its whole flat path, or the tail of that after a dash (10-vend-apps-github > github); two matches are refused ----
pub fn pick(a: std.mem.Allocator, list: []const Named, query: []const u8) !Pick {
    const q = try flat(a, query);
    if (q.len == 0) return .none;
    for (list) |x| if (std.mem.eql(u8, x.name, q)) return .{ .ok = x };
    var hits: std.ArrayList(Named) = .empty;
    for (list) |x| {
        const f = try flat(a, x.path);
        if (std.mem.eql(u8, f, q)) return .{ .ok = x };
        if (f.len > q.len and std.mem.endsWith(u8, f, q) and f[f.len - q.len - 1] == '-') try hits.append(a, x);
    }
    if (hits.items.len == 1) return .{ .ok = hits.items[0] };
    if (hits.items.len == 0) return .none;
    return .{ .many = hits.items };
}

// target names that match what the user typed: the whole name or a piece of it (windows > x86_64-windows) ----
pub fn targetsFor(a: std.mem.Allocator, all: []const []const u8, want: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |t| if (std.mem.eql(u8, t, want)) return a.dupe([]const u8, &.{t});
    for (all) |t| if (want.len > 0 and std.mem.indexOf(u8, t, want) != null) try out.append(a, t);
    return out.items;
}

pub fn testJobs(a: std.mem.Allocator, t: conf.Task, apps_: []const Named) ![]const Job {
    var out: std.ArrayList(Job) = .empty;
    for (apps_) |x| try out.append(a, .{ .label = x.name, .path = x.path, .argv = t.test_cmd, .name = x.name, .key = try seen.keyFor(a, x.name, false, null) });
    return out.items;
}

// no target = a plain native build into zig-out/bin; a target builds into its own zig-out/<target> so two targets never mix ----
pub fn buildJobs(a: std.mem.Allocator, t: conf.Task, apps_: []const Named, targets: []const []const u8) ![]const Job {
    var out: std.ArrayList(Job) = .empty;
    const opt = try std.fmt.allocPrint(a, "-Doptimize={s}", .{t.build_opt});
    for (apps_) |x| {
        const name = x.name;
        const p = x.path;
        if (targets.len == 0) {
            try out.append(a, .{ .label = name, .path = p, .argv = try a.dupe([]const u8, &.{ "zig", "build", opt }), .name = name, .key = try seen.keyFor(a, name, true, null) });
            continue;
        }
        for (targets) |tg| try out.append(a, .{
            .label = try std.fmt.allocPrint(a, "{s} ({s})", .{ name, tg }),
            .path = p,
            .argv = try a.dupe([]const u8, &.{ "zig", "build", try std.fmt.allocPrint(a, "-Dtarget={s}", .{tg}), opt, "-p", try std.fmt.allocPrint(a, "zig-out/{s}", .{tg}) }),
            .name = name,
            .key = try seen.keyFor(a, name, true, tg),
        });
    }
    return out.items;
}

// run every job in its app folder; a red job is retried, then reported, and the rest still run ----
pub fn runJobs(io: std.Io, a: std.mem.Allocator, t: conf.Task, from: []const u8, jobs: []const Job, run: Run, rctx: ?*anyopaque, say: *const fn (std.Io, []const u8) void) !Outcome {
    var bad: std.ArrayList(Fail) = .empty;
    var green: std.ArrayList(u32) = .empty;
    var ok: u32 = 0;
    for (jobs, 0..) |j, ji| {
        const dir = try std.fs.path.join(a, &.{ from, j.path });
        var tries: u32 = 0;
        var last: Result = .{ .code = 0 };
        while (true) {
            last = run(rctx, dir, j.argv);
            tries += 1;
            if (last.code == 0 or tries > t.retr) break;
            say(io, try std.fmt.allocPrint(a, "{s}: red, retrying\n", .{j.label}));
        }
        if (last.code == 0) {
            ok += 1;
            try green.append(a, @intCast(ji));
            say(io, try std.fmt.allocPrint(a, "{s}: green\n", .{j.label}));
        } else {
            try bad.append(a, .{ .label = j.label, .tail = last.tail, .tries = tries });
            say(io, try std.fmt.allocPrint(a, "{s}: RED\n", .{j.label}));
        }
    }
    return .{ .ok = ok, .bad = bad.items, .green = green.items };
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

// ---- tests ----
const Script = struct {
    seen: std.ArrayList([]const u8) = .empty,
    a: std.mem.Allocator,
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
    for ([_][]const u8{ "v/beta", "v/alpha", "w/alpha", "zig-out/ghost", "node_modules/x" }) |d| try tmp.dir.createDirPath(io, d);
    for ([_][]const u8{ "build.zig", "v/beta/build.zig", "v/alpha/build.zig", "w/alpha/build.zig", "zig-out/ghost/build.zig", "node_modules/x/build.zig", "readme.md" }) |f| try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });
}

test "apps: every folder with a build.zig, sorted, skip folders left out, the tree root is never an app" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tree(&tmp);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const got = try apps(std.testing.io, a, root, &.{ "zig-out", "node_modules" });
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("v/alpha", got[0]);
    try std.testing.expectEqualStrings("v/beta", got[1]);
    try std.testing.expectEqualStrings("w/alpha", got[2]);
}

test "namesAll: the last folder, the last two on a clash, a clash that is left stops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try namesAll(a, &.{ "05-jobs/facebook/scrape", "05-jobs/zalochat/scrape", "10-vend/github", "10-vend/gitlab" });
    try std.testing.expectEqualStrings("facebook-scrape", got[0].name);
    try std.testing.expectEqualStrings("zalochat-scrape", got[1].name);
    try std.testing.expectEqualStrings("github", got[2].name);
    try std.testing.expectEqualStrings("gitlab", got[3].name);
    try std.testing.expectEqualStrings("10-vend/github", got[2].path);
    // same last two folders too: no honest short name exists
    try std.testing.expectError(error.NameClash, namesAll(a, &.{ "a/x/scrape", "b/x/scrape" }));
    // a name with a quote, a space or a dollar would break the workflow file and its shell lines: refused
    try std.testing.expectError(error.BadName, namesAll(a, &.{ "v/it's", "v/beta" }));
    try std.testing.expectError(error.BadName, namesAll(a, &.{ "v/has space", "v/beta" }));
    try std.testing.expectError(error.BadName, namesAll(a, &.{ "v/$(x)" }));
    // a one-folder name that equals another app's two-folder name is also a clash
    try std.testing.expectError(error.NameClash, namesAll(a, &.{ "x/scrape", "y/x/scrape", "facebook-scrape", "z/facebook/scrape" }));
}

test "flat and pick: short name, flat path, tail of it, a path; never a piece of a word; two matches are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try namesAll(a, &.{ "05-jobs/facebook/scrape", "05-jobs/zalochat/scrape", "10-vend/github", "10-vend/gitlab" });
    try std.testing.expectEqualStrings("10-vend-github", try flat(a, "10-vend/github"));
    try std.testing.expectEqualStrings("10-vend/github", (try pick(a, list, "github")).ok.path);
    try std.testing.expectEqualStrings("10-vend/github", (try pick(a, list, "10-vend-github")).ok.path);
    try std.testing.expectEqualStrings("10-vend/github", (try pick(a, list, "10-vend/github/")).ok.path);
    try std.testing.expectEqualStrings("05-jobs/facebook/scrape", (try pick(a, list, "facebook-scrape")).ok.path);
    try std.testing.expect((try pick(a, list, "hub")) == .none); // a piece of a word is no match
    try std.testing.expect((try pick(a, list, "")) == .none);
    try std.testing.expect((try pick(a, list, "nothing")) == .none);
    try std.testing.expectEqual(@as(usize, 2), (try pick(a, list, "scrape")).many.len);
    // an exact short name wins over a longer name that only ends the same way
    const tricky = try namesAll(a, &.{ "10/github", "20/old-github" });
    try std.testing.expectEqualStrings("10/github", (try pick(a, tricky, "github")).ok.path);
    try std.testing.expectEqualStrings("20/old-github", (try pick(a, tricky, "old-github")).ok.path);
}

test "jobs: test uses the config command, build is native without a target and keeps one folder per target with one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t: conf.Task = .{};
    const two = try namesAll(a, &.{ "v/alpha", "v/beta" });
    const tj = try testJobs(a, t, two);
    try std.testing.expectEqual(@as(usize, 2), tj.len);
    try std.testing.expectEqualStrings("alpha", tj[0].label);
    try std.testing.expectEqualStrings("v/alpha", tj[0].path);
    try std.testing.expectEqualStrings("test", tj[0].argv[2]);
    try std.testing.expectEqualStrings("alpha|test", tj[0].key);
    const nat = try buildJobs(a, t, two[0..1], &.{});
    try std.testing.expectEqual(@as(usize, 1), nat.len);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSafe", nat[0].argv[2]);
    try std.testing.expectEqual(@as(usize, 3), nat[0].argv.len);
    try std.testing.expectEqualStrings("alpha|build:native", nat[0].key);
    const all: []const []const u8 = &.{ "x86_64-linux", "x86_64-windows" };
    const win = try targetsFor(a, all, "windows");
    try std.testing.expectEqual(@as(usize, 1), win.len);
    const cross = try buildJobs(a, t, two[0..1], win);
    try std.testing.expectEqualStrings("alpha (x86_64-windows)", cross[0].label);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-windows", cross[0].argv[2]);
    try std.testing.expectEqualStrings("zig-out/x86_64-windows", cross[0].argv[5]);
    try std.testing.expectEqualStrings("alpha|build:x86_64-windows", cross[0].key);
    try std.testing.expectEqualStrings("alpha", cross[0].name);
    try std.testing.expectEqual(@as(usize, 0), (try targetsFor(a, all, "macos")).len);
    try std.testing.expectEqual(@as(usize, 0), (try targetsFor(a, all, "")).len);
}

test "runJobs: green jobs count, a red job is retried then reported, the rest still run, a flake passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jobs: []const Job = &.{
        .{ .label = "alpha", .path = "alpha", .argv = &.{"x"} },
        .{ .label = "beta", .path = "beta", .argv = &.{"x"} },
        .{ .label = "gamma", .path = "gamma", .argv = &.{"x"} },
    };
    var s: Script = .{ .a = a };
    const clean = try runJobs(std.testing.io, a, .{ .retr = 0 }, "/t", jobs, Script.run, &s, quiet);
    try std.testing.expectEqual(@as(u32, 3), clean.ok);
    try std.testing.expectEqual(@as(usize, 3), clean.green.len);
    try std.testing.expectEqual(@as(usize, 0), clean.bad.len);
    var red: Script = .{ .a = a, .bad = "alpha", .failing_times = 9 };
    const r = try runJobs(std.testing.io, a, .{ .retr = 1 }, "/t", jobs, Script.run, &red, quiet);
    try std.testing.expectEqual(@as(u32, 2), r.ok); // gamma and beta still ran after alpha went red
    try std.testing.expectEqual(@as(usize, 2), r.green.len);
    try std.testing.expectEqual(@as(u32, 1), r.green[0]); // alpha (job 0) is not in the green list
    try std.testing.expectEqual(@as(usize, 1), r.bad.len);
    try std.testing.expectEqualStrings("alpha", r.bad[0].label);
    try std.testing.expectEqual(@as(u32, 2), r.bad[0].tries);
    try std.testing.expectEqualStrings("test boom", r.bad[0].tail);
    var flaky: Script = .{ .a = a, .bad = "alpha", .failing_times = 1 };
    const f = try runJobs(std.testing.io, a, .{ .retr = 1 }, "/t", jobs, Script.run, &flaky, quiet);
    try std.testing.expectEqual(@as(usize, 0), f.bad.len);
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
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
