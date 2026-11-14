// =====================================================================
// Des: `fetch` (pull the vault repo, write new secrets here) and `ship` (pack, commit, push) with a stale guard, so one device never overwrites a newer bundle another device shipped
// Flo: fetch: git fetch > compare > (go) pull > read bundle > write new files, keep or replace differing ones > remember the bundle sha | ship: clean vault > fetch > stale check > pull > pack > commit only the bundle > push > remember the sha
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Sync (flow Env, git runner, state file), passphrase, go / replace / rekey flags
// Out: FetchRes | ShipRes | SyncErro (`why` holds git's first complaint)
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const flow = @import("bundle-flow.zig");
const git_run = @import("git-run.zig");
const state = @import("sync-state.zig");

pub const SyncErro = error{ NoUpstream, GitFail, Diverged, Stale, DirtyVault, PushRejected, NoVaultGit } || flow.FlowErro || git_run.GitzErro || state.StateErro;

var why_buf: [256]u8 = undefined;
pub var why: []const u8 = "";

fn note(text: []const u8) void {
    const n = @min(text.len, why_buf.len);
    @memcpy(why_buf[0..n], text[0..n]);
    why = why_buf[0..n];
}

pub const Sync = struct { e: flow.Env, git: git_run.Git, state_file: []const u8 };

fn line(s: Sync, comptime fmt: []const u8, args: anytype) void {
    s.e.say(s.e.io, std.fmt.allocPrint(s.e.a, fmt, args) catch return);
}

fn quiet(_: std.Io, _: []const u8) void {}

// run git; any non-zero exit is a GitFail with git's first line in `why` ----
fn gok(s: Sync, args: []const []const u8) SyncErro!git_run.Res {
    const r = try s.git.run(args);
    if (!r.okay()) {
        note(r.why());
        return error.GitFail;
    }
    return r;
}

fn vaultGit(s: Sync) SyncErro!void {
    const g = std.fs.path.join(s.e.a, &.{ s.e.bundle_dir, ".git" }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().access(s.e.io, g, .{}) catch return error.NoVaultGit;
}

const Pos = struct { ahead: u32, behind: u32 };

fn position(s: Sync) SyncErro!Pos {
    const up = try s.git.run(&.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" });
    if (!up.okay()) return error.NoUpstream;
    const c = try gok(s, &.{ "rev-list", "--left-right", "--count", "HEAD...@{u}" });
    var it = std.mem.tokenizeAny(u8, c.text(), " \t");
    const a = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    const b = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    return .{ .ahead = a, .behind = b };
}

// the bundle as the vault's remote branch has it (when behind) or as the local file has it; null = no bundle yet ----
fn remoteBlob(s: Sync, pos: Pos) SyncErro!?[]const u8 {
    if (pos.behind > 0) {
        const spec = std.fmt.allocPrint(s.e.a, "@{{u}}:{s}", .{s.e.conf.bundle.path}) catch return error.OutOfMemory;
        const has = try s.git.run(&.{ "cat-file", "-e", spec });
        if (!has.okay()) return null;
        return (try gok(s, &.{ "cat-file", "blob", spec })).out;
    }
    return flow.readBundle(s.e) catch null;
}

// only the bundle file may differ from the last commit (a ship rebuilds it anyway); true when it does ----
fn onlyBundle(s: Sync) SyncErro!bool {
    const r = try gok(s, &.{ "status", "--porcelain" });
    var it = std.mem.tokenizeScalar(u8, r.out, '\n');
    var any = false;
    while (it.next()) |l| {
        if (l.len < 4 or !std.mem.eql(u8, std.mem.trim(u8, l[3..], "\""), s.e.conf.bundle.path)) return error.DirtyVault;
        any = true;
    }
    return any;
}

pub const FetchRes = struct { none: bool, behind: u32, un: flow.UnpackRes, conflicts: u32, synced: bool };

// go = false: read-only (git fetch only; the bundle is read straight from the remote branch) ----
pub fn fetch(s: Sync, pass: []const u8, go: bool, replace: bool, reseed: bool) SyncErro!FetchRes {
    try vaultGit(s);
    _ = try gok(s, &.{ "fetch", "-q" });
    const pos = try position(s);
    if (pos.behind > 0 and pos.ahead > 0) return error.Diverged;
    line(s, "vault repo: {d} new commit(s) to pull\n", .{pos.behind});
    var after = pos;
    if (go and pos.behind > 0) {
        _ = try gok(s, &.{ "pull", "-q", "--ff-only" });
        after.behind = 0;
    }
    const blob = (try remoteBlob(s, after)) orelse {
        line(s, "no bundle in the vault repo yet\n", .{});
        return .{ .none = true, .behind = pos.behind, .un = std.mem.zeroes(flow.UnpackRes), .conflicts = 0, .synced = false };
    };
    const r = try flow.unpackWith(s.e, pass, blob, go, replace, reseed);
    const conflicts: u32 = r.keeps;
    var synced = false;
    if (go and conflicts == 0) {
        try state.write(s.e.io, s.e.a, s.state_file, &flow.shaHex(blob));
        synced = true;
    }
    return .{ .none = false, .behind = pos.behind, .un = r, .conflicts = conflicts, .synced = synced };
}

// put the vault repo back where it was after a failed commit or push; the bundle is rebuilt by the next ship ----
fn undo(s: Sync, committed: bool) void {
    if (committed) _ = s.git.run(&.{ "reset", "-q", "--soft", "HEAD~1" }) catch {};
    _ = s.git.run(&.{ "restore", "--staged", "--", s.e.conf.bundle.path }) catch {};
    _ = s.git.run(&.{ "restore", "--", s.e.conf.bundle.path }) catch {};
}

pub const ShipRes = struct { shipped: bool, unchanged: bool, pack: flow.PackRes };

pub fn ship(s: Sync, pass: []const u8, go: bool, rekey: bool, reseed: bool) SyncErro!ShipRes {
    try vaultGit(s);
    _ = try onlyBundle(s);
    _ = try gok(s, &.{ "fetch", "-q" });
    const pos = try position(s);
    if (pos.behind > 0 and pos.ahead > 0) return error.Diverged;

    // stale guard: a bundle this device has not absorbed blocks the ship, unless this device already holds every file in it ----
    const applied = try state.read(s.e.io, s.e.a, s.state_file);
    if (try remoteBlob(s, pos)) |remote| {
        const sha = flow.shaHex(remote);
        if (applied == null or !std.mem.eql(u8, applied.?, &sha)) {
            var q = s.e;
            q.say = quiet;
            const r = try flow.unpackWith(q, pass, remote, false, true, false);
            if (r.new + r.differs > 0) return error.Stale;
            if (go) try state.write(s.e.io, s.e.a, s.state_file, &sha);
        }
    }
    if (!go) return .{ .shipped = false, .unchanged = false, .pack = try flow.pack(s.e, pass, false, rekey, reseed) };

    if (pos.behind > 0) _ = try gok(s, &.{ "pull", "-q", "--ff-only" });
    const p = try flow.pack(s.e, pass, true, rekey, reseed);
    // git decides what is left to ship: a bundle file an earlier failed ship left behind still counts ----
    if (!(try onlyBundle(s))) {
        try state.write(s.e.io, s.e.a, s.state_file, &flow.shaHex(try flow.readBundle(s.e)));
        return .{ .shipped = false, .unchanged = true, .pack = p };
    }
    _ = try gok(s, &.{ "add", "--", s.e.conf.bundle.path });
    const made = try s.git.run(&.{ "commit", "-q", "-m", s.e.conf.ship.message });
    if (!made.okay()) {
        note(made.why());
        undo(s, false);
        return error.GitFail;
    }
    const pushed = try s.git.run(&.{ "push", "-q" });
    if (!pushed.okay()) {
        note(pushed.why());
        undo(s, true);
        return error.PushRejected;
    }
    const mine = try flow.readBundle(s.e);
    try state.write(s.e.io, s.e.a, s.state_file, &flow.shaHex(mine));
    return .{ .shipped = true, .unchanged = false, .pack = p };
}

// ---- tests: real git, a bare remote and two vault clones; fake secrets only ----
const TEST_PASS = "correct horse battery";

const Rig = struct {
    a: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    env: *std.process.Environ.Map,

    fn git(self: Rig, dir: []const u8, args: []const []const u8) !git_run.Res {
        const g: git_run.Git = .{ .io = self.io, .a = self.a, .env = self.env, .root = dir };
        return g.run(args);
    }

    fn path(self: Rig, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.a, &.{ self.root, name });
    }

    fn put(self: Rig, rel: []const u8, data: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const full = try self.path(rel);
        if (std.fs.path.dirname(full)) |d| try cwd.createDirPath(self.io, d);
        try cwd.writeFile(self.io, .{ .sub_path = full, .data = data });
    }

    fn read(self: Rig, rel: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, try self.path(rel), self.a, .limited(1 << 20));
    }

    // a device: work repo W (plain folder), vault clone V, own state file ----
    fn sync(self: Rig, work: []const u8, vault: []const u8, state_name: []const u8) !Sync {
        var c: conf.Conf = .{};
        c.argon = .{ .time = 1, .memo_kbyt = 8, .para = 1 };
        const e: flow.Env = .{ .io = self.io, .a = self.a, .conf = c, .repo = try self.path(work), .bundle_dir = try self.path(vault), .pass_file = "", .trash = try self.path("trash"), .now_secs = 1_800_000_000, .say = quiet };
        const g: git_run.Git = .{ .io = self.io, .a = self.a, .env = self.env, .root = try self.path(vault), .tmos_secs = 30 };
        return .{ .e = e, .git = g, .state_file = try self.path(state_name) };
    }
};

fn rig(a: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !?Rig {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    const env = try a.create(std.process.Environ.Map);
    env.* = std.process.Environ.Map.init(a);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    try env.put("HOME", root);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    const r: Rig = .{ .a = a, .io = io, .root = root, .env = env };
    const ver = r.git(root, &.{"--version"}) catch |e| if (e == error.Missing) return null else return e;
    if (!ver.okay()) return null;
    _ = try r.git(root, &.{ "init", "-q", "--bare", "-b", "main", "remote.git" });
    for ([_][]const u8{ "VA", "VB" }) |v| {
        if (std.mem.eql(u8, v, "VB")) {
            _ = try r.git(root, &.{ "clone", "-q", "remote.git", v });
        } else {
            _ = try r.git(root, &.{ "clone", "-q", "remote.git", v });
            try r.put("VA/README.md", "vault");
            const d = try r.path(v);
            _ = try r.git(d, &.{ "config", "user.name", "t" });
            _ = try r.git(d, &.{ "config", "user.email", "t@t" });
            _ = try r.git(d, &.{ "add", "-A" });
            _ = try r.git(d, &.{ "commit", "-q", "-m", "init" });
            _ = try r.git(d, &.{ "branch", "-M", "main" });
            _ = try r.git(d, &.{ "push", "-q", "-u", "origin", "main" });
        }
    }
    // VB was cloned while the remote was still empty: point it at main now
    const vb = try r.path("VB");
    _ = try r.git(vb, &.{ "fetch", "-q" });
    _ = try r.git(vb, &.{ "checkout", "-q", "-B", "main", "origin/main" });
    _ = try r.git(vb, &.{ "config", "user.name", "t" });
    _ = try r.git(vb, &.{ "config", "user.email", "t@t" });
    return r;
}

test "ship from A, fetch on B; a stale ship is refused; keep protects a local edit; replace brings the new value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = (try rig(a, io, &tmp)) orelse return error.SkipZigTest;
    try r.put("A/p/.secrets/key", "KEY-1");
    try r.put("B/keep.txt", "unrelated");
    const sa = try r.sync("A", "VA", "stateA.json");
    const sb = try r.sync("B", "VB", "stateB.json");

    // A: a dry-run changes nothing; the real ship commits only the bundle and pushes it
    const dry = try ship(sa, TEST_PASS, false, false, false);
    try std.testing.expect(!dry.shipped);
    try std.testing.expect((try state.read(io, a, sa.state_file)) == null);
    const s1 = try ship(sa, TEST_PASS, true, false, false);
    try std.testing.expect(s1.shipped);
    try std.testing.expect((try state.read(io, a, sa.state_file)) != null);
    try std.testing.expect(!(try ship(sa, TEST_PASS, true, false, false)).shipped);

    // B: dry-run fetch lists, writes nothing; the real fetch writes the secret and remembers the bundle
    const fd = try fetch(sb, TEST_PASS, false, false, false);
    try std.testing.expectEqual(@as(u32, 1), fd.un.new);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, try r.path("B/p/.secrets/key"), .{}));
    const f1 = try fetch(sb, TEST_PASS, true, false, false);
    try std.testing.expect(f1.synced);
    try std.testing.expectEqualStrings("KEY-1", try r.read("B/p/.secrets/key"));
    const f2 = try fetch(sb, TEST_PASS, true, false, false);
    try std.testing.expectEqual(@as(u32, 1), f2.un.same);

    // A rotates the secret and ships; B (old bundle) is refused until it fetches
    try r.put("A/p/.secrets/key", "KEY-2");
    try std.testing.expect((try ship(sa, TEST_PASS, true, false, false)).shipped);
    try std.testing.expectError(error.Stale, ship(sb, TEST_PASS, true, false, false));

    // B edits the same secret by hand: fetch keeps the edit and does not claim to be in sync
    try r.put("B/p/.secrets/key", "MY-EDIT");
    const f3 = try fetch(sb, TEST_PASS, true, false, false);
    try std.testing.expectEqual(@as(u32, 1), f3.conflicts);
    try std.testing.expect(!f3.synced);
    try std.testing.expectEqualStrings("MY-EDIT", try r.read("B/p/.secrets/key"));
    try std.testing.expectError(error.Stale, ship(sb, TEST_PASS, true, false, false));

    // replace brings the new value; the edit is in the trash; now B is in sync and can ship (nothing changed)
    const f4 = try fetch(sb, TEST_PASS, true, true, false);
    try std.testing.expect(f4.synced);
    try std.testing.expectEqualStrings("KEY-2", try r.read("B/p/.secrets/key"));
    const s2 = try ship(sb, TEST_PASS, true, false, false);
    try std.testing.expect(!s2.shipped and s2.unchanged);
}

test "a device that already holds every file is not stale; a dirty vault, a missing remote and a wrong passphrase are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = (try rig(a, io, &tmp)) orelse return error.SkipZigTest;
    try r.put("A/x/.secrets/k", "SAME");
    try r.put("B/x/.secrets/k", "SAME");
    const sa = try r.sync("A", "VA", "stateA.json");
    const sb = try r.sync("B", "VB", "stateB.json");
    try std.testing.expect((try ship(sa, TEST_PASS, true, false, false)).shipped);
    // B never fetched (no state) but holds identical files: allowed, and it heals its state
    try std.testing.expect((try state.read(io, a, sb.state_file)) == null);
    const s = try ship(sb, TEST_PASS, true, false, false);
    try std.testing.expect(s.unchanged);
    try std.testing.expect((try state.read(io, a, sb.state_file)) != null);
    // a wrong passphrase never ships or fetches
    try r.put("A/x/.secrets/k", "CHANGED");
    try std.testing.expectError(error.PassDiffers, ship(sa, "another passphrase!!", true, false, false));
    // a stray file in the vault repo blocks a ship
    try r.put("VA/notes.txt", "x");
    try std.testing.expectError(error.DirtyVault, ship(sa, TEST_PASS, true, false, false));
    // an unreachable remote fails cleanly with git's first line
    const orig = try r.git(try r.path("VB"), &.{ "remote", "get-url", "origin" });
    _ = try r.git(try r.path("VB"), &.{ "remote", "set-url", "origin", try r.path("no-such-remote.git") });
    try std.testing.expectError(error.GitFail, fetch(sb, TEST_PASS, true, false, false));
    try std.testing.expect(why.len > 0);
    _ = try r.git(try r.path("VB"), &.{ "remote", "set-url", "origin", orig.text() });
}

test "a rejected push leaves the vault repo as it was and the state untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = (try rig(a, io, &tmp)) orelse return error.SkipZigTest;
    try r.put("A/p/.secrets/k", "K1");
    const sa = try r.sync("A", "VA", "stateA.json");
    try std.testing.expect((try ship(sa, TEST_PASS, true, false, false)).shipped);
    const head = (try r.git(try r.path("VA"), &.{ "rev-parse", "HEAD" })).text();
    const before = try r.read("VA/bundle-secret.enc");
    // the remote now refuses every push
    try r.put("remote.git/hooks/pre-receive", "#!/bin/sh\necho no >&2\nexit 1\n");
    _ = try r.git(try r.path("remote.git"), &.{ "config", "core.hooksPath", "hooks" });
    const hook = try r.path("remote.git/hooks/pre-receive");
    try std.Io.Dir.cwd().setFilePermissions(io, hook, .fromMode(0o755), .{});
    try r.put("A/p/.secrets/k", "K2");
    const st_before = (try state.read(io, a, sa.state_file)).?;
    try std.testing.expectError(error.PushRejected, ship(sa, TEST_PASS, true, false, false));
    try std.testing.expectEqualStrings(head, (try r.git(try r.path("VA"), &.{ "rev-parse", "HEAD" })).text());
    try std.testing.expectEqualSlices(u8, before, try r.read("VA/bundle-secret.enc"));
    try std.testing.expectEqualStrings(st_before, (try state.read(io, a, sa.state_file)).?);
    try std.testing.expectEqualStrings("", (try r.git(try r.path("VA"), &.{ "status", "--porcelain" })).text());
}
test "a failing commit hook is undone: the vault repo is clean again and the next ship works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = (try rig(a, io, &tmp)) orelse return error.SkipZigTest;
    try r.put("A/p/.secrets/k", "K1");
    const sa = try r.sync("A", "VA", "stateA.json");
    try r.put("VA/.git/hooks/pre-commit", "#!/bin/sh\necho blocked >&2\nexit 1\n");
    try std.Io.Dir.cwd().setFilePermissions(io, try r.path("VA/.git/hooks/pre-commit"), .fromMode(0o755), .{});
    try std.testing.expectError(error.GitFail, ship(sa, TEST_PASS, true, false, false));
    try std.testing.expectEqualStrings("blocked", why);
    try std.testing.expect((try state.read(io, a, sa.state_file)) == null);
    // hook removed: the leftover bundle file does not block the next ship
    try r.put("VA/.git/hooks/pre-commit", "#!/bin/sh\nexit 0\n");
    try std.testing.expect((try ship(sa, TEST_PASS, true, false, false)).shipped);
}
test "reseed through ship and fetch: A re-authorizes and ships it; B's fetch leaves its token, fetch --reseed takes A's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = (try rig(a, io, &tmp)) orelse return error.SkipZigTest;
    try r.put("A/p/.secrets/gg-token.json", "TOKEN-1");
    const sa = try r.sync("A", "VA", "stateA.json");
    const sb = try r.sync("B", "VB", "stateB.json");
    try std.testing.expect((try ship(sa, TEST_PASS, true, false, false)).shipped);
    _ = try fetch(sb, TEST_PASS, true, false, false);
    // A re-authorizes: a plain ship sends nothing, ship --reseed sends the new token
    try r.put("A/p/.secrets/gg-token.json", "TOKEN-NEW-AUTH");
    try std.testing.expect(!(try ship(sa, TEST_PASS, true, false, false)).shipped);
    try std.testing.expect((try ship(sa, TEST_PASS, true, false, true)).shipped);
    // B: the new bundle does not touch its token and is no conflict; --reseed takes A's (old copy to the trash)
    const plain = try fetch(sb, TEST_PASS, true, false, false);
    try std.testing.expectEqual(@as(u32, 0), plain.conflicts);
    try std.testing.expectEqualStrings("TOKEN-1", try r.read("B/p/.secrets/gg-token.json"));
    const seeded = try fetch(sb, TEST_PASS, true, false, true);
    try std.testing.expect(seeded.synced);
    try std.testing.expectEqual(@as(u32, 1), seeded.un.counts.replaced);
    try std.testing.expectEqualStrings("TOKEN-NEW-AUTH", try r.read("B/p/.secrets/gg-token.json"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
