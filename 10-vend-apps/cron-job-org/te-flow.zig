// =====================================================================
// Des: End-to-end flow tests against the pretend cron-job.org on a spare loopback port, with a temp home, a fake API key and a fake vault passphrase. They run the real engine, the real actions and the real commands.
// Flo: rig: mock + temp home + config pointed at the mock > boot > run / status / usage / revoke > check the mock, the files and the exit codes
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: test results
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (test file)
// =====================================================================
const std = @import("std");
const conf = @import("co-cfg.zig");
const boot = @import("cm-boot.zig");
const engi = @import("co-engine.zig");
const tabl = @import("ve-table.zig");
const crun = @import("cm-run.zig");
const cinf = @import("cm-info.zig");
const crev = @import("cm-revo.zig");
const mock = @import("te-mock.zig");

const CF = .{ .passEnvz = "CLOUD_HOUSE_VAULT_PASS", .passVal = "test-vault-pass-1", .keyEnvz = "CRONJOBORG_KEY", .fileMax = 1 << 20 };

// everything one test needs; built in place (the Boot holds pointers into it)
const Rig = struct {
    aren: std.heap.ArenaAllocator,
    tmpz: std.testing.TmpDir,
    mk: *mock.Mock,
    cfg: conf.Conf,
    env: std.process.Environ.Map,
    bt: boot.Boot,
    root: []const u8,
    steps: conf.Steps,

    // envKey: the API key comes from the env var (no hand job)
    fn init(self: *Rig, envKey: bool) !void {
        self.aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        const a = self.aren.allocator();
        const io = std.testing.io;
        self.tmpz = std.testing.tmpDir(.{});
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const tlen = try self.tmpz.dir.realPath(io, &tbuf);
        self.root = try std.fs.path.join(a, &.{ tbuf[0..tlen], "home" });
        self.mk = try mock.Mock.star(io);
        var diag = conf.Diag{};
        self.cfg = try conf.confLoad(a, io, "00-config.json", &diag);
        self.steps = try conf.stepLoad(a, io, "no-such-steps.json", &diag);
        self.cfg.cron.base = try self.mk.base(a);
        self.cfg.tick.urlz = try self.mk.tickUrl(a);
        self.cfg.vaul.time = 1;
        self.cfg.vaul.memo = 64;
        self.cfg.vaul.para = 1;
        self.cfg.http.back = 1;
        self.cfg.http.maxw = 1;
        self.cfg.http.trys = 2;
        self.cfg.guid.open = false;
        self.cfg.guid.poll = 1;
        self.cfg.guid.wait = 20;
        self.cfg.veri.gap = 0;
        self.cfg.veri.tries = 2;
        self.env = std.process.Environ.Map.init(a);
        try self.env.put("PATH", "/usr/bin:/bin");
        try self.env.put(CF.passEnvz, CF.passVal);
        if (envKey) try self.env.put(CF.keyEnvz, mock.keyz);
        try self.start();
    }

    // (re)build the Boot: reloads the state file from disk, closes the vault
    fn start(self: *Rig) !void {
        try self.bt.init(self.aren.allocator(), std.testing.io, &self.env, &self.cfg, self.steps, self.root);
    }

    fn deinit(self: *Rig) void {
        self.mk.halt();
        self.tmpz.cleanup();
        self.aren.deinit();
    }

    fn run(self: *Rig) !engi.Report {
        const rep = try engi.run(&self.bt.ctx, &tabl.table);
        if (rep.code != 0) std.debug.print("run stopped at {s} code {d}: {s}\n", .{ rep.stop_at orelse "-", rep.code, self.bt.ctx.lastFail });
        return rep;
    }

    // a second command in a fresh process: reboot, then run
    fn again(self: *Rig) !engi.Report {
        try self.start();
        return self.run();
    }

    fn fileText(self: *Rig, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.aren.allocator(), &.{ self.root, name });
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, self.aren.allocator(), .limited(CF.fileMax)) catch "";
    }

    // a vault value (opens the vault with the test passphrase)
    fn vaulGet(self: *Rig, key: []const u8) !?[]const u8 {
        const vlt = try self.bt.ctx.vault();
        return vlt.getz(key);
    }

    fn feed(self: *Rig, text: []const u8) !void {
        const smp = std.heap.smp_allocator;
        try self.bt.line.list.append(smp, try smp.dupe(u8, text));
    }
};

fn has(hay: []const u8, need: []const u8) bool {
    return std.mem.indexOf(u8, hay, need) != null;
}

// history reads the mock saw
fn histCoun(mk: *mock.Mock) u32 {
    var coun: u32 = 0;
    for (mk.logz.items) |item| if (has(item, "/history")) {
        coun += 1;
    };
    return coun;
}

// all headers of a mock job as a name list contains the name
fn headHas(job: anytype, name: []const u8) bool {
    for (job.heads) |hd| if (std.ascii.eqlIgnoreCase(hd.name, name)) return true;
    return false;
}

test "full setup with the key in an env var: job made, verified by a tick, no secret leaks" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 7), rep.done + rep.skipped);
    try std.testing.expectEqual(@as(u32, 0), r.bt.ctx.handled);
    try std.testing.expectEqual(@as(u32, 0), r.mk.bads);
    try std.testing.expectEqual(@as(u32, 0), r.mk.deletes);
    try std.testing.expectEqual(@as(usize, 1), r.mk.jobs.items.len);
    const job = r.mk.jobs.items[0];
    try std.testing.expect(job.enabled);
    try std.testing.expectEqualStrings(r.cfg.tick.urlz, job.url);
    try std.testing.expectEqual(@as(i64, 1), job.meth);
    try std.testing.expectEqual(@as(i64, 25), job.tmoz);
    try std.testing.expect(job.nfail and job.nsucc and job.ndisa);
    try std.testing.expect(headHas(job, "X-Tick-Secret") and headHas(job, "Content-Type"));
    // the tick the mock fired carried the vaulted secret
    const secr = (try r.vaulGet(r.cfg.vaul.keyt)).?;
    try std.testing.expectEqual(@as(usize, r.cfg.tick.seca * 2), secr.len);
    try std.testing.expectEqualStrings(secr, r.mk.tickSecret);
    try std.testing.expect(r.mk.tickRuns >= 1);
    // no secret anywhere but the vault
    const key = mock.keyz;
    for ([_][]const u8{ "cronjoborg-state.json", "cronjoborg-audit.log", "cronjoborg-handoff.json", "cronjoborg-vault.json" }) |name| {
        const text = try r.fileText(name);
        try std.testing.expect(text.len > 0);
        try std.testing.expect(!has(text, key));
        try std.testing.expect(!has(text, secr));
    }
    try std.testing.expect(has(try r.fileText("cronjoborg-handoff.json"), "cronjoborg.tick"));
    // the day counter matches what the mock saw
    try std.testing.expectEqual(r.mk.authReqs, r.bt.cron.used());
}

test "second run changes nothing and costs at most 3 requests" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    const before = r.mk.authReqs;
    const puts = r.mk.seenCoun("PUT ");
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expect(r.mk.authReqs - before <= 3);
    try std.testing.expectEqual(puts, r.mk.seenCoun("PUT "));
    try std.testing.expectEqual(@as(u32, 0), r.mk.seenCoun("PATCH "));
    try std.testing.expectEqual(@as(usize, 1), r.mk.jobs.items.len);
    try std.testing.expectEqual(@as(u32, 1), r.mk.creates);
}

test "two hand jobs: sign-up g, key g, hidden key typed; then the key is vaulted" {
    var r: Rig = undefined;
    try r.init(false);
    defer r.deinit();
    try r.feed("g");
    try r.feed("g");
    try r.feed(mock.keyz);
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 2), r.bt.ctx.handled);
    try std.testing.expectEqualStrings(mock.keyz, (try r.vaulGet(r.cfg.vaul.keya)).?);
    // a later run needs no hand job
    const again = try r.again();
    try std.testing.expectEqual(@as(u8, 0), again.code);
    try std.testing.expectEqual(@as(u32, 0), r.bt.ctx.handled);
}

test "a wrong key is refused, not vaulted, and the next run asks again" {
    var r: Rig = undefined;
    try r.init(false);
    defer r.deinit();
    try r.env.put(CF.keyEnvz, "not-the-key");
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 4), rep.code);
    try std.testing.expectEqualStrings("keyz-make", rep.stop_at.?);
    try std.testing.expect((try r.vaulGet(r.cfg.vaul.keya)) == null);
    try std.testing.expectEqual(@as(u32, 0), r.mk.creates);
    try std.testing.expect(!has(try r.fileText("cronjoborg-audit.log"), "not-the-key"));
}

test "a locked IP (403) stops with a fix and vaults nothing" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.lockIp = true;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expect(has(r.bt.ctx.lastFail, "locked"));
    try std.testing.expect((try r.vaulGet(r.cfg.vaul.keya)) == null);
}

test "drift: a switched-off job and a changed timeout are put back with one patch" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    r.mk.jobOff(0);
    r.mk.jobTmo(0, 10);
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 1), r.mk.seenCoun("PATCH "));
    try std.testing.expect(r.mk.jobs.items[0].enabled);
    try std.testing.expectEqual(@as(i64, 25), r.mk.jobs.items[0].tmoz);
    try std.testing.expectEqual(@as(u32, 1), r.mk.creates);
}

test "a job deleted at the vendor is made again" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    r.mk.jobs.clearRetainingCapacity();
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 2), r.mk.creates);
    try std.testing.expectEqual(@as(usize, 1), r.mk.jobs.items.len);
}

test "two jobs with our title: refused, nothing created, nothing deleted" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try r.mk.jobAdd(r.cfg.jobz.titl, "https://a.test/x");
    try r.mk.jobAdd(r.cfg.jobz.titl, "https://b.test/x");
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("job-sync", rep.stop_at.?);
    try std.testing.expectEqual(@as(u32, 0), r.mk.creates);
    try std.testing.expectEqual(@as(u32, 0), r.mk.deletes);
    try std.testing.expectEqual(@as(usize, 2), r.mk.jobs.items.len);
}

test "one job with our title is adopted and repaired, not duplicated" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try r.mk.jobAdd(r.cfg.jobz.titl, "https://old.test/x");
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 0), r.mk.creates);
    try std.testing.expectEqual(@as(usize, 1), r.mk.jobs.items.len);
    try std.testing.expectEqualStrings(r.cfg.tick.urlz, r.mk.jobs.items[0].url);
}

test "the daily limit stops the app before the next request is sent" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.cfg.limi.dayl = 3;
    try r.start();
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("job-veri", rep.stop_at.?);
    try std.testing.expectEqual(@as(u32, 3), r.mk.authReqs);
    try std.testing.expect(has(r.bt.ctx.lastFail, "daily request limit"));
}

test "a create blocked by the vendor (429) is reported, nothing is half-made" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.createMax = 0;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("job-sync", rep.stop_at.?);
    try std.testing.expectEqual(@as(usize, 0), r.mk.jobs.items.len);
    try std.testing.expectEqual(r.mk.authReqs, r.bt.cron.used());
}

test "a tick target that refuses the secret: run ends ok with a note, status says 3" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.tickWant = "some-other-secret";
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 2), rep.skipped); // sign-up (key from env) + the bad tick note
    try std.testing.expectEqual(@as(u8, 3), try cinf.status(&r.bt.ctx));
}

test "no tick yet: verify tries the set number of times, then notes it" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.autoTick = false;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 2), rep.skipped); // sign-up (key from env) + no tick yet
    try std.testing.expectEqual(r.cfg.veri.tries, histCoun(r.mk));
}

test "status and usage: exit 0 when healthy, 3 when off or near the limit" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    try std.testing.expectEqual(@as(u8, 0), try cinf.status(&r.bt.ctx));
    try std.testing.expectEqual(@as(u8, 0), cinf.usage(&r.bt.ctx));
    r.mk.jobOff(0);
    try std.testing.expectEqual(@as(u8, 3), try cinf.status(&r.bt.ctx));
    r.cfg.limi.warn = 1;
    try std.testing.expectEqual(@as(u8, 3), cinf.usage(&r.bt.ctx));
}

test "changed tick secret in the vault is pushed to the job" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    const vlt = try r.bt.ctx.vault();
    try vlt.putz(r.cfg.vaul.keyt, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 1), r.mk.seenCoun("PATCH "));
    try std.testing.expectEqualStrings("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", r.mk.tickSecret);
}

test "a reply without notification fields never causes endless patching" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.hideNoti = true;
    _ = try r.run();
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 0), r.mk.seenCoun("PATCH "));
}

test "tick url from the Trigger layer's handoff file; missing file is a clear failure" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.cfg.tick.urlz = "";
    try r.start();
    const bad = try r.run();
    try std.testing.expectEqual(@as(u8, 1), bad.code);
    try std.testing.expectEqualStrings("tick-reso", bad.stop_at.?);
    try std.testing.expectEqual(@as(u32, 0), r.mk.creates);
    const text = try std.fmt.allocPrint(r.aren.allocator(), "{{\"tick_url\":\"{s}\"}}", .{try r.mk.tickUrl(r.aren.allocator())});
    const path = try std.fs.path.join(r.aren.allocator(), &.{ r.root, r.cfg.tick.from });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
    const good = try r.again();
    try std.testing.expectEqual(@as(u8, 0), good.code);
    try std.testing.expectEqual(@as(u32, 1), r.mk.creates);
}

test "dry-run touches nothing: no request, no vault file" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), try crun.run(&r.bt.ctx, false));
    try std.testing.expectEqual(@as(u32, 0), r.mk.seen);
    try std.testing.expectEqual(@as(usize, 0), (try r.fileText("cronjoborg-vault.json")).len);
}

test "revoke: dry-run changes nothing; --go turns the job off and forgets the secrets; a re-run turns it on again" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    try r.start();
    const seen = r.mk.seen;
    try std.testing.expectEqual(@as(u8, 0), try crev.revoke(&r.bt.ctx, false));
    try std.testing.expectEqual(seen, r.mk.seen);
    try std.testing.expect(r.mk.jobs.items[0].enabled);
    try std.testing.expectEqual(@as(u8, 0), try crev.revoke(&r.bt.ctx, true));
    try std.testing.expect(!r.mk.jobs.items[0].enabled);
    try std.testing.expectEqual(@as(u32, 0), r.mk.deletes);
    try std.testing.expect((try r.vaulGet(r.cfg.vaul.keya)) == null);
    try std.testing.expect((try r.vaulGet(r.cfg.vaul.keyt)) == null);
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expect(r.mk.jobs.items[0].enabled);
    try std.testing.expectEqual(@as(u32, 1), r.mk.creates);
}

test "no code path ever sends DELETE" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    r.mk.jobOff(0);
    _ = try r.again();
    _ = try crev.revoke(&r.bt.ctx, true);
    try std.testing.expectEqual(@as(u32, 0), r.mk.seenCoun("DELETE "));
    try std.testing.expectEqual(@as(u32, 0), r.mk.deletes);
}

test "wrong vault passphrase stops the preflight without touching the vault file" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    _ = try r.run();
    const before = try r.fileText("cronjoborg-vault.json");
    try r.env.put(CF.passEnvz, "another-passphrase");
    const rep = try r.again();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("pref-chec", rep.stop_at.?);
    try std.testing.expectEqualStrings(before, try r.fileText("cronjoborg-vault.json"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
