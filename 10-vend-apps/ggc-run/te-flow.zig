// =====================================================================
// Des: End-to-end flow tests: run every real step through the real engine against the pretend Google Cloud on a spare port. Proves the whole setup works together, is rerun-safe, patches drift, resumes after a hand job, and takes back only what it added.
// Flo: build a temp home + mock > wire a Boot to the mock urls > run the engine > assert the mock's final state and request log
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (self-contained; the gcloud test needs sh and skips on Windows)
// Out: pass/fail
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const conf = @import("co-cfg.zig");
const boot = @import("cm-boot.zig");
const engi = @import("co-engine.zig");
const tabl = @import("ve-table.zig");
const cinf = @import("cm-info.zig");
const crev = @import("cm-revo.zig");
const mock = @import("te-mock.zig");

const CF = .{ .projIden = "cloud-house-test01", .envName = "GGC_RUN_TOKEN" };

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

    fn init(self: *Rig, envMode: bool) !void {
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
        self.cfg.apis = .{ .crmz = try self.mk.base(a, "crm"), .bill = try self.mk.base(a, "bill"), .budg = try self.mk.base(a, "budg"), .usag = try self.mk.base(a, "usag"), .iamz = try self.mk.base(a, "iam"), .arti = try self.mk.base(a, "arti"), .runz = try self.mk.base(a, "run"), .moni = try self.mk.base(a, "moni") };
        self.cfg.goog.proj_iden = CF.projIden;
        self.cfg.http.back = 1;
        self.cfg.http.maxw = 1;
        self.cfg.http.lro_msec = 10;
        self.cfg.http.lro_secs = 5;
        self.cfg.guid.open = false;
        self.cfg.guid.clip = false;
        self.cfg.guid.poll = 1;
        self.cfg.guid.wait = 20;
        if (envMode) self.cfg.auth.mode = "env";
        self.env = std.process.Environ.Map.init(a);
        try self.env.put("PATH", "/usr/bin:/bin:/usr/local/bin");
        try self.env.put(CF.envName, mock.toke);
        try self.start();
    }

    // (re)build the Boot: reloads the state file from disk
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
        if (rep.code != 0) {
            std.debug.print("run stopped at {s} code {d}: {s}\n", .{ rep.stop_at orelse "-", rep.code, self.bt.ctx.lastFail });
        }
        return rep;
    }

    // forget the state file, as if the first run never happened
    fn stateDrop(self: *Rig) !void {
        const path = try std.fs.path.join(self.aren.allocator(), &.{ self.root, self.cfg.data.stat });
        try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
        try self.start();
    }
};

// write calls only (reads that use POST do not count)
fn mutations(mk: *mock.Mock) u32 {
    var coun: u32 = 0;
    for (mk.logz.items) |item| {
        if (std.mem.indexOf(u8, item, ":getIamPolicy") != null or std.mem.indexOf(u8, item, "/tick") != null) continue;
        if (std.mem.startsWith(u8, item, "POST ") or std.mem.startsWith(u8, item, "PUT ") or std.mem.startsWith(u8, item, "PATCH ") or std.mem.startsWith(u8, item, "DELETE ")) coun += 1;
    }
    return coun;
}

// true when a log line starts with the prefix and carries the quota header value
fn quotAll(mk: *mock.Mock, pref: []const u8, want: []const u8) bool {
    var seen = false;
    for (mk.logz.items) |item| if (std.mem.indexOf(u8, item, pref) != null) {
        seen = true;
        const tail = try_tail(item);
        if (!std.mem.eql(u8, tail, want)) return false;
    };
    return seen;
}

fn try_tail(item: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, item, " q=") orelse return "?";
    return item[at + 3 ..];
}

fn fileText(r: *Rig, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(r.aren.allocator(), &.{ r.root, name });
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, r.aren.allocator(), .limited(1 << 20));
}

test "full setup: every step, in order, billing appears mid-run" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.billAfter = 2;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 12), rep.done + rep.skipped);
    try std.testing.expectEqual(@as(u32, 1), r.bt.ctx.handled);
    try std.testing.expectEqual(@as(u32, 0), r.mk.bads);
    // project, billing, APIs
    try std.testing.expectEqual(@as(usize, 1), r.mk.projs.items.len);
    try std.testing.expect(r.mk.projs.items[0].bill);
    try std.testing.expect(r.mk.apiOn(CF.projIden, "run.googleapis.com"));
    // budget before the service, three alerts
    try std.testing.expectEqual(@as(usize, 1), r.mk.budgs.items.len);
    try std.testing.expectEqual(@as(usize, 3), r.mk.budgs.items[0].rules);
    var budgAt: usize = 0;
    var runAt: usize = 0;
    for (r.mk.logz.items, 0..) |item, indx| {
        if (std.mem.startsWith(u8, item, "POST /budg/") and budgAt == 0) budgAt = indx;
        if (std.mem.startsWith(u8, item, "POST /run/") and runAt == 0) runAt = indx;
    }
    try std.testing.expect(budgAt != 0 and runAt != 0 and budgAt < runAt);
    // service: scale to zero, one instance, CPU only in requests
    const svc = r.mk.svc.?;
    try std.testing.expectEqual(@as(i64, 0), svc.mini);
    try std.testing.expectEqual(@as(i64, 1), svc.maxi);
    try std.testing.expect(svc.idle);
    try std.testing.expect(svc.ready);
    // project policy: one new binding, unknown fields kept
    try std.testing.expect(std.mem.indexOf(u8, r.mk.projPol.text, "roles/logging.logWriter") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.mk.projPol.text, "cloud-job-run@") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.mk.projPol.text, "auditConfigs") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.mk.projPol.text, "roles/owner") != null);
    // public invoker
    try std.testing.expect(std.mem.indexOf(u8, r.mk.svcPol.text, "roles/run.invoker") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.mk.svcPol.text, "allUsers") != null);
    // quota header: none for the APIs step, the project for the Cloud Run calls
    try std.testing.expect(quotAll(r.mk, "/usag/v1/projects", ""));
    try std.testing.expect(quotAll(r.mk, "/run/v2/projects", CF.projIden));
    // handoff file has the tick url
    const hand = try fileText(&r, r.cfg.data.hand);
    try std.testing.expect(std.mem.indexOf(u8, hand, "/svc/cloud-job/tick") != null);
    // the audit log never holds the token
    const audit = try fileText(&r, r.cfg.data.audi);
    try std.testing.expect(std.mem.indexOf(u8, audit, "mock-token") == null and audit.len > 0);
    // state holds ids, no secret
    const state = try fileText(&r, r.cfg.data.stat);
    try std.testing.expect(std.mem.indexOf(u8, state, "mock-token") == null);
}

test "second run changes nothing, even with the state file gone" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    const first = try r.run();
    try std.testing.expectEqual(@as(u8, 0), first.code);
    const before = mutations(r.mk);
    const second = try r.run();
    try std.testing.expectEqual(@as(u8, 0), second.code);
    try std.testing.expectEqual(before, mutations(r.mk));
    try r.stateDrop();
    const third = try r.run();
    try std.testing.expectEqual(@as(u8, 0), third.code);
    try std.testing.expectEqual(before, mutations(r.mk));
    try std.testing.expectEqual(@as(u32, 1), r.mk.svc.?.gens);
}

test "drift in the config is patched once" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    r.cfg.serv.memo = "512Mi";
    try r.stateDrop();
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    try std.testing.expectEqual(@as(u32, 2), r.mk.svc.?.gens);
    try std.testing.expectEqualStrings("512Mi", r.mk.svc.?.mem);
    try std.testing.expectEqual(@as(u32, 1), r.mk.seenCoun("PATCH /run/"));
}

test "a pull-through repo makes the image path; a wrong upstream is refused" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.cfg.imag.sour = "maitrang1/cloud-job:latest";
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    try std.testing.expectEqual(@as(usize, 1), r.mk.repos.items.len);
    try std.testing.expectEqualStrings("https://ghcr.io", r.mk.repos.items[0].uri);
    try std.testing.expectEqualStrings("us-central1-docker.pkg.dev/cloud-house-test01/ghcr-remote/maitrang1/cloud-job:latest", r.mk.svc.?.image);
    r.cfg.imag.upst = "https://registry.example.com";
    try r.stateDrop();
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("imag-path", rep.stop_at.?);
}

test "org policy blocks public access: stops with a fix, resumes later" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.denyPubl = true;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("serv-depl", rep.stop_at.?);
    r.mk.denyPubl = false;
    try r.start();
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    try std.testing.expectEqual(@as(u32, 1), r.mk.svc.?.gens);
}

test "a 429 and a slow service-account role are retried" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.rateLimi = 1;
    r.mk.saDelay = 2;
    r.mk.lroPend = 3;
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    // the only 400s are the two the mock injected on purpose
    try std.testing.expectEqual(@as(u32, 2), r.mk.bads);
    try std.testing.expectEqual(@as(u32, 3), r.mk.seenCoun("POST /crm/v1/projects/cloud-house-test01:setIamPolicy"));
}

test "two billing accounts: the app will not guess; config picks one" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.billTwo = true;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("bill-link", rep.stop_at.?);
    r.cfg.budg.bill_acct = mock.bill;
    try r.start();
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
}

test "the service not Ready fails the deploy step" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.svcFail = true;
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("serv-depl", rep.stop_at.?);
}

test "tick probe: twice with one run id runs the job once" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.cfg.tick.prob = true;
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    try std.testing.expectEqual(@as(u32, 2), r.mk.seenCoun("POST /svc/"));
    try std.testing.expectEqual(@as(u32, 1), r.mk.tickRuns);
}

test "usage warns at the configured percent" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), cinf.usage(&r.bt.ctx));
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    r.mk.useReqs = 100;
    try std.testing.expectEqual(@as(u8, 0), cinf.usage(&r.bt.ctx));
    r.mk.useReqs = 1_700_000;
    try std.testing.expectEqual(@as(u8, 3), cinf.usage(&r.bt.ctx));
    r.mk.useReqs = 100;
    r.mk.useCpuz = 150000.5;
    try std.testing.expectEqual(@as(u8, 3), cinf.usage(&r.bt.ctx));
}

test "revoke removes only public access; dry-run changes nothing" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    const before = mutations(r.mk);
    try std.testing.expectEqual(@as(u8, 0), try crev.revoke(&r.bt.ctx, false));
    try std.testing.expectEqual(before, mutations(r.mk));
    try std.testing.expectEqual(@as(u8, 0), try crev.revoke(&r.bt.ctx, true));
    try std.testing.expect(std.mem.indexOf(u8, r.mk.svcPol.text, "allUsers") == null);
    try std.testing.expect(r.mk.svc != null);
    try std.testing.expect(std.mem.indexOf(u8, r.mk.projPol.text, "cloud-job-run@") != null);
    // a rerun puts the public binding back
    try r.start();
    try std.testing.expectEqual(@as(u8, 0), (try r.run()).code);
    try std.testing.expect(std.mem.indexOf(u8, r.mk.svcPol.text, "allUsers") != null);
}

test "a bad token is refused at the login step" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    try r.env.put(CF.envName, "ya29.wrong");
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 1), rep.code);
    try std.testing.expectEqualStrings("goog-logi", rep.stop_at.?);
}

test "gcloud mode: hand jobs 1 and 2 with a stub gcloud, resume after g" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var r: Rig = undefined;
    try r.init(false);
    defer r.deinit();
    const a = r.aren.allocator();
    const flag = try std.fs.path.join(a, &.{ r.root, "logged-in" });
    const stub = try std.fs.path.join(a, &.{ r.root, "gcloud-stub.sh" });
    const text = try std.fmt.allocPrint(a, "#!/bin/sh\ncase \"$1 $2\" in\n  \"auth list\") [ -f '{s}' ] && echo ann@example.com ;;\n  \"auth login\") : > '{s}' ;;\n  \"auth print-access-token\") echo {s} ;;\n  \"auth revoke\") rm -f '{s}' ;;\nesac\nexit 0\n", .{ flag, flag, mock.toke, flag });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, r.root);
    try cwd.writeFile(std.testing.io, .{ .sub_path = stub, .data = text, .flags = .{ .permissions = std.Io.File.Permissions.fromMode(0o700) } });
    r.cfg.tool.gclo = stub;
    try r.start();
    // the human types g at the Google account step
    try r.bt.line.list.append(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, "g"));
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 0), rep.code);
    try std.testing.expectEqual(@as(u32, 2), r.bt.ctx.handled);
    try std.testing.expectEqualStrings("app", r.bt.ctx.st.valu("logi_from"));
    // revoke logs out the account the app logged in
    try std.testing.expectEqual(@as(u8, 0), try crev.revoke(&r.bt.ctx, true));
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, flag, .{}));
}

test "the human can stop a guided step with x" {
    var r: Rig = undefined;
    try r.init(true);
    defer r.deinit();
    r.mk.billAfter = 1000;
    try r.bt.line.list.append(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, "x"));
    const rep = try r.run();
    try std.testing.expectEqual(@as(u8, 4), rep.code);
    try std.testing.expectEqualStrings("bill-link", rep.stop_at.?);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
