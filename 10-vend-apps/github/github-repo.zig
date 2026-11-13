// =====================================================================
// Des: The repo half of the GitHub setup - git identity, SSH key, ignore files, a secret scan, the first push, repo settings and branch rules
// Flo: git config > ed25519 key > upload to the account > .gitignore/.gitattributes > scan staged files > create+commit+push > settings > rule (or skip)
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, Mode (chec = read-only look, acts = do it)
// Out: Outc per step ; the SSH key goes to <home>/keys, never into the repo
// Run: not run directly - listed in vendor-github.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const api = @import("github-api.zig");
const sshz = @import("ssh-key.zig");
const scan = @import("secret-scan.zig");
const ctxm = @import("app-ctx.zig");
const Ctx = ctxm.Ctx;
const Mode = ctxm.Mode;
const Outc = ctxm.Outc;

const CF = .{ .seed_keyz = "sshz.seed", .chec_keyz = "sshz.chec", .ghcr_host = "ghcr.io" };

const KeyzRow = struct { key: []const u8 = "" };
const Repo = struct { name: []const u8 = "", default_branch: []const u8 = "", private: bool = false, has_wiki: bool = false, has_projects: bool = false, delete_branch_on_merge: bool = false, visibility: []const u8 = "" };
const Rule = struct { id: u64 = 0, name: []const u8 = "", target: []const u8 = "" };

// ---- step 8: git identity, LF line endings ----
// the repo folder must be its own git repo: make it when it is no repo at all; refuse when it sits inside another one (unless repo.nest_okay) ----
pub fn ensureRepo(ctx: *Ctx) anyerror!?Outc {
    const g = ctx.gitz("");
    const top = try g.run(&.{ "rev-parse", "--show-toplevel" });
    if (!top.okay()) {
        const made = try g.run(&.{ "init", "-q", "-b", ctx.conf.repo.bran });
        if (!made.okay()) return ctxm.fail("cannot start the git repo", made.err, "check git is installed and the --root folder is writable");
        return null;
    }
    if (ctx.conf.repo.nest_okay) return null;
    const real = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ctx.root, ctx.a) catch return null;
    const have = std.mem.trimEnd(u8, top.text(), "/\\");
    if (!std.mem.eql(u8, have, std.mem.trimEnd(u8, real, "/\\"))) return ctxm.fail("the folder sits inside another git repo", have, "pass a --root folder that is not inside another repo, or set repo.nest_okay to true on purpose");
    return null;
}

pub fn gitzIden(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const nore = ctx.stat.valu("mail_nore");
    if (nore.len == 0) return ctxm.fail("no noreply email yet", "step 7 has not run", "run the same command again");
    const g = ctx.gitz("");
    const scop_args: []const []const u8 = if (std.mem.eql(u8, ctx.conf.gitz.scop, "global")) &.{"--global"} else &.{"--local"};
    const cur = try g.run(&(.{ "config" } ++ .{scop_args[0]} ++ .{"user.email"}));
    const okay = cur.okay() and std.mem.eql(u8, cur.text(), nore);
    if (okay) return .{ .done = nore };
    if (mode == .chec) return .{ .wait = "git identity not set" };
    if (try ensureRepo(ctx)) |bad| return bad;
    const login = ctx.stat.valu("logi");
    const rows: [4][2][]const u8 = .{
        .{ "user.name", if (login.len > 0) login else "cloud-house" },
        .{ "user.email", nore },
        .{ "init.defaultBranch", ctx.conf.repo.bran },
        .{ "core.autocrlf", ctx.conf.gitz.crlf },
    };
    for (rows) |r| {
        const got = try g.run(&.{ "config", scop_args[0], r[0], r[1] });
        if (!got.okay()) return ctxm.fail(try std.fmt.allocPrint(ctx.a, "cannot set git {s}", .{r[0]}), got.err, "check git is installed and the folder is writable");
    }
    return .{ .done = nore };
}

fn keysListed(ctx: *Ctx, publ: []const u8) !bool {
    const r = try api.getz(ctx, "/user/keys");
    if (!r.okay()) return error.KeysRefused;
    const list = api.read([]const KeyzRow, ctx, r.body) orelse return false;
    const bare = sshz.bare(publ);
    for (list) |k| if (std.mem.eql(u8, sshz.bare(k.key), bare)) return true;
    return false;
}

// ---- step 9: SSH key (ed25519) ----
pub fn sshzKeyz(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const priv_path = try ctx.keysPath(false);
    const publ_path = try ctx.keysPath(true);
    const have_file = std.Io.Dir.cwd().access(ctx.io, priv_path, .{}) catch null != null;
    if (have_file) {
        const publ = std.Io.Dir.cwd().readFileAlloc(ctx.io, publ_path, ctx.a, .limited(4096)) catch return ctxm.fail("the public key file is unreadable", publ_path, "run the same command again");
        const seen = keysListed(ctx, publ) catch |e| {
            if (e != error.KeysRefused) return e;
            return api.refuse(ctx, try api.getz(ctx, "/user/keys"), "cannot list SSH keys (needs the read:user scope)");
        };
        if (seen) return .{ .done = "key is on the account" };
        if (mode == .chec) return .{ .wait = "key not uploaded" };
        const r = try api.call(ctx, .POST, "/user/keys", try api.json(ctx, .{ .title = ctx.conf.sshz.titl, .key = std.mem.trim(u8, publ, " \r\n") }), true);
        if (!r.okay()) return api.refuse(ctx, r, "cannot upload the SSH key");
        return .{ .done = "key uploaded" };
    }
    if (mode == .chec) return .{ .wait = "no key yet" };
    const pair = sshz.make(ctx.a, ctx.io, ctx.conf.sshz.titl) catch |e| return ctxm.fail("cannot make an SSH key", @errorName(e), "run the same command again");
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(priv_path)) |d| cwd.createDirPath(ctx.io, d) catch return ctxm.fail("cannot make the keys folder", priv_path, "check the folder is writable");
    {
        const f = cwd.createFile(ctx.io, priv_path, if (comptime @import("builtin").os.tag == .windows) .{} else .{ .permissions = .fromMode(0o600) }) catch return ctxm.fail("cannot write the private key", priv_path, "check the folder is writable");
        defer f.close(ctx.io);
        f.writePositionalAll(ctx.io, pair.priv, 0) catch return ctxm.fail("cannot write the private key", priv_path, "check the folder is writable");
    }
    cwd.writeFile(ctx.io, .{ .sub_path = publ_path, .data = pair.publ }) catch return ctxm.fail("cannot write the public key", publ_path, "check the folder is writable");
    const r = try api.call(ctx, .POST, "/user/keys", try api.json(ctx, .{ .title = ctx.conf.sshz.titl, .key = std.mem.trim(u8, pair.publ, " \r\n") }), true);
    if (!r.okay()) return api.refuse(ctx, r, "cannot upload the SSH key");
    return .{ .done = "key made and uploaded" };
}

pub fn sshzCommandPub(ctx: *Ctx) ![]const u8 {
    return sshzCommand(ctx);
}

fn sshzCommand(ctx: *Ctx) ![]const u8 {
    const priv = try ctx.keysPath(false);
    return std.fmt.allocPrint(ctx.a, "ssh -i {s} -o IdentitiesOnly=yes -o UserKnownHostsFile={s} -o StrictHostKeyChecking=accept-new", .{ priv, try ctx.hostPath() });
}

// ---- step 10: .gitignore, .gitattributes ----
pub fn fileIgno(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const ip = try ctx.path(&.{ ctx.root, ".gitignore" });
    const ap = try ctx.path(&.{ ctx.root, ".gitattributes" });
    const ihave = std.Io.Dir.cwd().access(ctx.io, ip, .{}) catch null != null;
    const ahave = std.Io.Dir.cwd().access(ctx.io, ap, .{}) catch null != null;
    if (ihave and ahave) return .{ .done = "files exist" };
    if (mode == .chec) return .{ .wait = "files missing" };
    if (!ihave) {
        const text = try std.mem.join(ctx.a, "\n", ctx.conf.file.igno);
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ip, .data = try std.mem.concat(ctx.a, u8, &.{ text, "\n" }) }) catch return ctxm.fail("cannot write .gitignore", ip, "check the folder is writable");
    }
    if (!ahave) {
        const text = try std.mem.join(ctx.a, "\n", ctx.conf.file.attr);
        std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = ap, .data = try std.mem.concat(ctx.a, u8, &.{ text, "\n" }) }) catch return ctxm.fail("cannot write .gitattributes", ap, "check the folder is writable");
    }
    return .{ .done = "files written" };
}

// every file that would be part of the next commit, read-only (tracked + untracked, respecting .gitignore) ----
fn wouldCommitFiles(ctx: *Ctx) ![]const []const u8 {
    const g = ctx.gitz("");
    const tracked = try g.run(&.{"ls-files"});
    const untracked = try g.run(&.{ "ls-files", "--others", "--exclude-standard" });
    var list: std.ArrayList([]const u8) = .empty;
    for ([2][]const u8{ tracked.out, untracked.out }) |block| {
        var it = std.mem.tokenizeAny(u8, block, "\n\r");
        while (it.next()) |line| try list.append(ctx.a, line);
    }
    return list.items;
}

fn scanRules(ctx: *Ctx, marks: []scan.Mark) scan.Rules {
    const mn = @min(ctx.conf.scan.mark.len, marks.len);
    for (ctx.conf.scan.mark[0..mn], 0..) |m, i| marks[i] = .{ .pref = m.pref, .tail = m.tail };
    return .{ .name = ctx.conf.scan.name, .mark = marks[0..mn], .skip = ctx.conf.scan.skip, .size_maxz_kbyt = ctx.conf.scan.size_maxz_kbyt, .file_maxz_mbyt = ctx.conf.scan.file_maxz_mbyt };
}

// ---- step 11: secret scan before the first push; read-only in chec mode, stages only when it acts ----
pub fn scanSecr(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (std.mem.eql(u8, ctx.stat.valu("scan_okay"), "yes")) return .{ .done = "nothing risky found (cached)" };
    const files = try wouldCommitFiles(ctx);
    var marks: [16]scan.Mark = undefined;
    const found = try scan.scan(ctx.io, ctx.a, ctx.root, files, scanRules(ctx, &marks));
    if (found.len == 0) {
        if (mode == .acts) try ctx.stat.putz("scan_okay", "yes");
        return .{ .done = try std.fmt.allocPrint(ctx.a, "{d} files checked, nothing risky", .{files.len}) };
    }
    if (mode == .chec) return .{ .wait = "risky files found" };
    var msg: std.ArrayList(u8) = .empty;
    for (found) |f| try msg.print(ctx.a, "{s}: {s} ({s})\n", .{ @tagName(f.kind), f.path, f.rule });
    return ctxm.failCode(3, "a key-like or oversized file would be committed", msg.items, "add it to repo.root/.gitignore (or scan.skip in 00-config.json if it is a false positive), then run again");
}

fn repoRead(ctx: *Ctx) !?Repo {
    const r = try api.getz(ctx, try std.mem.concat(ctx.a, u8, &.{ "/repos/", try repoOwner(ctx), "/", try api.enc(ctx.a, ctx.repoName()) }));
    if (r.code == 404) return null;
    if (!r.okay()) return error.RepoRefused;
    return api.read(Repo, ctx, r.body);
}

fn repoOwner(ctx: *Ctx) ![]const u8 {
    return api.enc(ctx.a, ctx.stat.valu("logi"));
}

fn remoteOkay(ctx: *Ctx) !bool {
    const g = ctx.gitz("");
    const r = try g.run(&.{ "remote", "get-url", "origin" });
    return r.okay();
}

// ---- step 12: create repo, first commit, push ----
pub fn repoMake(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const name = ctx.repoName();
    const existing = repoRead(ctx) catch |e| {
        if (e != error.RepoRefused) return e;
        return api.refuse(ctx, try api.getz(ctx, try std.mem.concat(ctx.a, u8, &.{ "/repos/", try repoOwner(ctx), "/", try api.enc(ctx.a, name) })), "cannot read the repo");
    };
    const g = ctx.gitz(try sshzCommand(ctx));
    if (existing != null and (try remoteOkay(ctx))) {
        const r = try g.run(&.{ "ls-remote", "origin", ctx.conf.repo.bran });
        if (r.okay() and r.text().len > 0) return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} is live", .{name}) };
    }
    if (mode == .chec) return .{ .wait = "repo not live yet" };
    if (existing == null) {
        const r = try api.call(ctx, .POST, "/user/repos", try api.json(ctx, .{ .name = name, .description = ctx.conf.repo.desc, .private = !std.mem.eql(u8, ctx.conf.repo.visi, "public"), .auto_init = false }), true);
        if (!r.okay()) return api.refuse(ctx, r, "cannot create the repo");
    }
    if (!std.mem.eql(u8, ctx.stat.valu("scan_okay"), "yes")) return ctxm.fail("secret scan has not run", "step 11 must pass before any push", "run the same command again");
    if (!(try remoteOkay(ctx))) {
        const url = try std.fmt.allocPrint(ctx.a, "{s}:{s}/{s}.git", .{ ctx.conf.sshz.host_user, try repoOwner(ctx), name });
        const r = try g.run(&.{ "remote", "add", "origin", url });
        if (!r.okay()) return ctxm.fail("cannot add the remote", r.err, "check the repo folder and git config");
    }
    _ = try g.run(&.{ "add", "-A" });
    const commit = try g.run(&.{ "commit", "-m", ctx.conf.repo.comm_text });
    if (!commit.okay() and std.mem.indexOf(u8, commit.out, "nothing to commit") == null) return ctxm.fail("cannot commit", commit.err, "check git identity (step 8) and file permissions");
    const branch = try g.run(&.{ "branch", "-M", ctx.conf.repo.bran });
    if (!branch.okay()) return ctxm.fail("cannot name the branch", branch.err, "check git is installed");
    const push = try g.run(&.{ "push", "-u", "origin", ctx.conf.repo.bran });
    if (!push.okay()) return ctxm.fail("cannot push", push.err, "check the SSH key is uploaded (step 9) and the key's known_hosts is writable");
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} pushed", .{name}) };
}

// later edits: commit everything the mirror brought in and push it; nothing changed = nothing sent ----
pub fn publish(ctx: *Ctx) anyerror!Outc {
    const g = ctx.gitz(try sshzCommand(ctx));
    const st = try g.run(&.{ "status", "--porcelain" });
    if (!st.okay()) return ctxm.fail("cannot read the repo state", st.err, "check --root is the repo folder");
    if (st.text().len == 0) return .{ .done = "nothing to publish" };
    const add = try g.run(&.{ "add", "-A" });
    if (!add.okay()) return ctxm.fail("cannot stage the files", add.err, "check the repo folder is writable");
    const commit = try g.run(&.{ "commit", "-m", ctx.conf.repo.publ_text });
    if (!commit.okay()) return ctxm.fail("cannot commit", commit.err, "check git identity (step 8)");
    const push = try g.run(&.{ "push", "origin", ctx.conf.repo.bran });
    if (!push.okay()) return ctxm.fail("cannot push", push.err, "check the SSH key is uploaded (step 9) and the network works");
    const head = try g.run(&.{ "rev-parse", "--short", "HEAD" });
    return .{ .done = try std.fmt.allocPrint(ctx.a, "published {s}", .{head.text()}) };
}

// ---- step 13: repo settings ----
pub fn repoSett(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const path = try std.mem.concat(ctx.a, u8, &.{ "/repos/", try repoOwner(ctx), "/", try api.enc(ctx.a, ctx.repoName()) });
    const cur = (try repoRead(ctx)) orelse return ctxm.fail("the repo is missing", "step 12 has not run", "run the same command again");
    const want = ctx.conf.repo;
    const okay = cur.has_wiki == want.wiki and cur.has_projects == want.proj and cur.delete_branch_on_merge == want.merg_dele;
    if (okay) return .{ .done = "settings match" };
    if (mode == .chec) return .{ .wait = "settings differ" };
    const r = try api.call(ctx, .PATCH, path, try api.json(ctx, .{ .has_wiki = want.wiki, .has_projects = want.proj, .delete_branch_on_merge = want.merg_dele }), true);
    if (!r.okay()) return api.refuse(ctx, r, "cannot update repo settings");
    return .{ .done = "settings applied" };
}

fn ruleSeen(ctx: *Ctx) !?Rule {
    const owner = try repoOwner(ctx);
    const r = try api.getz(ctx, try std.mem.concat(ctx.a, u8, &.{ "/repos/", owner, "/", try api.enc(ctx.a, ctx.repoName()), "/rulesets" }));
    if (!r.okay()) return error.RuleRefused;
    const list = api.read([]const Rule, ctx, r.body) orelse return null;
    for (list) |rl| if (std.mem.eql(u8, rl.name, ctx.conf.rule.name)) return rl;
    return null;
}

const RuleType = struct { type: []const u8 };

// which rule types to ask for, driven by config so a flag that is off is never sent ----
fn ruleTypes(cf: @import("config-load.zig").Rule, buf: *[3]RuleType) []const RuleType {
    var n: usize = 0;
    if (cf.dele_bloc) {
        buf[n] = .{ .type = "deletion" };
        n += 1;
    }
    if (cf.forc_bloc) {
        buf[n] = .{ .type = "non_fast_forward" };
        n += 1;
    }
    if (cf.pull_need) {
        buf[n] = .{ .type = "pull_request" };
        n += 1;
    }
    return buf[0..n];
}

// ---- step 14: branch rules (a plan that refuses rulesets is logged as a skip, never an error) ----
pub fn ruleBran(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (!ctx.conf.rule.onzz) return .{ .skip = "skipped: rule.onzz is off" };
    if ((ruleSeen(ctx) catch null) != null) return .{ .done = "rule exists" };
    if (mode == .chec) return .{ .wait = "no rule yet" };
    const owner = try repoOwner(ctx);
    var rule_buf: [3]RuleType = undefined;
    const body = try api.json(ctx, .{
        .name = ctx.conf.rule.name,
        .target = "branch",
        .enforcement = "active",
        .conditions = .{ .ref_name = .{ .include = &.{try std.fmt.allocPrint(ctx.a, "refs/heads/{s}", .{ctx.conf.repo.bran})}, .exclude = &[_][]const u8{} } },
        .rules = ruleTypes(ctx.conf.rule, &rule_buf),
    });
    const r = try api.call(ctx, .POST, try std.mem.concat(ctx.a, u8, &.{ "/repos/", owner, "/", try api.enc(ctx.a, ctx.repoName()), "/rulesets" }), body, true);
    if (r.code == 403 or r.code == 404 or r.code == 422) {
        try ctx.stat.setz("rule-bran", .skipped, "skipped: plan", ctx.nowSecs());
        return .{ .skip = "skipped: plan (this plan or repo visibility refuses rulesets)" };
    }
    if (!r.okay()) return api.refuse(ctx, r, "cannot create the branch rule");
    return .{ .done = "rule created" };
}

test "ruleTypes follows config flags, in order, with none when all are off" {
    var buf: [3]RuleType = undefined;
    const d: @import("config-load.zig").Rule = .{};
    const all = ruleTypes(d, &buf);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("deletion", all[0].type);
    try std.testing.expectEqualStrings("non_fast_forward", all[1].type);
    var cf = d;
    cf.pull_need = true;
    try std.testing.expectEqual(@as(usize, 3), ruleTypes(cf, &buf).len);
    try std.testing.expectEqualStrings("pull_request", ruleTypes(cf, &buf)[2].type);
    cf = .{ .dele_bloc = false, .forc_bloc = false, .pull_need = false };
    try std.testing.expectEqual(@as(usize, 0), ruleTypes(cf, &buf).len);
}

test "publish: commits and pushes what changed, says nothing to publish when clean" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.createDirPath(io, "remote.git");
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    if (std.c.getenv("PATH")) |pp| try env.put("PATH", std.mem.span(pp));
    try env.put("HOME", base);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", base);
    for ([_][]const u8{ "GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME" }) |k| try env.put(k, "tester");
    for ([_][]const u8{ "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL" }) |k| try env.put(k, "t@example.com");
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    const work = try std.fs.path.join(a, &.{ base, "work" });
    const bare = try std.fs.path.join(a, &.{ base, "remote.git" });
    var c: Ctx = .{ .io = io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = base, .root = work, .conf_dirz = "" };
    _ = c.gitz("").run(&.{"--version"}) catch |e| if (e == error.Missing) return error.SkipZigTest else return e;
    var rg: @import("git-run.zig").Git = c.gitz("");
    rg.root = bare;
    try std.testing.expect((try rg.run(&.{ "init", "-q", "--bare", "-b", "main" })).okay());
    try std.testing.expect((try ensureRepo(&c)) == null);
    try std.testing.expect((try c.gitz("").run(&.{ "remote", "add", "origin", bare })).okay());
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "one" });
    const first = try publish(&c);
    try std.testing.expect(first == .done and std.mem.startsWith(u8, first.done, "published "));
    const log1 = try rg.run(&.{ "rev-list", "--count", "main" });
    try std.testing.expectEqualStrings("1", log1.text());
    const again = try publish(&c);
    try std.testing.expect(again == .done and std.mem.eql(u8, again.done, "nothing to publish"));
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "two" });
    _ = try publish(&c);
    try std.testing.expectEqualStrings("2", (try rg.run(&.{ "rev-list", "--count", "main" })).text());
}

test "ensureRepo: makes a repo in a plain folder, accepts its own repo, refuses a folder inside another repo unless allowed" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outer/inner");
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    var env = std.process.Environ.Map.init(a);
    if (std.c.getenv("PATH")) |pp| try env.put("PATH", std.mem.span(pp));
    try env.put("HOME", base);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CEILING_DIRECTORIES", base); // the scratch folder lives inside a real repo: do not look above it
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    const outer = try std.fs.path.join(a, &.{ base, "outer" });
    var c: Ctx = .{ .io = io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "/h", .root = outer, .conf_dirz = "" };
    _ = c.gitz("").run(&.{"--version"}) catch |e| if (e == error.Missing) return error.SkipZigTest else return e;
    try std.testing.expect((try ensureRepo(&c)) == null); // no repo yet: init
    try tmp.dir.access(io, "outer/.git", .{});
    try std.testing.expect((try ensureRepo(&c)) == null); // its own repo: fine
    c.root = try std.fs.path.join(a, &.{ base, "outer", "inner" });
    try std.testing.expect((try ensureRepo(&c)) != null); // inside the outer repo: refused
    c.conf.repo.nest_okay = true;
    try std.testing.expect((try ensureRepo(&c)) == null);
}

test "ssh command names the key, the known_hosts file and accepts new hosts only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    var c: Ctx = .{ .io = std.testing.io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "/h", .root = "/r", .conf_dirz = "" };
    const cmd = try sshzCommand(&c);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "/h/github-keys/id_ed25519") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "StrictHostKeyChecking=accept-new") != null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
