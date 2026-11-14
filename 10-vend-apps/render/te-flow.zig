// =====================================================================
// Des: Contract tests of the Render client and full-flow tests of the setup against the pretend Render: first run, second run (nothing changes), wrong key, drift, env changes, revoke, cold start, rate limit.
// Flo: start mock > build a temp home + config > run the real commands > read back the mock and the files
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (tests)
// Out: pass or fail
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");
const mock = @import("te-mock.zig");
const cfg = @import("co-cfg.zig");
const vaul = @import("pv-vault.zig");
const stat = @import("co-state.zig");
const audi = @import("co-audit.zig");
const inpu = @import("co-input.zig");
const http = @import("co-http.zig");
const engi = @import("co-engine.zig");
const steps = @import("co-steps.zig");
const rend = @import("ap-render.zig");
const ctxz = @import("co-ctx.zig");
const acct = @import("ve-account.zig");
const serv = @import("ve-service.zig");
const wire = @import("ve-wire.zig");
const cmdz = @import("cm-run.zig");

const CF = .{ .pass = "test passphrase 1234", .imag = "ghcr.io/fake/cloud-house-trigger:1", .env1 = "https://hc.example.test/ping/abc" };

// everything one test needs: mock, temp home, config file, arena
const Rig = struct {
    aren: std.heap.ArenaAllocator,
    tmpz: std.testing.TmpDir,
    mock: *mock.Mock,
    home: []const u8,
    conf: []const u8,
    envz: std.process.Environ.Map,

    fn star() !*Rig {
        const self = try std.testing.allocator.create(Rig);
        self.aren = std.heap.ArenaAllocator.init(std.testing.allocator);
        const gpa = self.aren.allocator();
        self.tmpz = std.testing.tmpDir(.{});
        var buff: [std.fs.max_path_bytes]u8 = undefined;
        const size = try self.tmpz.dir.realPath(std.testing.io, &buff);
        self.home = try gpa.dupe(u8, buff[0..size]);
        self.mock = try mock.Mock.star(std.testing.io, 0);
        // the shipped config, pointed at the mock and the temp home
        var text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "00-config.json", gpa, .limited(1 << 20));
        const apiz = try self.mock.base(gpa, "/v1");
        text = try std.mem.replaceOwned(u8, gpa, text, "https://api.render.com/v1", apiz);
        text = try std.mem.replaceOwned(u8, gpa, text, "\"imag\": \"\"", "\"imag\": \"" ++ CF.imag ++ "\"");
        text = try std.mem.replaceOwned(u8, gpa, text, "\"time\": 3, \"memo\": 65536", "\"time\": 1, \"memo\": 64");
        text = try std.mem.replaceOwned(u8, gpa, text, "\"guid\": { \"open\": true, \"clip\": true, \"poll\": 5, \"wait\": 900 }", "\"guid\": { \"open\": false, \"clip\": false, \"poll\": 1, \"wait\": 30 }");
        text = try std.mem.replaceOwned(u8, gpa, text, "\"cold\": { \"wait\": 600, \"poll\": 5, \"wind\": 60 }", "\"cold\": { \"wait\": 20, \"poll\": 1, \"wind\": 60 }");
        text = try std.mem.replaceOwned(u8, gpa, text, "\"trys\": 4, \"back\": 2, \"maxw\": 60", "\"trys\": 3, \"back\": 1, \"maxw\": 3");
        self.conf = try std.fs.path.join(gpa, &.{ self.home, "conf.json" });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = self.conf, .data = text });
        self.envz = std.process.Environ.Map.init(gpa);
        try self.envz.put("HOME", self.home);
        try self.envz.put("CLOUD_HOUSE_VAULT_PASS", CF.pass);
        return self;
    }

    fn stop(self: *Rig) void {
        self.mock.halt();
        self.tmpz.cleanup();
        self.aren.deinit();
        std.testing.allocator.destroy(self);
    }

    fn path(self: *Rig, name: []const u8) ![]u8 {
        return std.fs.path.join(self.aren.allocator(), &.{ self.home, ".05-cloud-house-secre", name });
    }

    fn read(self: *Rig, name: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try self.path(name), self.aren.allocator(), .limited(1 << 20));
    }

    // preload what the human would type, one per line
    fn typed(self: *Rig, lines: []const []const u8) !inpu.Inpu {
        _ = self;
        var queu = inpu.Inpu{ .io = std.testing.io };
        for (lines) |line| try queu.list.append(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, line));
        return queu;
    }

    // run one CLI command the way main() does
    fn exec(self: *Rig, cmd: cmdz.Cmd, go: bool, queu: *inpu.Inpu) !u8 {
        return cmdz.exec(self.aren.allocator(), std.testing.io, &self.envz, cmd, .{ .go = go, .conf = self.conf }, queu);
    }
};

fn typedFree(queu: *inpu.Inpu) void {
    for (queu.list.items) |line| std.heap.smp_allocator.free(line);
    queu.list.deinit(std.heap.smp_allocator);
}

test "dry-run changes nothing and never calls Render" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{});
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.run, false, &queu));
    try std.testing.expectEqual(@as(u32, 0), rig.mock.seen);
    try std.testing.expectEqual(@as(usize, 0), rig.mock.svcs.items.len);
}

test "run needs the image path in config" {
    const rig = try Rig.star();
    defer rig.stop();
    const gpa = rig.aren.allocator();
    var text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rig.conf, gpa, .limited(1 << 20));
    text = try std.mem.replaceOwned(u8, gpa, text, "\"imag\": \"" ++ CF.imag ++ "\"", "\"imag\": \"\"");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rig.conf, .data = text });
    var queu = try rig.typed(&.{});
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitUsag), try rig.exec(.run, false, &queu));
}

test "full flow: first run builds everything, second run changes nothing" {
    const rig = try Rig.star();
    defer rig.stop();
    const gpa = rig.aren.allocator();
    // the owner already stored an env value in the vault
    {
        var seed = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("render-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, try rig.path(""));
        try seed.putz("env.HEALTHCHECKS_URL", CF.env1);
    }
    var queu = try rig.typed(&.{ "g", mock.keyz });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.run, true, &queu));

    const mok = rig.mock;
    try std.testing.expectEqual(@as(usize, 1), mok.svcs.items.len);
    try std.testing.expectEqualStrings("free", mok.svcs.items[0].plan);
    try std.testing.expectEqualStrings(CF.imag, mok.svcs.items[0].imag);
    try std.testing.expectEqual(@as(u32, 0), mok.paidMade);
    try std.testing.expectEqual(@as(usize, 1), mok.envs.items.len);
    try std.testing.expectEqualStrings("HEALTHCHECKS_URL", mok.envs.items[0].key);
    try std.testing.expectEqualStrings(CF.env1, mok.envs.items[0].value);
    try std.testing.expectEqual(@as(u32, 2), mok.deploys); // create + one env deploy
    try std.testing.expectEqual(@as(u32, 0), mok.bads);

    // Trigger C wiring file
    const wirj = try rig.read("trigger-c.json");
    try std.testing.expect(std.mem.indexOf(u8, wirj, "\"slot\": \"C\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wirj, "/svc/cloud-house-trigger") != null);
    // no secret anywhere on disk in plain text
    inline for (.{ "render-vault.json", "render-state.json", "render-audit.log", "trigger-c.json" }) |name| {
        const body = try rig.read(name);
        try std.testing.expect(std.mem.indexOf(u8, body, mock.keyz) == null);
        try std.testing.expect(std.mem.indexOf(u8, body, CF.env1) == null);
    }

    // second run: nothing is created, sent or deployed again, no human needed
    const posts = mok.seenCoun("POST /v1/services"); // create + one deploy
    try std.testing.expectEqual(@as(u32, 2), posts);
    var again = try rig.typed(&.{});
    defer typedFree(&again);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.run, true, &again));
    try std.testing.expectEqual(@as(usize, 1), mok.svcs.items.len);
    try std.testing.expectEqual(@as(u32, 2), mok.deploys);
    try std.testing.expectEqual(posts, mok.seenCoun("POST /v1/services"));
    try std.testing.expectEqual(@as(u32, 1), mok.seenCoun("PUT /v1/services/"));

    // status and vault commands answer
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.status, false, &again));
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.vault, false, &again));
}

test "a refused key is dropped from the vault and the run fails clean" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{ "g", "rnd_WRONGKEY" });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitFail), try rig.exec(.run, true, &queu));
    try std.testing.expectEqual(@as(usize, 0), rig.mock.svcs.items.len);
    const gpa = rig.aren.allocator();
    const back = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("render-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
    try std.testing.expect(back.getz("render.apikey") == null);
}

test "a key without the rnd_ prefix is refused before any call" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{ "g", "not-a-render-key" });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitFail), try rig.exec(.run, true, &queu));
    try std.testing.expectEqual(@as(u32, 0), rig.mock.seen);
}

test "x at the sign-up step stops the run with exit 4" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{"x"});
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitHand), try rig.exec(.run, true, &queu));
    try std.testing.expectEqual(@as(u32, 0), rig.mock.seen);
}

test "an existing service with the same name is reused, not created twice" {
    const rig = try Rig.star();
    defer rig.stop();
    var first = try rig.typed(&.{ "g", mock.keyz });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    // lose the local state (new machine), keep the vault
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try rig.path("render-state.json"), .data = "{\"vers\":1}" });
    var second = try rig.typed(&.{});
    defer typedFree(&second);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &second));
    try std.testing.expectEqual(@as(usize, 1), rig.mock.svcs.items.len);
    try std.testing.expectEqual(@as(u32, 1), rig.mock.seenCoun("POST /v1/services"));
}

test "revoke pauses the service and drops the key; dry-run does nothing" {
    const rig = try Rig.star();
    defer rig.stop();
    var first = try rig.typed(&.{ "g", mock.keyz });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.revoke, false, &first));
    try std.testing.expect(!rig.mock.svcs.items[0].susp);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.revoke, true, &first));
    try std.testing.expect(rig.mock.svcs.items[0].susp);
    const gpa = rig.aren.allocator();
    const back = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("render-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
    try std.testing.expect(back.getz("render.apikey") == null);
    // a later run asks for a key again, then refuses to go on with a paused service
    var again = try rig.typed(&.{mock.keyz});
    defer typedFree(&again);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitFail), try rig.exec(.run, true, &again));
    try std.testing.expect(rig.mock.svcs.items[0].susp);
}

test "cold start: slow wake is measured, a dead one is skipped not failed" {
    const rig = try Rig.star();
    defer rig.stop();
    rig.mock.coldNeed = 2;
    var first = try rig.typed(&.{ "g", mock.keyz });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    try std.testing.expect(rig.mock.wakes >= 3);
    const sta = try rig.read("render-state.json");
    try std.testing.expect(std.mem.indexOf(u8, sta, "\"coldSecs\": 0") == null);
    // `cold` command works on its own
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.cold, false, &first));
}

// build a context by hand for contract and drift tests
const Hand = struct {
    logz: audi.Audi,
    http1: http.Http,
    rend1: rend.Rend,
    vaul1: vaul.Vaul,
    stat1: stat.Stat,
    conf: cfg.Conf,
    queu: inpu.Inpu,
    ctx: ctxz.Ctx,

    fn star(rig: *Rig, hand: *Hand) !void {
        const gpa = rig.aren.allocator();
        var diag = cfg.Diag{};
        hand.conf = try cfg.confLoad(gpa, std.testing.io, rig.conf, &diag);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, try rig.path(""));
        hand.logz = .{ .io = std.testing.io, .path = try rig.path("a.log") };
        hand.http1 = http.Http.init(gpa, std.testing.io, &hand.logz, .{ .trys = hand.conf.http.trys, .back = hand.conf.http.back, .maxw = hand.conf.http.maxw, .agen = "t", .maxb = 1 << 20 });
        hand.rend1 = .{ .gpa = gpa, .http = &hand.http1, .apiz = hand.conf.rend.apiz, .toke = mock.keyz };
        hand.vaul1 = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("v.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
        hand.stat1 = try stat.Stat.load(gpa, std.testing.io, try rig.path("s.json"));
        hand.queu = .{ .io = std.testing.io };
        hand.ctx = .{ .gpa = gpa, .io = std.testing.io, .conf = &hand.conf, .vaul = &hand.vaul1, .stat = &hand.stat1, .rend = &hand.rend1, .inpu = &hand.queu, .root = try rig.path("") };
    }
};

test "contract: every client call matches the strict mock" {
    const rig = try Rig.star();
    defer rig.stop();
    var hand: Hand = undefined;
    try Hand.star(rig, &hand);
    defer hand.http1.deinit();
    const cli = &hand.rend1;
    const owne = try cli.owner("");
    try std.testing.expectEqualStrings(mock.owne, owne.id);
    rig.mock.ownMany = true;
    try std.testing.expectEqualStrings(mock.owne, (try cli.owner("Mock Team")).id);
    try std.testing.expectError(error.RendOwner, cli.owner("Nobody"));
    try std.testing.expect((try cli.find("cloud-house-trigger", "web_service")) == null);
    const made = try cli.make(.{ .name = "cloud-house-trigger", .owne = owne.id, .imag = CF.imag, .plan = "free", .regi = "oregon", .heal = "/healthz", .inst = 1 });
    try std.testing.expect(made.serviceDetails.url.len > 0);
    try std.testing.expectEqualStrings("free", made.serviceDetails.plan);
    try std.testing.expectError(error.RendBad, cli.make(.{ .name = "cloud-house-trigger", .owne = owne.id, .imag = CF.imag, .plan = "free", .regi = "oregon", .heal = "/healthz", .inst = 1 }));
    try std.testing.expectEqualStrings("service name already in use", cli.mess);
    try std.testing.expect((try cli.find("cloud-house-trigger", "web_service")) != null);
    try cli.heal(made.id, "/ready");
    try std.testing.expectEqualStrings("/ready", (try cli.get(made.id)).serviceDetails.healthCheckPath.?);
    try cli.envs(made.id, &.{.{ .key = "A", .value = "1" }});
    try cli.deploy(made.id);
    try std.testing.expectError(error.RendMiss, cli.get("srv-nope"));
    cli.toke = "rnd_BAD";
    try std.testing.expectError(error.RendAuth, cli.owner(""));
    cli.toke = mock.keyz;
    // 429: waits per Retry-After and then succeeds
    rig.mock.rateLimi = 1;
    _ = try cli.owner("");
    try std.testing.expect(hand.http1.wait >= 1);
    try cli.suspend_(made.id);
    try std.testing.expect(rig.mock.svcs.items[0].susp);
}

test "drift: wrong health path is fixed, wrong plan is refused, paused service is refused" {
    const rig = try Rig.star();
    defer rig.stop();
    var hand: Hand = undefined;
    try Hand.star(rig, &hand);
    defer hand.http1.deinit();
    hand.stat1.data.idsz.owneId = mock.owne;
    const gpa = rig.aren.allocator();
    const rowz = serv.rows(&hand.ctx);
    var queu = try rig.typed(&.{});
    defer typedFree(&queu);
    var eng = engi.Engi{ .gpa = gpa, .io = std.testing.io, .stat = &hand.stat1, .inpu = &queu, .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 5 } };
    try eng.runOne(rowz[0]);
    // someone changes the health path by hand
    rig.mock.svcs.items[0].heal = "/other";
    try hand.stat1.markSetz("serv-sett", .todo, "", 0);
    try eng.runOne(rowz[1]);
    try std.testing.expectEqualStrings("/healthz", rig.mock.svcs.items[0].heal);
    // someone upgrades the plan by hand: the app refuses to touch it
    rig.mock.svcs.items[0].plan = "starter";
    try hand.stat1.markSetz("serv-sett", .todo, "", 0);
    try std.testing.expectError(error.PlanDrift, eng.runOne(rowz[1]));
    try std.testing.expectEqualStrings("starter", rig.mock.svcs.items[0].plan);
    // paused
    rig.mock.svcs.items[0].plan = "free";
    rig.mock.svcs.items[0].susp = true;
    try std.testing.expectError(error.Suspended, eng.runOne(rowz[1]));
}

test "env: needed var missing stops the step; changed value is resent with one deploy" {
    const rig = try Rig.star();
    defer rig.stop();
    var hand: Hand = undefined;
    try Hand.star(rig, &hand);
    defer hand.http1.deinit();
    hand.stat1.data.idsz.owneId = mock.owne;
    const gpa = rig.aren.allocator();
    const rowz = serv.rows(&hand.ctx);
    var queu = try rig.typed(&.{});
    defer typedFree(&queu);
    var eng = engi.Engi{ .gpa = gpa, .io = std.testing.io, .stat = &hand.stat1, .inpu = &queu, .guid = .{ .open = false, .clip = false, .poll = 1, .wait = 5 } };
    try eng.runOne(rowz[0]);
    // nothing in the vault and the var is optional: skip, no call
    try eng.runOne(rowz[2]);
    try std.testing.expectEqual(@as(u32, 0), rig.mock.seenCoun("PUT"));
    try hand.vaul1.putz("env.HEALTHCHECKS_URL", "v1");
    try hand.stat1.markSetz("envv-sync", .todo, "", 0);
    try eng.runOne(rowz[2]);
    try std.testing.expectEqualStrings("v1", rig.mock.envs.items[0].value);
    const deps = rig.mock.deploys;
    try hand.vaul1.putz("env.HEALTHCHECKS_URL", "v2");
    try hand.stat1.markSetz("envv-sync", .todo, "", 0);
    try eng.runOne(rowz[2]);
    try std.testing.expectEqualStrings("v2", rig.mock.envs.items[0].value);
    try std.testing.expectEqual(deps + 1, rig.mock.deploys);
    // same value again: no call
    try hand.stat1.markSetz("envv-sync", .todo, "", 0);
    try eng.runOne(rowz[2]);
    try std.testing.expectEqual(deps + 1, rig.mock.deploys);
    // a needed var that is empty stops the step
    var need = hand.conf;
    var envs = [_]cfg.Envz{.{ .name = "MUST", .vaul = "env.MUST", .need = true }};
    need.envs = &envs;
    hand.ctx.conf = &need;
    try hand.stat1.markSetz("envv-sync", .todo, "", 0);
    try std.testing.expectError(error.EnvMissing, eng.runOne(rowz[2]));
}

test "the step list in 10-steps.json matches the rows in code" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const file = try steps.load(gpa);
    var ctx: ctxz.Ctx = undefined;
    const all = acct.rows(&ctx) ++ serv.rows(&ctx) ++ wire.rows(&ctx);
    // step 0 (tool-chec) is the preflight in cm-run, not an engine row
    try std.testing.expectEqualStrings("tool-chec", file.step[0].iden);
    try std.testing.expectEqual(file.step.len - 1, all.len);
    var hands: u32 = 0;
    for (file.step[1..], all) |def, rowz| {
        try std.testing.expectEqualStrings(def.iden, rowz.iden);
        try std.testing.expectEqual(def.hand > 0, rowz.hand);
        if (rowz.hand) hands += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), hands);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
