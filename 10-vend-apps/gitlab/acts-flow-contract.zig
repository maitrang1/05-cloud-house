// =====================================================================
// Des: End-to-end flow test: runs every real step (account, project, mirror) against the mock GitLab + GitHub, a real temp ssh key, and a real scratch git repo. Proves the whole setup works together, not just each adapter alone.
// Flo: build a temp home + scratch repo > wire Ctx structs to the mock > run every Row through the engine > assert the mock's final state
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (self-contained; needs git and ssh-keygen on PATH, skips if missing)
// Out: pass/fail
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");
const audi = @import("audit-log.zig");
const http = @import("http-call.zig");
const stat = @import("state-file.zig");
const vaul = @import("vault-file.zig");
const inpu = @import("line-input.zig");
const tool = @import("tool-exec.zig");
const engi = @import("step-engine.zig");
const gitl = @import("gitl-adapter.zig");
const gith = @import("gith-adapter.zig");
const mock = @import("mock-server.zig");
const acct = @import("acts-account.zig");
const proj = @import("acts-project.zig");
const mirr = @import("acts-mirror.zig");

const testOpts = http.Opts{ .trys = 3, .back = 1, .maxw = 2, .agen = "gitlab-test/1", .maxb = 1 << 20 };
const testCost = vaul.Cost{ .time = 1, .memo = 64, .para = 1 };

// a fixed minimal config: no JSON file needed, every field the acts touch is set by hand
fn confMake(gpa: std.mem.Allocator) !@import("config-load.zig").Conf {
    const sett = try std.json.parseFromSliceLeaky(std.json.Value, gpa, "{\"shared_runners_enabled\":false}", .{});
    return .{
        .vers = 1,
        .data = .{ .root = "", .vaul = "", .stat = "", .audi = "", .step = "", .acct = "" },
        .vaul = .{ .envz = "", .time = 1, .memo = 64, .para = 1 },
        .repo = .{ .path = "", .bran = "main", .remo = "origin" },
        .gitl = .{ .host = "gitlab.com", .webz = "", .apiz = "", .oaut = "", .user = "", .proj = "cloud-house", .visi = "public", .push = "", .sign = "", .sett = sett },
        .gith = .{ .apiz = "", .repo = "cloud-house", .vers = "2022-11-28", .secr = "GITLAB_MIRROR_TOKEN", .ping = "", .varz = "MIRROR_ON", .flow = ".github/workflows/mirror.yml", .tmpl = "mirror-template.yml", .mess = "", .wait = 0 },
        .oaut = .{ .clid = mock.clid, .scop = "api" },
        .logi = .{ .orde = &.{"devi"} },
        .tool = .{ .gitz = "git", .sshk = "ssh-keygen", .sshz = "ssh", .glab = "glab", .ghcl = "gh", .time = 20 },
        .glab = .{ .stat = &.{}, .logi = &.{}, .toke = &.{} },
        .ghcl = .{ .toke = &.{}, .user = &.{} },
        .sshz = .{ .file = "", .titl = "cloud-house" },
        .prot = .{ .push = 30, .merg = 40, .forc = false },
        .toke = .{ .name = "mirror", .scop = &.{"write_repository"}, .role = 30, .days = 90, .rota = 14 },
        .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 30 },
        .http = .{ .trys = 3, .back = 1, .maxw = 2, .agen = "gitlab-test/1", .maxb = 1 << 20 },
        .limi = .{ .stor = 1 << 30, .apiz = 0, .warn = 80, .cimn = 400, .mirx = 10, .usrx = 5 },
    };
}

test "full setup flow: account, project, mirror, all through the real engine" {
    var aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const io = std.testing.io;

    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tlen = try tmpz.dir.realPath(io, &tbuf);
    const root = tbuf[0..tlen];

    // a real scratch git repo standing in for the live cloud-house tree
    const repo = try std.fs.path.join(gpa, &.{ root, "repo" });
    var pare = std.process.Environ.Map.init(gpa);
    try pare.put("PATH", "/usr/bin:/bin:/usr/local/bin");
    try pare.put("HOME", root);
    var logz = audi.Audi{ .io = io, .path = try std.fs.path.join(gpa, &.{ root, "audit.log" }) };
    var tool1 = try tool.Tool.init(gpa, io, &logz, &pare, 20);
    if (!tool1.have("git") or !tool1.have("ssh-keygen")) return error.SkipZigTest;
    try std.Io.Dir.cwd().createDirPath(io, repo);
    _ = try tool1.runz(&.{ "git", "init", "--quiet", "--initial-branch=main" }, repo);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(gpa, &.{ repo, "readme.txt" }), .data = "x" });
    _ = try tool1.runz(&.{ "git", "-c", "user.email=a@b.co", "-c", "user.name=t", "add", "." }, repo);
    _ = try tool1.runz(&.{ "git", "-c", "user.email=a@b.co", "-c", "user.name=t", "commit", "--quiet", "-m", "x" }, repo);
    const head1 = try tool1.runz(&.{ "git", "rev-parse", "main" }, repo);
    try std.testing.expect(head1.okay());
    // the GitHub remote must exist first (pushUrlz only adds a second push url to it)
    const githDir = try std.fmt.allocPrint(gpa, "{s}/github/cloud-house.git", .{root});
    try std.Io.Dir.cwd().createDirPath(io, githDir);
    _ = try tool1.runz(&.{ "git", "init", "--quiet", "--bare" }, githDir);
    _ = try tool1.runz(&.{ "git", "remote", "add", "origin", githDir }, repo);

    // the mock stands in for both GitHub and GitLab; the mirror project's bare repo lives under root
    const mock1 = try mock.Mock.star(io);
    defer mock1.halt();
    mock1.root = root;
    mock1.gitz = "git";
    mock1.pollNeed = 0; // the flow test checks the wiring, not the device-flow wait loop (see gitl-contract.zig)

    var conf1 = try confMake(gpa);
    conf1.sshz.file = try std.fs.path.join(gpa, &.{ root, "id_ed25519" });
    conf1.repo.path = repo;

    var vaul1 = try vaul.Vaul.open(gpa, io, try std.fs.path.join(gpa, &.{ root, "vault.json" }), "correct horse battery", testCost);
    try vaul1.putz("gith.user", "ghowner");
    var stat1 = try stat.Stat.load(gpa, io, try std.fs.path.join(gpa, &.{ root, "state.json" }));
    var http1 = http.Http.init(gpa, io, &logz, testOpts);
    defer http1.deinit();
    var gitl1 = gitl.Gitl{ .gpa = gpa, .http = &http1, .apiz = try mock1.base(gpa, "/api/v4"), .oaut = try mock1.base(gpa, "/oauth") };
    var gith1 = gith.Gith{ .gpa = gpa, .io = io, .http = &http1, .apiz = try mock1.base(gpa, "/gh"), .vers = "2022-11-28", .toke = mock.ghToke, .owne = "ghowner", .repo = "cloud-house" };

    var queu = inpu.Inpu{ .io = io };
    try queu.list.append(gpa, try gpa.dupe(u8, "g")); // stands in for the human on the email-link step (never auto-detected)
    var eng1 = engi.Engi{ .gpa = gpa, .io = io, .stat = &stat1, .inpu = &queu, .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 5 } };

    var acctCtx = acct.Ctx{ .gpa = gpa, .conf = &conf1, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1, .tool = &tool1 };
    const acctRows = acct.rows(&acctCtx);
    try eng1.runOne(acctRows[0]); // acc-read-gith
    try eng1.runOne(acctRows[1]); // acc-free-name: username must still be free, nobody signed up yet
    mock1.sign("ghowner"); // the human presses "Continue with GitHub" now; must match the GitHub login read above
    try eng1.runAll(acctRows[2..]);

    var projCtx = proj.Ctx{ .gpa = gpa, .conf = &conf1, .vaul = &vaul1, .stat = &stat1, .tool = &tool1, .gitl = &gitl1 };
    try eng1.runAll(&proj.rows(&projCtx));
    try std.testing.expectEqualStrings("public", mock1.projVisi); // the project took its visibility from the config

    // the first push: mimic "git push" by updating the bare project repo straight from the scratch repo
    const gitDir = try std.fmt.allocPrint(gpa, "{s}/ghowner/cloud-house.git", .{root});
    _ = try tool1.runz(&.{ "git", "push", "--quiet", gitDir, "main" }, repo);

    var mirrCtx = mirr.Ctx{ .gpa = gpa, .io = io, .conf = &conf1, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1, .gith = &gith1 };
    mock1.runzDone = true; // the mirror workflow "ran" in the mock already
    try eng1.runAll(&mirr.rows(&mirrCtx));

    // the mirror workflow was written into the copy folder from the template, every marker filled
    const flow = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(gpa, &.{ repo, ".github/workflows/mirror.yml" }), gpa, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, flow, "ghowner/cloud-house.git") != null or std.mem.indexOf(u8, flow, "/cloud-house.git") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow, "secrets.GITLAB_MIRROR_TOKEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow, "branches: [main]") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow, "{") == null or std.mem.indexOf(u8, flow, "{branch}") == null);

    // assertions: the whole chain actually happened, in the mock's own state
    try std.testing.expectEqual(@as(?stat.Mark, .done), eng1.stat.markGetz("acc-devi-logi"));
    try std.testing.expect(mock1.keys.items.len == 1 and !mock1.keys.items[0].gone);
    try std.testing.expect(mock1.protHave and mock1.protPush == 30 and !mock1.protForc);
    try std.testing.expect(mock1.atok.items.len >= 1);
    try std.testing.expectEqualStrings(vaul1.getz("gitl.mirror_token").?, mock1.atok.items[0].toke);
    try std.testing.expectEqualStrings(mock1.atok.items[0].toke, mock1.secrGetz("GITLAB_MIRROR_TOKEN").?);
    try std.testing.expectEqualStrings("1", varzGetz(mock1, "MIRROR_ON") orelse "");
    const head2 = try tool1.runz(&.{ "git", "--git-dir", gitDir, "rev-parse", "refs/heads/main" }, null);
    try std.testing.expectEqualStrings(head1.text(), head2.text());
    try std.testing.expect(stat1.data.idsz.pingSent);
    try std.testing.expectEqual(@as(u32, 3), eng1.hand); // acc-sign-up, acc-email, acc-devi-logi
}

// a small helper so varzGetz reads cleanly in the test above
fn varzGetz(self: *mock.Mock, name: []const u8) ?[]const u8 {
    for (self.varz.items) |item| if (std.mem.eql(u8, item.keyz, name)) return item.valu;
    return null;
}

test "an account you named in gitlab-account.json that already exists skips the name, sign-up and email steps" {
    const io = std.testing.io;
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    var logz = audi.Audi{ .io = io, .path = "" };
    var pare = std.process.Environ.Map.init(gpa);
    var tl = try tool.Tool.init(gpa, io, &logz, &pare, 20);
    const mock1 = try mock.Mock.star(io);
    defer mock1.halt();
    var conf1 = try confMake(gpa);
    var vaul1 = try vaul.Vaul.open(gpa, io, try std.fs.path.join(gpa, &.{ root, "vault.json" }), "correct horse battery", testCost);
    try vaul1.putz("gith.user", "someone-else"); // the GitHub login differs from the GitLab name on purpose
    var stat1 = try stat.Stat.load(gpa, io, try std.fs.path.join(gpa, &.{ root, "state.json" }));
    var http1 = http.Http.init(gpa, io, &logz, testOpts);
    defer http1.deinit();
    var gitl1 = gitl.Gitl{ .gpa = gpa, .http = &http1, .apiz = try mock1.base(gpa, "/api/v4"), .oaut = try mock1.base(gpa, "/oauth") };
    var cx = acct.Ctx{ .gpa = gpa, .conf = &conf1, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1, .tool = &tl };
    mock1.sign("ann"); // the account exists on GitLab already
    conf1.gitl.user = "ann";
    const name = try acct.Ctx.freeName(&cx, gpa);
    try std.testing.expect(name == .okay and std.mem.eql(u8, name.okay, "ann"));
    try std.testing.expectEqualStrings("ann", vaul1.getz("gitl.user").?);
    const sign = try acct.Ctx.signUpzz(&cx, gpa);
    try std.testing.expect(sign == .okay);
    const mail = try acct.Ctx.emailLink(&cx, gpa);
    try std.testing.expect(mail == .okay);
    // without the named account the same name is "taken" (someone else's), as before
    conf1.gitl.user = "";
    try vaul1.putz("gith.user", "ann");
    try std.testing.expectError(error.UsernameTaken, acct.Ctx.freeName(&cx, gpa));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
