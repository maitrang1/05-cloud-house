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

// fill the workflow template from config; every knob lives in 00-config.json
// the release job sits between two marker lines: keep its text (markers dropped) or cut it all out ----
fn releaseBlock(a: std.mem.Allocator, tmpl: []const u8, keep: bool) ![]u8 {
    const begin = "@@RELEASE_BEGIN@@\n";
    const end = "@@RELEASE_END@@\n";
    const b = std.mem.indexOf(u8, tmpl, begin) orelse return a.dupe(u8, tmpl);
    const e = std.mem.indexOfPos(u8, tmpl, b, end) orelse return a.dupe(u8, tmpl);
    const inner = tmpl[b + begin.len .. e];
    return std.mem.concat(a, u8, &.{ tmpl[0..b], if (keep) inner else "", tmpl[e + end.len ..] });
}

// write the workflow from the template when it differs from the file in the repo folder; true = it changed ----
pub fn ciizRender(ctx: *Ctx, write: bool) !bool {
    const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.conf.ciiz.tmpl_file, ctx.a, .limited(64 * 1024)) catch return error.TemplateMissing;
    const want = try tmplFill(ctx.a, raw, ctx.conf.ciiz);
    const dest = try ctx.path(&.{ ctx.root, ctx.conf.ciiz.file_path });
    const have = std.Io.Dir.cwd().readFileAlloc(ctx.io, dest, ctx.a, .limited(256 * 1024)) catch null;
    if (have != null and std.mem.eql(u8, have.?, want)) return false;
    if (write) {
        if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(ctx.io, d);
        try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = want });
    }
    return true;
}

fn tmplFill(a: std.mem.Allocator, tmpl: []const u8, cf: @import("config-load.zig").Ciiz) ![]u8 {
    var paths: std.ArrayList(u8) = .empty;
    if (cf.paths.len > 0) {
        try paths.appendSlice(a, "    paths:\n");
        for (cf.paths) |p| try paths.print(a, "      - '{s}'\n", .{p});
    }
    const tags: []const u8 = if (cf.tags) "    tags: ['v*']\n" else "";
    const cache: []const u8 = if (cf.cache)
        "\n      - id: ZIGZ-CASH\n        uses: actions/cache@v6\n        with:\n          path: ~/.cache/zig\n          key: zig-${{ runner.os }}-${{ hashFiles('**/build.zig.zon') }}\n"
    else
        "";
    const keys = [_][]const u8{ "@@TAGS@@", "@@PATHS@@", "@@KILL@@", "@@RUNNER@@", "@@TIMEOUT@@", "@@ZIGVERS@@", "@@ZIGBASE@@", "@@CACHE@@", "@@RELTIMEOUT@@", "@@RELTARGETS@@" };
    const timeout = try std.fmt.allocPrint(a, "{d}", .{cf.job_tmos_mins});
    const reltmo = try std.fmt.allocPrint(a, "{d}", .{cf.rele_tmos_mins});
    const targets = try std.mem.join(a, " ", cf.rele_targets);
    const vals = [_][]const u8{ tags, paths.items, cf.kill_name, cf.runs_on, timeout, cf.zig_vers, cf.zig_base, cache, reltmo, targets };
    var cur = try releaseBlock(a, tmpl, cf.rele);
    for (keys, vals) |k, v| cur = try std.mem.replaceOwned(u8, a, cur, k, v);
    return cur;
}

test "tmplFill puts every config knob in and leaves no marker behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tmpl = "@@TAGS@@@@PATHS@@|@@KILL@@|@@RUNNER@@|@@TIMEOUT@@|@@ZIGVERS@@|@@ZIGBASE@@|@@CACHE@@";
    const out = try tmplFill(a, tmpl, .{ .paths = &.{"apps/x/**"}, .runs_on = "ubuntu-slim", .job_tmos_mins = 7, .cache = false });
    try std.testing.expect(std.mem.indexOf(u8, out, "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "      - 'apps/x/**'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "|ubuntu-slim|7|") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "actions/cache") == null);
}

test "the release job is kept with its targets and timeout, or cut out whole; the shipped template leaves no marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "20-build.yml", a, .limited(64 * 1024));
    const on = try tmplFill(a, raw, .{ .rele_targets = &.{ "x86_64-linux", "aarch64-macos" }, .rele_tmos_mins = 45 });
    try std.testing.expect(std.mem.indexOf(u8, on, "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, on, "gh release create") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "for t in x86_64-linux aarch64-macos; do") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "timeout-minutes: 45") != null);
    const off = try tmplFill(a, raw, .{ .rele = false });
    try std.testing.expect(std.mem.indexOf(u8, off, "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, off, "release") == null);
    try std.testing.expect(std.mem.indexOf(u8, off, "EXEZ-BUIL") != null); // the build job stays
}

fn fileAtRepo(ctx: *Ctx, rel: []const u8) !bool {
    return std.Io.Dir.cwd().access(ctx.io, try ctx.path(&.{ ctx.root, rel }), .{}) catch null != null;
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
    const have_file = try fileAtRepo(ctx, ctx.conf.ciiz.file_path);
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
        const raw = std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.conf.ciiz.tmpl_file, ctx.a, .limited(64 * 1024)) catch return ctxm.fail("the CI template is missing", ctx.conf.ciiz.tmpl_file, "keep 20-build.yml next to 00-config.json");
        const tmpl = try tmplFill(ctx.a, raw, ctx.conf.ciiz);
        const dest = try ctx.path(&.{ ctx.root, ctx.conf.ciiz.file_path });
        if (std.fs.path.dirname(dest)) |d| std.Io.Dir.cwd().createDirPath(ctx.io, d) catch return ctxm.fail("cannot make the workflow folder", dest, "check the folder is writable");
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = dest, .data = tmpl }) catch return ctxm.fail("cannot write the workflow file", dest, "check the folder is writable");
        const g = ctx.gitz(try @import("github-repo.zig").sshzCommandPub(ctx));
        _ = try g.run(&.{ "add", ctx.conf.ciiz.file_path });
        const c = try g.run(&.{ "commit", "-m", ctx.conf.ciiz.comm_text });
        if (!c.okay()) return ctxm.fail("cannot commit the workflow", c.err, "check git identity (step 8)");
        const p = try g.run(&.{ "push" });
        if (!p.okay()) return ctxm.fail("cannot push the workflow", p.err, "check the SSH key (step 9)");
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
