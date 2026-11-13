// =====================================================================
// Des: Contract tests of the Cloudflare client and full-flow tests of the setup against the pretend Cloudflare: first run, second run (nothing changes), wrong token, drift, secret change, sync, revoke, slow route, rate limit, tick reaches the Trigger.
// Flo: start mock > build a temp home + config > run the real commands > read back the mock and the files
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (tests)
// Out: pass or fail
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");
const mock = @import("te-mock.zig");
const vaul = @import("pv-vault.zig");
const inpu = @import("co-input.zig");
const http = @import("co-http.zig");
const audi = @import("co-audit.zig");
const steps = @import("co-steps.zig");
const cfla = @import("ap-cflare.zig");
const ctxz = @import("co-ctx.zig");
const acct = @import("ve-account.zig");
const work = @import("ve-worker.zig");
const wire = @import("ve-wire.zig");
const cmdz = @import("cm-run.zig");

const CF = .{ .pass = "test passphrase 1234", .secr = "TICKSECRET-fake-0001", .secr2 = "TICKSECRET-fake-0002", .cron = "*/5 * * * *", .scri = "cloud-house-tick" };

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
        text = try std.mem.replaceOwned(u8, gpa, text, "https://api.cloudflare.com/client/v4", try self.mock.base(gpa, "/client/v4"));
        text = try std.mem.replaceOwned(u8, gpa, text, "https://{scri}.{subd}.workers.dev", try self.mock.base(gpa, "/w/{scri}"));
        text = try std.mem.replaceOwned(u8, gpa, text, "\"url\": \"\"", try std.fmt.allocPrint(gpa, "\"url\": \"{s}\"", .{try self.mock.base(gpa, "")}));
        text = try std.mem.replaceOwned(u8, gpa, text, "\"time\": 3, \"memo\": 65536", "\"time\": 1, \"memo\": 64");
        text = try std.mem.replaceOwned(u8, gpa, text, "\"guid\": { \"open\": true, \"clip\": true, \"poll\": 5, \"wait\": 900 }", "\"guid\": { \"open\": false, \"clip\": false, \"poll\": 1, \"wait\": 30 }");
        text = try std.mem.replaceOwned(u8, gpa, text, "\"rout\": { \"wait\": 120, \"poll\": 5 }", "\"rout\": { \"wait\": 20, \"poll\": 1 }");
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

    // change the config text (one replace)
    fn edit(self: *Rig, from: []const u8, to: []const u8) !void {
        const gpa = self.aren.allocator();
        var text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, self.conf, gpa, .limited(1 << 20));
        try std.testing.expect(std.mem.indexOf(u8, text, from) != null);
        text = try std.mem.replaceOwned(u8, gpa, text, from, to);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = self.conf, .data = text });
    }

    // put values in the vault the way `secret` would
    fn seed(self: *Rig, key: []const u8, valu: []const u8) !void {
        const gpa = self.aren.allocator();
        try std.Io.Dir.cwd().createDirPath(std.testing.io, try self.path(""));
        var vl = try vaul.Vaul.open(gpa, std.testing.io, try self.path("cf-cron-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
        try vl.putz(key, valu);
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
        return self.execArg(cmd, go, "", queu);
    }

    fn execArg(self: *Rig, cmd: cmdz.Cmd, go: bool, arg: []const u8, queu: *inpu.Inpu) !u8 {
        return cmdz.exec(self.aren.allocator(), std.testing.io, &self.envz, cmd, .{ .go = go, .conf = self.conf, .arg = arg }, queu);
    }
};

fn typedFree(queu: *inpu.Inpu) void {
    for (queu.list.items) |line| std.heap.smp_allocator.free(line);
    queu.list.deinit(std.heap.smp_allocator);
}

fn bindText(mok: *mock.Mock, name: []const u8) []const u8 {
    for (mok.wrks.items[0].binds) |item| if (std.mem.eql(u8, item.name, name)) return item.text;
    return "";
}

test "dry-run changes nothing and never calls Cloudflare" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{});
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.run, false, &queu));
    try std.testing.expectEqual(@as(u32, 0), rig.mock.seen);
    try std.testing.expectEqual(@as(usize, 0), rig.mock.wrks.items.len);
}

test "run needs the Trigger url in config" {
    const rig = try Rig.star();
    defer rig.stop();
    try rig.edit(try std.fmt.allocPrint(rig.aren.allocator(), "\"url\": \"{s}\"", .{try rig.mock.base(rig.aren.allocator(), "")}), "\"url\": \"\"");
    var queu = try rig.typed(&.{});
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitUsag), try rig.exec(.run, false, &queu));
    var go = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&go);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitFail), try rig.exec(.run, true, &go));
    try std.testing.expectEqual(@as(usize, 0), rig.mock.wrks.items.len);
}

test "full flow: first run builds everything, a tick reaches the Trigger, second run changes nothing" {
    const rig = try Rig.star();
    defer rig.stop();
    const gpa = rig.aren.allocator();
    try rig.seed("trigger.tick_secret", CF.secr);
    var queu = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.run, true, &queu));

    const mok = rig.mock;
    try std.testing.expectEqual(@as(usize, 1), mok.wrks.items.len);
    try std.testing.expectEqualStrings(CF.scri, mok.wrks.items[0].name);
    try std.testing.expect(mok.wrks.items[0].route);
    try std.testing.expectEqual(@as(usize, 1), mok.wrks.items[0].crons.len);
    try std.testing.expectEqualStrings(CF.cron, mok.wrks.items[0].crons[0]);
    try std.testing.expect(std.mem.startsWith(u8, mok.subd, "ch-"));
    try std.testing.expectEqualStrings("/tick", bindText(mok, "TRIGGER_URL")[std.mem.lastIndexOfScalar(u8, bindText(mok, "TRIGGER_URL"), '/').?..]);
    try std.testing.expectEqual(@as(u32, 0), mok.bads);

    // what real cron does: call the Trigger with the secret header
    try std.testing.expect(try mok.fire(gpa, CF.scri));
    try std.testing.expectEqual(@as(usize, 1), mok.ticks.items.len);
    try std.testing.expectEqualStrings(CF.secr, mok.ticks.items[0].secret);

    // wiring file + no secret on disk in plain text
    const wirj = try rig.read("schedule-c.json");
    try std.testing.expect(std.mem.indexOf(u8, wirj, "\"slot\": \"C\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wirj, "/w/cloud-house-tick") != null);
    try std.testing.expect(std.mem.indexOf(u8, wirj, "\"ticks_per_day\": 288") != null);
    inline for (.{ "cf-cron-vault.json", "cf-cron-state.json", "cf-cron-audit.log", "schedule-c.json" }) |name| {
        const body = try rig.read(name);
        try std.testing.expect(std.mem.indexOf(u8, body, mock.toke) == null);
        try std.testing.expect(std.mem.indexOf(u8, body, CF.secr) == null);
    }

    // second run: nothing is uploaded, routed or scheduled again, no human needed
    const writes = mok.pushes + mok.schedPuts + mok.subPuts;
    try std.testing.expectEqual(@as(u32, 3), writes);
    var again = try rig.typed(&.{});
    defer typedFree(&again);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.run, true, &again));
    try std.testing.expectEqual(writes, mok.pushes + mok.schedPuts + mok.subPuts);
    try std.testing.expectEqual(@as(usize, 1), mok.wrks.items.len);

    // status, check, vault answer
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.status, false, &again));
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.check, false, &again));
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitOkay), try rig.exec(.vault, false, &again));
}

test "no tick secret in the vault: the Worker is uploaded without that binding" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &queu));
    try std.testing.expectEqualStrings("", bindText(rig.mock, "TICK_SECRET"));
    try std.testing.expectEqual(@as(usize, 3), rig.mock.wrks.items[0].binds.len);
    try std.testing.expect(try rig.mock.fire(rig.aren.allocator(), CF.scri));
    try std.testing.expectEqualStrings("", rig.mock.ticks.items[0].secret);
}

test "a refused token is dropped from the vault and the run fails clean" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{ "g", "cfut_WRONGTOKEN_0123456789abcdefghij" });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitFail), try rig.exec(.run, true, &queu));
    try std.testing.expectEqual(@as(usize, 0), rig.mock.wrks.items.len);
    const gpa = rig.aren.allocator();
    const back = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("cf-cron-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
    try std.testing.expect(back.getz("cloudflare.apitoken") == null);
}

test "a too short token is refused before any call" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{ "g", "short" });
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

test "an existing workers.dev name is reused, and lost local state does not duplicate anything" {
    const rig = try Rig.star();
    defer rig.stop();
    rig.mock.subd = "myname";
    var first = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    try std.testing.expectEqual(@as(u32, 0), rig.mock.subPuts);
    try std.testing.expectEqualStrings("myname", rig.mock.subd);
    // lose the local state (new machine), keep the vault
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try rig.path("cf-cron-state.json"), .data = "{\"vers\":1}" });
    var second = try rig.typed(&.{});
    defer typedFree(&second);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &second));
    try std.testing.expectEqual(@as(usize, 1), rig.mock.wrks.items.len);
    try std.testing.expectEqual(@as(u32, 1), rig.mock.schedPuts); // cron already right: not set twice
}

test "revoke turns the cron off and drops the token; dry-run does nothing" {
    const rig = try Rig.star();
    defer rig.stop();
    var first = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.revoke, false, &first));
    try std.testing.expectEqual(@as(usize, 1), rig.mock.wrks.items[0].crons.len);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.revoke, true, &first));
    try std.testing.expectEqual(@as(usize, 0), rig.mock.wrks.items[0].crons.len);
    try std.testing.expect(!try rig.mock.fire(rig.aren.allocator(), CF.scri));
    const gpa = rig.aren.allocator();
    const back = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("cf-cron-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
    try std.testing.expect(back.getz("cloudflare.apitoken") == null);
    // a later run asks for a token again and sets the cron again
    var again = try rig.typed(&.{mock.toke});
    defer typedFree(&again);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &again));
    try std.testing.expectEqual(@as(usize, 1), rig.mock.wrks.items[0].crons.len);
}

test "sync: a new period reaches the cron, the Worker is not uploaded again" {
    const rig = try Rig.star();
    defer rig.stop();
    var first = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    try rig.edit("\"peri\": 5", "\"peri\": 10");
    var again = try rig.typed(&.{});
    defer typedFree(&again);
    // plain run does not notice (marks are done); sync does
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &again));
    try std.testing.expectEqualStrings(CF.cron, rig.mock.wrks.items[0].crons[0]);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.sync, true, &again));
    try std.testing.expectEqualStrings("*/10 * * * *", rig.mock.wrks.items[0].crons[0]);
    try std.testing.expectEqual(@as(u32, 1), rig.mock.pushes);
    try std.testing.expect(std.mem.indexOf(u8, try rig.read("schedule-c.json"), "\"ticks_per_day\": 144") != null);
}

test "sync: a changed secret is re-uploaded; live cron drift is fixed" {
    const rig = try Rig.star();
    defer rig.stop();
    try rig.seed("trigger.tick_secret", CF.secr);
    var first = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&first);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &first));
    try rig.seed("trigger.tick_secret", CF.secr2);
    rig.mock.wrks.items[0].crons = &.{"*/30 * * * *"}; // someone edited it in the dashboard
    var again = try rig.typed(&.{});
    defer typedFree(&again);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.sync, true, &again));
    try std.testing.expectEqual(@as(u32, 2), rig.mock.pushes);
    try std.testing.expectEqualStrings(CF.cron, rig.mock.wrks.items[0].crons[0]);
    try std.testing.expect(try rig.mock.fire(rig.aren.allocator(), CF.scri));
    try std.testing.expectEqualStrings(CF.secr2, rig.mock.ticks.items[0].secret);
}

test "route: a slow start is measured, a dead one is skipped not failed" {
    const rig = try Rig.star();
    defer rig.stop();
    rig.mock.routeNeed = 2;
    var queu = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &queu));
    try std.testing.expect(rig.mock.pings >= 3);

    const rig2 = try Rig.star();
    defer rig2.stop();
    rig2.mock.routeNeed = 1000;
    try rig2.edit("\"rout\": { \"wait\": 20, \"poll\": 1 }", "\"rout\": { \"wait\": 2, \"poll\": 1 }");
    var queu2 = try rig2.typed(&.{ "g", mock.toke });
    defer typedFree(&queu2);
    try std.testing.expectEqual(@as(u8, 0), try rig2.exec(.run, true, &queu2));
    try std.testing.expectEqual(@as(u8, 1), try rig2.exec(.check, false, &queu2));
}

test "rate limit: 429 is retried and the flow still ends" {
    const rig = try Rig.star();
    defer rig.stop();
    rig.mock.rateLimi = 2;
    var queu = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &queu));
    try std.testing.expectEqual(@as(usize, 1), rig.mock.wrks.items[0].crons.len);
}

test "two accounts: cfla.acco picks one, empty picks the first" {
    const rig = try Rig.star();
    defer rig.stop();
    rig.mock.accMany = true;
    try rig.edit("\"acco\": \"\"", "\"acco\": \"" ++ mock.acco ++ "\"");
    var queu = try rig.typed(&.{ "g", mock.toke });
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, 0), try rig.exec(.run, true, &queu));
    try std.testing.expectEqual(@as(usize, 1), rig.mock.wrks.items.len);
}

test "secret command vaults one hidden value and prints nothing secret" {
    const rig = try Rig.star();
    defer rig.stop();
    var queu = try rig.typed(&.{CF.secr});
    defer typedFree(&queu);
    try std.testing.expectEqual(@as(u8, cmdz.CF.exitUsag), try rig.execArg(.secret, true, "", &queu));
    try std.testing.expectEqual(@as(u8, 0), try rig.execArg(.secret, true, "trigger.tick_secret", &queu));
    const gpa = rig.aren.allocator();
    const back = try vaul.Vaul.open(gpa, std.testing.io, try rig.path("cf-cron-vault.json"), CF.pass, .{ .time = 1, .memo = 64, .para = 1 });
    try std.testing.expectEqualStrings(CF.secr, back.getz("trigger.tick_secret").?);
    try std.testing.expect(std.mem.indexOf(u8, try rig.read("cf-cron-vault.json"), CF.secr) == null);
}

test "contract: every client call matches the strict mock" {
    const rig = try Rig.star();
    defer rig.stop();
    const gpa = rig.aren.allocator();
    var logz = audi.Audi{ .io = std.testing.io, .path = try rig.path("contract.log") };
    try std.Io.Dir.cwd().createDirPath(std.testing.io, try rig.path(""));
    var http1 = http.Http.init(gpa, std.testing.io, &logz, .{ .trys = 2, .back = 1, .maxw = 2, .agen = "test", .maxb = 1 << 20 });
    defer http1.deinit();
    var cl = cfla.Cfla{ .gpa = gpa, .http = &http1, .apiz = try rig.mock.base(gpa, "/client/v4"), .toke = "cfut_BAD" };
    try std.testing.expectError(error.CflaAuth, cl.account(""));
    cl.toke = mock.toke;
    const acc = try cl.account("");
    try std.testing.expectEqualStrings(mock.acco, acc.id);
    try std.testing.expectError(error.CflaAcco, cl.account("nope"));
    try std.testing.expect((try cl.subGet(acc.id)) == null);
    try std.testing.expectError(error.CflaBad, cl.subSet(acc.id, "BAD NAME"));
    try cl.subSet(acc.id, "abc-123");
    try std.testing.expectEqualStrings("abc-123", (try cl.subGet(acc.id)).?);
    try std.testing.expect(!try cl.exists(acc.id, "w1"));
    // route and schedule need the Worker first
    try std.testing.expectError(error.CflaMiss, cl.route(acc.id, "w1"));
    try cl.push(acc.id, "w1", "2025-01-01", "export default { async scheduled() {} };", &.{.{ .name = "A", .text = "1", .secret = false }});
    try std.testing.expectError(error.CflaBad, cl.push(acc.id, "w1", "2025-01-01", "export default {};", &.{}));
    try std.testing.expect(try cl.exists(acc.id, "w1"));
    try std.testing.expect(try cl.route(acc.id, "w1"));
    try cl.sched(acc.id, "w1", &.{"*/7 * * * *"});
    try std.testing.expectError(error.CflaBad, cl.sched(acc.id, "w1", &.{"every minute"}));
    const live = try cl.schedGet(acc.id, "w1");
    try std.testing.expectEqual(@as(usize, 1), live.len);
    try std.testing.expectEqualStrings("*/7 * * * *", live[0]);
    try cl.sched(acc.id, "w1", &.{});
    try std.testing.expectEqual(@as(usize, 0), (try cl.schedGet(acc.id, "w1")).len);
    try std.testing.expectEqual(@as(u32, 0), rig.mock.bads - 4); // 4 intended refusals: 401 + three 400
}

test "the step list in 10-steps.json matches the rows in code" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    const file = try steps.load(gpa);
    var ctx: ctxz.Ctx = undefined;
    var rows: std.ArrayList(@import("co-engine.zig").Row) = .empty;
    try rows.appendSlice(gpa, &acct.rows(&ctx));
    try rows.appendSlice(gpa, &work.rows(&ctx));
    try rows.appendSlice(gpa, &wire.rows(&ctx));
    try std.testing.expectEqual(file.step.len - 1, rows.items.len); // tool-chec is done by exec
    for (rows.items, file.step[1..]) |row, def| {
        try std.testing.expectEqualStrings(def.iden, row.iden);
        try std.testing.expectEqual(def.hand > 0, row.hand);
    }
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
