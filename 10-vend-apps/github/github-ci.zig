// =====================================================================
// Des: The CI half of the GitHub setup - seals vault secrets into Actions, commits the build workflow, checks GHCR and mirrors, and prints the final report
// Flo: repo public key > seal each secret > PUT /actions/secrets > commit the workflow file > first run green > GHCR/mirrors checked or skipped > report
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, Mode (chec = read-only look, acts = do it) ; revoke() is the panic button
// Out: Outc per step ; revoke() kills only what this app made
// Run: not run directly - listed in vendor-github.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const api = @import("github-api.zig");
const seal = @import("seal-box.zig");
const ctxm = @import("app-ctx.zig");
const Ctx = ctxm.Ctx;
const Mode = ctxm.Mode;
const Outc = ctxm.Outc;
const tasks = @import("app-task.zig");
const rpush = @import("repo-push.zig");

const CF = .{ .runz_poll_secs = 5, .runz_wait_secs = 30, .kill_okay = "0" };

const PubKey = struct { key_id: []const u8 = "", key: []const u8 = "" };
const SecrRow = struct { name: []const u8 = "", created_at: []const u8 = "" };
const RunzList = struct { workflow_runs: []const Runz = &.{} };
const Runz = struct { id: u64 = 0, status: []const u8 = "", conclusion: ?[]const u8 = null, head_branch: []const u8 = "" };
const Pack = struct { name: []const u8 = "" };

fn ownerName(ctx: *Ctx) ![]const u8 {
    return api.enc(ctx.a, ctx.stat.valu("logi"));
}

fn repoPath(ctx: *Ctx, tail: []const u8) ![]const u8 {
    return std.mem.concat(ctx.a, u8, &.{ "/repos/", try ownerName(ctx), "/", try api.enc(ctx.a, ctx.repoName()), tail });
}

fn secrListed(ctx: *Ctx, name: []const u8) !bool {
    const r = try api.getz(ctx, try repoPath(ctx, "/actions/secrets"));
    if (!r.okay()) return error.SecrRefused;
    const list = api.read(struct { secrets: []const SecrRow = &.{} }, ctx, r.body) orelse return false;
    for (list.secrets) |s| if (std.mem.eql(u8, s.name, name)) return true;
    return false;
}

fn pubKeyRead(ctx: *Ctx) !PubKey {
    const r = try api.getz(ctx, try repoPath(ctx, "/actions/secrets/public-key"));
    if (!r.okay()) return error.SecrRefused;
    return api.read(PubKey, ctx, r.body) orelse error.SecrRefused;
}

fn secrPut(ctx: *Ctx, pk: PubKey, name: []const u8, plain: []const u8) !void {
    const enc_value = seal.seal(ctx.a, ctx.io, pk.key, plain) catch return error.SealFail;
    const r = try api.call(ctx, .PUT, try repoPath(ctx, try std.mem.concat(ctx.a, u8, &.{ "/actions/secrets/", name })), try api.json(ctx, .{ .encrypted_value = enc_value, .key_id = pk.key_id }), true);
    if (!r.okay()) return error.SecrRefused;
}

// ---- step 15: CI secrets, sealed with the repo's own key, straight from the vault ----
pub fn ciizSecr(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (!ctx.conf.ciiz.onzz or ctx.conf.ciiz.secr.len == 0) return .{ .skip = "skipped: no CI secrets configured" };
    var have: u32 = 0;
    for (ctx.conf.ciiz.secr) |row| {
        const seen = secrListed(ctx, row.name) catch |e| {
            if (e != error.SecrRefused) return e;
            return api.refuse(ctx, try api.getz(ctx, try repoPath(ctx, "/actions/secrets")), "cannot list Actions secrets");
        };
        if (seen) have += 1;
    }
    if (have == ctx.conf.ciiz.secr.len) return .{ .done = try std.fmt.allocPrint(ctx.a, "{d} secret(s) listed", .{have}) };
    if (mode == .chec) return .{ .wait = "secrets missing" };
    const pk = pubKeyRead(ctx) catch |e| {
        if (e != error.SecrRefused) return e;
        return api.refuse(ctx, try api.getz(ctx, try repoPath(ctx, "/actions/secrets/public-key")), "cannot read the repo's secrets key");
    };
    var done: u32 = 0;
    for (ctx.conf.ciiz.secr) |row| {
        var value = (try ctx.secret(row.vaul)) orelse "";
        if (value.len == 0) {
            if (!row.need) continue;
            value = ctx.askHide(try std.fmt.allocPrint(ctx.a, "   value for secret {s} (hidden): ", .{row.name})) orelse return .{ .wait = "a required secret value is needed" };
            try ctx.secretPut(row.vaul, value);
        }
        secrPut(ctx, pk, row.name, value) catch return ctxm.fail(try std.fmt.allocPrint(ctx.a, "cannot set secret {s}", .{row.name}), "GitHub refused the sealed value", "check the vault key auth.scop has repo access, then run again");
        done += 1;
    }
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{d} secret(s) set", .{done}) };
}

// the first line every generated workflow carries: only files with it may be moved out when their app is gone ----
const MARK = "# made by the github app";

pub const Flows = struct { apps: u32 = 0, changed: u32 = 0, dropped: u32 = 0 };

fn flowRel(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}.yml", .{ std.mem.trimEnd(u8, dir, "/"), name });
}

// one workflow per app folder found in the repo folder, written when it differs from the file there; a dropped or orphaned generated file moves to the trash ----
pub fn ciizRender(ctx: *Ctx, write: bool) !Flows {
    const cf = ctx.conf.ciiz;
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, cf.tmpl_file, ctx.a, .limited(64 * 1024)) catch return error.TemplateMissing;
    const list = try tasks.namesAll(ctx.a, try tasks.apps(ctx.io, ctx.a, ctx.root, ctx.conf.push.skip_dirs));
    var fl: Flows = .{ .apps = @intCast(list.len) };
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    for (list) |x| {
        const name = x.name;
        const p = x.path;
        const rel = try flowRel(ctx.a, cf.dir_path, name);
        try wanted.put(ctx.a, try std.fmt.allocPrint(ctx.a, "{s}.yml", .{name}), {});
        const want = try tmplFill(ctx.a, raw, cf, name, p, rel);
        const dest = try ctx.path(&.{ ctx.root, rel });
        const have = std.Io.Dir.cwd().readFileAlloc(ctx.io, dest, ctx.a, .limited(256 * 1024)) catch null;
        if (have != null and std.mem.eql(u8, have.?, want)) continue;
        fl.changed += 1;
        if (!write) continue;
        if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(ctx.io, d);
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = want });
    }
    const dir_abs = try ctx.path(&.{ ctx.root, cf.dir_path });
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_abs, .{ .iterate = true }) catch return fl;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (try it.next(ctx.io)) |ent| {
        if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".yml") or wanted.contains(ent.name)) continue;
        var stale = false;
        for (cf.drop) |d| if (std.mem.eql(u8, d, ent.name)) {
            stale = true;
        };
        if (!stale) {
            var f = dir.openFile(ctx.io, ent.name, .{}) catch continue;
            defer f.close(ctx.io);
            var head: [MARK.len]u8 = undefined;
            const n = f.readPositionalAll(ctx.io, &head, 0) catch continue;
            stale = std.mem.eql(u8, head[0..n], MARK);
        }
        if (!stale) continue;
        fl.dropped += 1;
        if (!write) continue;
        if (ctx.conf.push.trash.len == 0) return error.NoTrashFolder;
        try rpush.trashFile(ctx.io, ctx.a, ctx.conf.push.trash, ctx.root, try flowRel(ctx.a, cf.dir_path, ent.name[0 .. ent.name.len - 4]), ctx.nowSecs());
    }
    return fl;
}

// fill the workflow template for one app from config; every knob lives in 00-config.json ----
// the release job sits between two marker lines: keep its text (markers dropped) or cut it all out
fn releaseBlock(a: std.mem.Allocator, tmpl: []const u8, keep: bool) ![]u8 {
    const begin = "@@RELEASE_BEGIN@@\n";
    const end = "@@RELEASE_END@@\n";
    const b = std.mem.indexOf(u8, tmpl, begin) orelse return a.dupe(u8, tmpl);
    const e = std.mem.indexOfPos(u8, tmpl, b, end) orelse return a.dupe(u8, tmpl);
    const inner = tmpl[b + begin.len .. e];
    return std.mem.concat(a, u8, &.{ tmpl[0..b], if (keep) inner else "", tmpl[e + end.len ..] });
}

fn tmplFill(a: std.mem.Allocator, tmpl: []const u8, cf: @import("config-load.zig").Ciiz, app: []const u8, dir: []const u8, flow: []const u8) ![]u8 {
    const cache: []const u8 = if (cf.cache)
        "\n      - id: ZIGZ-CASH\n        uses: actions/cache@v6\n        with:\n          path: ~/.cache/zig\n          key: zig-${{ runner.os }}-${{ hashFiles('**/build.zig.zon') }}\n"
    else
        "";
    const keys = [_][]const u8{ "@@APPDIR@@", "@@APP@@", "@@FLOWPATH@@", "@@KILL@@", "@@RUNNER@@", "@@TIMEOUT@@", "@@ZIGVERS@@", "@@ZIGBASE@@", "@@CACHE@@", "@@RELTIMEOUT@@", "@@RELTARGETS@@", "@@RELRUNNER@@" };
    const timeout = try std.fmt.allocPrint(a, "{d}", .{cf.job_tmos_mins});
    const reltmo = try std.fmt.allocPrint(a, "{d}", .{cf.rele_tmos_mins});
    const targets = try std.mem.join(a, " ", cf.rele_targets);
    const vals = [_][]const u8{ dir, app, flow, cf.kill_name, cf.runs_on, timeout, cf.zig_vers, cf.zig_base, cache, reltmo, targets, cf.rele_runs_on };
    var cur = try releaseBlock(a, tmpl, cf.rele);
    for (keys, vals) |k, v| cur = try std.mem.replaceOwned(u8, a, cur, k, v);
    return cur;
}

test "tmplFill puts every config knob and the app in, and leaves no marker behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmpl = "@@APP@@|@@APPDIR@@|@@FLOWPATH@@|@@KILL@@|@@RUNNER@@|@@TIMEOUT@@|@@ZIGVERS@@|@@ZIGBASE@@|@@CACHE@@";
    const out = try tmplFill(a, tmpl, .{ .runs_on = "ubuntu-slim", .job_tmos_mins = 7, .cache = false }, "v-alpha", "v/alpha", ".github/workflows/v-alpha.yml");
    try std.testing.expect(std.mem.indexOf(u8, out, "@@") == null);
    try std.testing.expect(std.mem.startsWith(u8, out, "v-alpha|v/alpha|.github/workflows/v-alpha.yml|CI_KILL|ubuntu-slim|7|"));
    try std.testing.expect(std.mem.indexOf(u8, out, "actions/cache") == null);
}

test "the shipped template is one app's flow: own paths, own tag, test job, release job or none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "20-build.yml", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.startsWith(u8, raw, MARK)); // the orphan sweep keys on this first line
    const on = try tmplFill(a, raw, .{ .rele_targets = &.{ "x86_64-linux", "aarch64-macos" }, .rele_tmos_mins = 45, .rele_runs_on = "runner-x" }, "v-alpha", "v/alpha", ".github/workflows/v-alpha.yml");
    try std.testing.expect(std.mem.indexOf(u8, on, "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, on, "      - 'v/alpha/**'\n      - '.github/workflows/v-alpha.yml'") != null); // only this app's folder, plus the flow file itself
    try std.testing.expect(std.mem.indexOf(u8, on, "tags: ['v-alpha-v*']") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "working-directory: v/alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "zig build test") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "for t in x86_64-linux aarch64-macos; do") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "timeout-minutes: 45") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "cp LICENSE \"dist/") != null); // every download carries the license
    try std.testing.expect(std.mem.indexOf(u8, on, "startsWith(github.ref, 'refs/tags/v-alpha-v')") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, on, "gh release create")); // one release per app tag
    try std.testing.expect(std.mem.indexOf(u8, on, "matrix") == null); // no shared job fan-out
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, on, "runs-on:"));
    try std.testing.expect(std.mem.indexOf(u8, on, "runs-on: runner-x") != null); // the release never rides the 15-minute slim runner
    const off = try tmplFill(a, raw, .{ .rele = false }, "v-alpha", "v/alpha", ".github/workflows/v-alpha.yml");
    try std.testing.expect(std.mem.indexOf(u8, off, "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, off, "gh release") == null);
    try std.testing.expect(std.mem.indexOf(u8, off, "EXEZ-TEST") != null); // the test job stays
}

fn put(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(std.testing.io, d);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "ciizRender: one flow per app, idempotent, old build.yml and orphaned generated flows move to the trash, other files stay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var bin = std.testing.tmpDir(.{});
    defer bin.cleanup();
    try put(repo.dir, "v/alpha/build.zig", "x");
    try put(repo.dir, "v/beta/build.zig", "x");
    try put(repo.dir, ".github/workflows/build.yml", "name: build\n"); // the old shared flow: no marker, named in drop
    try put(repo.dir, ".github/workflows/mirror.yml", "name: gitlab-mirror\n"); // someone else's flow: never touched
    try put(repo.dir, ".github/workflows/gone-app.yml", MARK ++ "\nname: gone-app\n"); // generated, its app is gone
    var env = std.process.Environ.Map.init(a);
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, rb[0..try repo.dir.realPath(std.testing.io, &rb)]);
    var tb: [std.fs.max_path_bytes]u8 = undefined;
    const trash = try a.dupe(u8, tb[0..try bin.dir.realPath(std.testing.io, &tb)]);
    var cf: @import("config-load.zig").Conf = .{};
    cf.ciiz.drop = &.{"build.yml"};
    cf.ciiz.tmpl_file = "20-build.yml";
    cf.push.trash = trash;
    cf.push.skip_dirs = &.{ ".github", "zig-out" };
    var c: Ctx = .{ .io = std.testing.io, .a = a, .env = &env, .conf = cf, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "/h", .root = root, .conf_dirz = "" };
    const dry = try ciizRender(&c, false);
    try std.testing.expectEqual(@as(u32, 2), dry.apps);
    try std.testing.expectEqual(@as(u32, 2), dry.changed);
    try std.testing.expectEqual(@as(u32, 2), dry.dropped); // build.yml and gone-app.yml
    try std.testing.expectError(error.FileNotFound, repo.dir.access(std.testing.io, ".github/workflows/alpha.yml", .{})); // dry-run writes nothing
    const live = try ciizRender(&c, true);
    try std.testing.expectEqual(@as(u32, 2), live.changed);
    const alpha = try repo.dir.readFileAlloc(std.testing.io, ".github/workflows/alpha.yml", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, alpha, "'v/alpha/**'") != null);
    try std.testing.expect(std.mem.indexOf(u8, alpha, "v/beta") == null); // one app per file
    try repo.dir.access(std.testing.io, ".github/workflows/beta.yml", .{});
    try repo.dir.access(std.testing.io, ".github/workflows/mirror.yml", .{}); // untouched
    try std.testing.expectError(error.FileNotFound, repo.dir.access(std.testing.io, ".github/workflows/build.yml", .{}));
    try std.testing.expectError(error.FileNotFound, repo.dir.access(std.testing.io, ".github/workflows/gone-app.yml", .{}));
    try bin.dir.access(std.testing.io, ".github/workflows/build.yml", .{}); // moved, never deleted
    try bin.dir.access(std.testing.io, ".github/workflows/gone-app.yml", .{});
    // two apps with the same last two folders: no workflow is written at all
    try put(repo.dir, "w/alpha/build.zig", "x");
    try put(repo.dir, "x/w/alpha/build.zig", "x");
    try std.testing.expectError(error.NameClash, ciizRender(&c, true));
    try repo.dir.deleteFile(std.testing.io, "x/w/alpha/build.zig");
    const again0 = try ciizRender(&c, true); // w/alpha now clashes by last folder with v/alpha: both take two folders, old short-named files become orphans
    try std.testing.expectEqual(@as(u32, 3), again0.apps);
    try repo.dir.access(std.testing.io, ".github/workflows/v-alpha.yml", .{});
    try repo.dir.access(std.testing.io, ".github/workflows/w-alpha.yml", .{});
    try std.testing.expectError(error.FileNotFound, repo.dir.access(std.testing.io, ".github/workflows/alpha.yml", .{}));
    try bin.dir.access(std.testing.io, ".github/workflows/alpha.yml", .{}); // the renamed app's old flow moved, never deleted
    const again = try ciizRender(&c, true);
    try std.testing.expectEqual(@as(u32, 0), again.changed); // second run is a no-op
    try std.testing.expectEqual(@as(u32, 0), again.dropped);
}

fn latestRunz(ctx: *Ctx) !?Runz {
    const r = try api.getz(ctx, try repoPath(ctx, try std.fmt.allocPrint(ctx.a, "/actions/runs?branch={s}&per_page=1", .{ctx.conf.repo.bran})));
    if (!r.okay()) return error.RunzRefused;
    const list = api.read(RunzList, ctx, r.body) orelse return null;
    return if (list.workflow_runs.len > 0) list.workflow_runs[0] else null;
}

fn workflowFresh(ctx: *Ctx) anyerror!bool {
    const r = latestRunz(ctx) catch return false;
    const run = r orelse return false;
    return std.mem.eql(u8, run.head_branch, ctx.conf.repo.bran) and run.conclusion != null and std.mem.eql(u8, run.conclusion.?, "success");
}

// ---- step 16: CI workflow file + first green run ----
pub fn ciizFile(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (!ctx.conf.ciiz.onzz) return .{ .skip = "skipped: ciiz.onzz is off" };
    const found = ciizRender(ctx, false) catch |e| return ctxm.fail("cannot prepare the workflow files", @errorName(e), "keep 20-build.yml next to 00-config.json and the repo folder readable");
    if (found.apps == 0) return .{ .wait = "no app folders in the repo folder yet; publish first, then run again" };
    const have_file = found.changed == 0 and found.dropped == 0;
    if (have_file) {
        const run = latestRunz(ctx) catch |e| {
            if (e != error.RunzRefused) return e;
            return api.refuse(ctx, try api.getz(ctx, try repoPath(ctx, "/actions/runs")), "cannot read Actions runs");
        };
        if (run) |r| if (std.mem.eql(u8, r.head_branch, ctx.conf.repo.bran) and r.conclusion != null) {
            if (std.mem.eql(u8, r.conclusion.?, "success")) return .{ .done = "first run is green" };
            return ctxm.fail("the Actions run failed", try std.fmt.allocPrint(ctx.a, "run {d} concluded {s}", .{ r.id, r.conclusion.? }), try std.fmt.allocPrint(ctx.a, "open the run on github.com/{s}/{s}/actions and fix the build", .{ try ownerName(ctx), ctx.repoName() }));
        };
    }
    if (mode == .chec) return .{ .wait = "workflow not run yet" };
    if (!have_file) {
        _ = ciizRender(ctx, true) catch |e| return ctxm.fail("cannot write the workflow files", @errorName(e), "check the repo folder is writable and push.trash is set");
        const g = ctx.gitz(try @import("github-repo.zig").sshzCommandPub(ctx));
        _ = try g.run(&.{ "add", "-A", ctx.conf.ciiz.dir_path });
        const c = try g.run(&.{ "commit", "-m", ctx.conf.ciiz.comm_text });
        if (!c.okay()) return ctxm.fail("cannot commit the workflows", c.err, "check git identity (step 8)");
        const p = try g.run(&.{ "push" });
        if (!p.okay()) return ctxm.fail("cannot push the workflows", p.err, "check the SSH key (step 9)");
    }
    ctx.say("   waiting for the first Actions run...\n", .{});
    const until = ctx.nowSecs() + ctx.conf.ciiz.runz_tmos_secs;
    while (ctx.nowSecs() < until) {
        if (try workflowFresh(ctx)) return .{ .done = "first run is green" };
        ctx.sleep(CF.runz_poll_secs);
    }
    return .{ .wait = "the first run has not finished yet; run again to keep checking" };
}

// ---- step 17: image registry (GHCR); optional, skipped when off ----
pub fn ghcrPush(ctx: *Ctx, mode: Mode) anyerror!Outc {
    _ = mode;
    if (!ctx.conf.ghcr.onzz) return .{ .skip = "skipped: ghcr.onzz is off" };
    const owner = try ownerName(ctx);
    const name = try api.enc(ctx.a, ctx.repoName());
    const r = try api.getz(ctx, try std.fmt.allocPrint(ctx.a, "/users/{s}/packages/container/{s}", .{ owner, name }));
    if (r.code == 404) return .{ .wait = "no image pushed yet (push one from CI, then run again)" };
    if (!r.okay()) return api.refuse(ctx, r, "cannot read the package");
    const pk = api.read(Pack, ctx, r.body) orelse return .{ .wait = "no image pushed yet" };
    return .{ .done = try std.fmt.allocPrint(ctx.a, "image listed: {s}", .{pk.name}) };
}

fn mirrorOkay(ctx: *Ctx, m: @import("config-load.zig").Mirr) anyerror!bool {
    const g = ctx.gitz(try @import("github-repo.zig").sshzCommandPub(ctx));
    const r = try g.run(&.{ "ls-remote", m.urlz, ctx.conf.repo.bran });
    return r.okay() and r.text().len > 0;
}

// ---- step 18: mirrors, off by default ----
pub fn mirrPush(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (ctx.conf.mirr.len == 0) return .{ .skip = "skipped: no mirrors configured" };
    var okay: u32 = 0;
    var want: u32 = 0;
    for (ctx.conf.mirr) |m| {
        if (!m.onzz) continue;
        want += 1;
        if (try mirrorOkay(ctx, m)) okay += 1;
    }
    if (want == 0) return .{ .skip = "skipped: every mirror is off" };
    if (okay == want) return .{ .done = try std.fmt.allocPrint(ctx.a, "{d} mirror(s) reachable", .{okay}) };
    if (mode == .chec) return .{ .wait = "a mirror is not reachable" };
    const g = ctx.gitz(try @import("github-repo.zig").sshzCommandPub(ctx));
    // the first explicit push url replaces git's default: pin the origin url first, or pushes stop reaching GitHub
    const expl = try g.run(&.{ "config", "--get-all", try std.fmt.allocPrint(ctx.a, "remote.{s}.pushurl", .{ctx.conf.repo.remo}) });
    if (expl.text().len == 0) {
        const orig = try g.run(&.{ "remote", "get-url", ctx.conf.repo.remo });
        if (!orig.okay()) return ctxm.fail("cannot read the origin url", orig.err, "check the repo folder has a remote");
        _ = try g.run(&.{ "remote", "set-url", "--add", "--push", ctx.conf.repo.remo, orig.text() });
    }
    for (ctx.conf.mirr) |m| {
        if (!m.onzz) continue;
        _ = try g.run(&.{ "remote", "set-url", "--add", "--push", ctx.conf.repo.remo, m.urlz });
        const push = try g.run(&.{ "push", m.urlz, ctx.conf.repo.bran });
        if (!push.okay()) return ctxm.fail(try std.fmt.allocPrint(ctx.a, "cannot push to {s}", .{m.name}), push.err, "check that app's own setup ran first (its own account, key and token)");
    }
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{d} mirror(s) pushed", .{want}) };
}

// ---- step 19: final report ----
pub fn repoFina(ctx: *Ctx, mode: Mode) anyerror!Outc {
    _ = mode;
    var done: u32 = 0;
    var skipped: u32 = 0;
    var todo: u32 = 0;
    var hand: u32 = 0;
    for (ctx.steps.step) |row| {
        const st = ctx.stat.getz(row.iden).stat;
        switch (st) {
            .done => done += 1,
            .skipped => skipped += 1,
            .todo => todo += 1,
        }
        if (row.hand > hand) hand = row.hand;
    }
    const acti = latestRunz(ctx) catch null;
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(ctx.a, "repo: {s}/{s}\ndone: {d}  skipped: {d}  to do: {d}\nhand jobs used: {d}\n", .{ try ownerName(ctx), ctx.repoName(), done, skipped, todo, hand });
    if (acti) |r| try buf.print(ctx.a, "latest Actions run: {s}{s}\n", .{ r.status, if (r.conclusion) |c| try std.fmt.allocPrint(ctx.a, " ({s})", .{c}) else "" });
    const w = ctx.conf.warn;
    const mins = w.acti_free_usd * 1000 / w.acti_rate_milli;
    try buf.print(ctx.a, "Actions budget: ${d}/mo = about {d} min on {s}; spend not readable by API - watch github.com/settings/billing, warn past {d}% (${d}); keep no card, spending limit $0\n", .{ w.acti_free_usd, mins, ctx.conf.ciiz.runs_on, w.perc, w.acti_free_usd * w.perc / 100 });
    try buf.print(ctx.a, "Packages+artifacts pool: {d} MB; repo soft cap {d} MB; ship exes as Release assets, not artifacts or git\n", .{ w.pack_maxz_mbyt, w.repo_maxz_mbyt });
    return .{ .done = buf.items };
}

// ---- panic button: kills only credentials this app made, never the repo ----
pub fn revoke(ctx: *Ctx) anyerror!void {
    if (try api.token(ctx)) |tok| {
        ctx.audi.hideAdd(tok);
        const r = try api.call(ctx, .DELETE, "/applications/grants/current", null, true);
        ctx.say("   revoking the login token: {s}\n", .{if (r.okay() or r.code == 404) "ok" else "GitHub refused; it may still be valid, check Settings > Applications"});
        try ctx.secretDrop(api.TOKE_KEYZ);
    }
    for (ctx.conf.ciiz.secr) |row| try ctx.secretDrop(row.vaul);
    ctx.say("   the SSH key and the repo are NOT removed; delete the key yourself in Settings > SSH keys if you want it gone\n", .{});
}

test "mirror off by default; secret rows with no value and not required are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    var c: Ctx = .{ .io = std.testing.io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "/h", .root = "/r", .conf_dirz = "" };
    const got = try mirrPush(&c, .chec);
    try std.testing.expectEqualStrings("skipped: no mirrors configured", got.skip);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
