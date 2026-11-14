// =====================================================================
// Des: End-to-end flow tests on the pretend server: the whole setup through the real engine (download + checksum, app.ini, unit, admin + token by the fake CLI, repo, protection, push url), a second run that changes nothing, drift, revoke, and the refusal cases.
// Flo: scratch host dirs + scratch git repo > mock > run rows > check the files, the vault, the mock's own state
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: test results
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (test-only file)
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const audi = @import("audit-log.zig");
const http = @import("http-call.zig");
const stat = @import("state-file.zig");
const vaul = @import("vault-file.zig");
const inpu = @import("line-input.zig");
const tool = @import("tool-exec.zig");
const engi = @import("step-engine.zig");
const forg = @import("forg-adapter.zig");
const mock = @import("mock-server.zig");
const host = @import("acts-host.zig");
const admi = @import("acts-admin.zig");
const repo = @import("acts-repo.zig");

const testOpts = http.Opts{ .trys = 3, .back = 1, .maxw = 2, .agen = "forgejo-test/1", .maxb = 1 << 20 };
const testCost = vaul.Cost{ .time = 1, .memo = 64, .para = 1 };
const trueCmd = [_][]const u8{"true"};
const falsCmd = [_][]const u8{"false"};

// one scratch world: host dirs, a git repo with an origin, a mock, a config, a vault, a state
const Env = struct {
    aren: std.heap.ArenaAllocator,
    tmpz: std.testing.TmpDir,
    root: []const u8,
    mock1: *mock.Mock,
    conf1: conf.Conf,
    logz: audi.Audi,
    tool1: tool.Tool,
    vaul1: vaul.Vaul,
    stat1: stat.Stat,
    http1: http.Http,
    down1: http.Http,
    forg1: forg.Forg,
    queu: inpu.Inpu,
    head1: []const u8,

    fn gpa(self: *Env) std.mem.Allocator {
        return self.aren.allocator();
    }

    fn path(self: *Env, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa(), &.{ self.root, name });
    }

    // build the world; returns false when git or ssh-keygen is missing
    fn init(self: *Env) !bool {
        self.aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        const alloc = self.aren.allocator();
        const io = std.testing.io;
        self.tmpz = std.testing.tmpDir(.{});
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const tlen = try self.tmpz.dir.realPath(io, &tbuf);
        self.root = try alloc.dupe(u8, tbuf[0..tlen]);

        var pare = std.process.Environ.Map.init(alloc);
        try pare.put("PATH", "/usr/bin:/bin:/usr/local/bin");
        try pare.put("HOME", self.root);
        self.logz = .{ .io = io, .path = try self.path("audit.log") };
        self.tool1 = try tool.Tool.init(alloc, io, &self.logz, &pare, 20);
        if (!self.tool1.have("git") or !self.tool1.have("ssh-keygen")) return false;

        // scratch git repo whose origin is a bare repo
        const repoDir = try self.path("repo");
        const origDir = try self.path("origin.git");
        try std.Io.Dir.cwd().createDirPath(io, repoDir);
        try std.Io.Dir.cwd().createDirPath(io, origDir);
        _ = try self.tool1.runz(&.{ "git", "init", "--quiet", "--bare" }, origDir);
        _ = try self.tool1.runz(&.{ "git", "init", "--quiet", "--initial-branch=main" }, repoDir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(alloc, &.{ repoDir, "readme.txt" }), .data = "x" });
        _ = try self.tool1.runz(&.{ "git", "-c", "user.email=a@b.co", "-c", "user.name=t", "add", "." }, repoDir);
        _ = try self.tool1.runz(&.{ "git", "-c", "user.email=a@b.co", "-c", "user.name=t", "commit", "--quiet", "-m", "x" }, repoDir);
        _ = try self.tool1.runz(&.{ "git", "remote", "add", "origin", origDir }, repoDir);
        _ = try self.tool1.runz(&.{ "git", "push", "--quiet", "origin", "main" }, repoDir);
        self.head1 = try alloc.dupe(u8, (try self.tool1.runz(&.{ "git", "rev-parse", "main" }, repoDir)).text());

        self.mock1 = try mock.Mock.star(io);

        // the shipped config, pointed at the scratch world
        var diag = conf.Diag{};
        self.conf1 = try conf.confLoad(alloc, io, "00-config.json", &diag);
        const c = &self.conf1;
        c.rele.base = try self.mock1.base(alloc, "/rel");
        c.rele.vers = "15.0.5";
        c.host.bina = try self.path("host/bin/forgejo");
        c.host.work = try self.path("host/work");
        c.host.conf = try self.path("host/etc/app.ini");
        c.host.unit = try self.path("host/unit/forgejo.service");
        c.bkup.svcf = try self.path("host/unit/forgejo-dump.service");
        c.bkup.tmrf = try self.path("host/unit/forgejo-dump.timer");
        c.bkup.enab = &trueCmd;
        c.host.pubh = "127.0.0.1";
        c.host.port = self.mock1.port;
        c.host.sshp = 2222;
        c.cmds.chek = &falsCmd;
        c.cmds.runa = &.{};
        c.cmds.mkus = &trueCmd;
        c.cmds.chow = &trueCmd;
        c.cmds.reld = &trueCmd;
        c.cmds.enab = &trueCmd;
        c.admi = .{ .user = "ann", .mail = "ann@example.com" };
        c.repo.path = repoDir;
        c.sshz.file = try self.path("keys/id_ed25519");
        c.boot = .{ .poll = 1, .wait = 5 };

        self.vaul1 = try vaul.Vaul.open(alloc, io, try self.path("vault.json"), "correct horse battery", testCost);
        self.stat1 = try stat.Stat.load(alloc, io, try self.path("state.json"));
        self.http1 = http.Http.init(alloc, io, &self.logz, testOpts);
        self.down1 = http.Http.init(alloc, io, &self.logz, .{ .trys = 3, .back = 1, .maxw = 2, .agen = "forgejo-test/1", .maxb = 1 << 20 });
        self.forg1 = .{ .gpa = alloc, .http = &self.http1, .apiz = try self.mock1.base(alloc, "/api/v1") };
        self.queu = inpu.Inpu{ .io = io };
        return true;
    }

    fn done(self: *Env) void {
        self.http1.deinit();
        self.down1.deinit();
        self.mock1.halt();
        self.tmpz.cleanup();
        self.aren.deinit();
    }

    fn engine(self: *Env) engi.Engi {
        return .{ .gpa = self.gpa(), .io = std.testing.io, .stat = &self.stat1, .inpu = &self.queu, .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 5 } };
    }

    fn hostCtx(self: *Env) host.Ctx {
        return .{ .gpa = self.gpa(), .io = std.testing.io, .conf = &self.conf1, .stat = &self.stat1, .tool = &self.tool1, .down = &self.down1, .forg = &self.forg1 };
    }

    fn admiCtx(self: *Env) admi.Ctx {
        return .{ .gpa = self.gpa(), .io = std.testing.io, .conf = &self.conf1, .vaul = &self.vaul1, .stat = &self.stat1, .tool = &self.tool1, .forg = &self.forg1 };
    }

    fn repoCtx(self: *Env) repo.Ctx {
        return .{ .gpa = self.gpa(), .conf = &self.conf1, .stat = &self.stat1, .tool = &self.tool1, .forg = &self.forg1 };
    }

    // run every row, as main does
    fn runAll(self: *Env, eng: *engi.Engi) !void {
        var hc = self.hostCtx();
        var ac = self.admiCtx();
        var rc = self.repoCtx();
        const all = host.rows(&hc) ++ admi.rows(&ac) ++ repo.rows(&rc);
        try eng.runAll(&all);
    }

    fn read(self: *Env, file: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, file, self.gpa(), .limited(1 << 20));
    }
};

test "full setup flow, then a second run that changes nothing" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    const gpa = env.gpa();
    env.mock1.downN = 1; // the server needs one more try to come up

    var eng = env.engine();
    try env.runAll(&eng);
    try std.testing.expectEqual(@as(u32, 11), eng.done);
    try std.testing.expectEqual(@as(u32, 0), eng.hand); // zero hand jobs

    // host: verified binary, app.ini, unit
    var hbuf: [64]u8 = undefined;
    const bina = try env.read(env.conf1.host.bina);
    try std.testing.expectEqualStrings(mock.fakeBina, bina);
    try std.testing.expectEqualStrings(mock.Mock.binaSha(&hbuf), env.stat1.data.idsz.binaSha);
    const ini = try env.read(env.conf1.host.conf);
    try std.testing.expect(std.mem.indexOf(u8, ini, "DISABLE_REGISTRATION = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ini, "DB_TYPE = sqlite3") != null);
    try std.testing.expect(std.mem.indexOf(u8, ini, "{") == null); // every placeholder filled
    const unit = try env.read(env.conf1.host.unit);
    try std.testing.expect(std.mem.indexOf(u8, unit, try std.fmt.allocPrint(gpa, "ExecStart={s} web --config {s}", .{ env.conf1.host.bina, env.conf1.host.conf })) != null);

    // lean ini + memory cap + nightly dump timer, all from config
    try std.testing.expect(std.mem.indexOf(u8, ini, "[packages]\nENABLED = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, ini, "ISSUE_INDEXER_TYPE = db") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "MemoryMax=") != null);
    const dsvc = try env.read(env.conf1.bkup.svcf);
    try std.testing.expect(std.mem.indexOf(u8, dsvc, "dump --config") != null and std.mem.indexOf(u8, dsvc, "{") == null);
    try std.testing.expect(std.mem.indexOf(u8, try env.read(env.conf1.bkup.tmrf), "OnCalendar=daily") != null);

    // admin + token: the fake CLI ran, the vault holds the token, nothing else holds it
    const users = try env.read(try env.path("host/bin/users.txt"));
    try std.testing.expect(std.mem.indexOf(u8, users, "ann ann@example.com") != null);
    try std.testing.expectEqualStrings("mocktoken-cloud-house", env.vaul1.getz("forg.token").?);
    const stat1 = try env.read(try env.path("state.json"));
    try std.testing.expect(std.mem.indexOf(u8, stat1, "mocktoken") == null);
    const logz = try env.read(try env.path("audit.log"));
    try std.testing.expect(std.mem.indexOf(u8, logz, "mocktoken") == null);

    // repo: private, features off, main protected without force push, one key
    try std.testing.expect(env.mock1.repoHave and env.mock1.repoPriv);
    try std.testing.expect(!env.mock1.hasWiki and !env.mock1.hasIssues and !env.mock1.hasPrs and !env.mock1.hasProjects and !env.mock1.hasActions);
    try std.testing.expect(env.mock1.protHave and env.mock1.protPush and !env.mock1.protForc);
    try std.testing.expectEqual(@as(usize, 1), env.mock1.keys.items.len);
    try std.testing.expectEqual(@as(u32, 0), env.mock1.bads);

    // push urls: the origin first, Forgejo second
    const urls = try env.tool1.runz(&.{ "git", "remote", "get-url", "--push", "--all", "origin" }, env.conf1.repo.path);
    var lines = std.mem.splitScalar(u8, urls.text(), '\n');
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "origin.git"));
    try std.testing.expectEqualStrings("ssh://git@127.0.0.1:2222/ann/cloud-house.git", lines.next().?);
    try std.testing.expect(lines.next() == null);

    // second run: fresh state file, same host, same vault: nothing new is made
    const before = env.mock1.seen;
    const keysBef = env.mock1.keys.items.len;
    const reqBef = env.mock1.seenCoun("POST");
    env.stat1 = try stat.Stat.load(gpa, std.testing.io, try env.path("state2.json"));
    var eng2 = env.engine();
    try env.runAll(&eng2);
    try std.testing.expectEqual(@as(u32, 11), eng2.done);
    try std.testing.expectEqual(reqBef, env.mock1.seenCoun("POST"));
    try std.testing.expectEqual(keysBef, env.mock1.keys.items.len);
    try std.testing.expect(env.mock1.seen > before);
    const users2 = try env.read(try env.path("host/bin/users.txt"));
    try std.testing.expectEqualStrings(users, users2);
    const urls2 = try env.tool1.runz(&.{ "git", "remote", "get-url", "--push", "--all", "origin" }, env.conf1.repo.path);
    try std.testing.expectEqualStrings(urls.text(), urls2.text());

    // drift: equal heads pass, a different head is refused
    var rc = env.repoCtx();
    env.mock1.headId = env.head1;
    const ok = try rc.driftChec();
    try std.testing.expectEqualStrings("heads match", ok.okay);
    env.mock1.headId = "ffffffffffffffffffffffffffffffffffffffff";
    try std.testing.expectError(error.Drift, rc.driftChec());

    // revoke: only the app-made token dies; the vault forgets it
    var ac = env.admiCtx();
    try ac.revoToke();
    try std.testing.expect(env.mock1.tokeGone);
    try std.testing.expect(env.mock1.basiPass.len >= 20);
    try std.testing.expect(env.vaul1.getz("forg.token") == null);
    const pass = try env.read(try env.path("host/bin/pass"));
    try std.testing.expectEqualStrings(env.mock1.basiPass, std.mem.trim(u8, pass, "\n"));
    const logz2 = try env.read(try env.path("audit.log"));
    try std.testing.expect(std.mem.indexOf(u8, logz2, env.mock1.basiPass) == null); // the password never reaches the log
}

test "bad checksum is refused and nothing is installed" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    env.mock1.badSum = true;
    var eng = env.engine();
    var hc = env.hostCtx();
    const rows = host.rows(&hc);
    try eng.runOne(rows[0]);
    try std.testing.expectError(error.SumMismatch, eng.runOne(rows[1]));
    try std.testing.expect(std.meta.isError(std.Io.Dir.accessAbsolute(std.testing.io, env.conf1.host.bina, .{})));
}

test "an unverified binary already in place is never overwritten" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try env.path("host/bin"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env.conf1.host.bina, .data = "mine" });
    var eng = env.engine();
    var hc = env.hostCtx();
    const rows = host.rows(&hc);
    try std.testing.expectError(error.BinaDiffers, eng.runOne(rows[1]));
    try std.testing.expectEqualStrings("mine", try env.read(env.conf1.host.bina));
}

test "an existing app.ini and unit are kept" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try env.path("host/etc"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env.conf1.host.conf, .data = "[mine]\n" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try env.path("host/unit"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = env.conf1.host.unit, .data = "[mine]\n" });
    var eng = env.engine();
    var hc = env.hostCtx();
    const rows = host.rows(&hc);
    try eng.runOne(rows[2]);
    try eng.runOne(rows[3]);
    try std.testing.expectEqualStrings("[mine]\n", try env.read(env.conf1.host.conf));
    try std.testing.expectEqualStrings("[mine]\n", try env.read(env.conf1.host.unit));
}

test "admin steps refuse a missing name, and a lost token secret is reported" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    // the fake binary must exist for the CLI steps
    var eng = env.engine();
    var hc = env.hostCtx();
    try eng.runOne(host.rows(&hc)[1]);
    var ac = env.admiCtx();
    const rows = admi.rows(&ac);

    env.conf1.admi.user = "";
    try std.testing.expectError(error.NoAdminName, eng.runOne(rows[0]));
    env.conf1.admi.user = "ann";
    try eng.runOne(rows[0]);
    try eng.runOne(rows[1]);
    try std.testing.expectEqualStrings("mocktoken-cloud-house", env.vaul1.getz("forg.token").?);

    // the vault is lost, the token name is already used: the app says so and keeps the vault empty
    try env.vaul1.drop("forg.token");
    env.stat1 = try stat.Stat.load(env.gpa(), std.testing.io, try env.path("state3.json"));
    try std.testing.expectError(error.TokenMintFail, eng.runOne(rows[1]));
    try std.testing.expect(env.vaul1.getz("forg.token") == null);
}

test "repo step refuses a repo whose visibility differs from the config" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    env.forg1.toke = "mocktoken-x";
    env.stat1.data.idsz.adminUser = "ann";
    _ = try env.forg1.repoMake("cloud-house", false, "main"); // someone made it public by hand
    var eng = env.engine();
    var rc = env.repoCtx();
    try std.testing.expectError(error.VisibilityDiffers, eng.runOne(repo.rows(&rc)[1]));
}

test "repo step takes visibility from the config: public creates a public repo" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    env.forg1.toke = "mocktoken-x";
    env.stat1.data.idsz.adminUser = "ann";
    env.conf1.frep.visi = "public";
    var eng = env.engine();
    var rc = env.repoCtx();
    _ = try eng.runOne(repo.rows(&rc)[1]);
    try std.testing.expect(!env.mock1.repoPriv);
}

test "repo step with a public config refuses a repo that is private" {
    var env: Env = undefined;
    if (!try env.init()) return error.SkipZigTest;
    defer env.done();
    env.forg1.toke = "mocktoken-x";
    env.stat1.data.idsz.adminUser = "ann";
    env.conf1.frep.visi = "public";
    _ = try env.forg1.repoMake("cloud-house", true, "main");
    var eng = env.engine();
    var rc = env.repoCtx();
    try std.testing.expectError(error.VisibilityDiffers, eng.runOne(repo.rows(&rc)[1]));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
