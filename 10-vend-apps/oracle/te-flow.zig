// =====================================================================
// Des: Full-flow tests: the real command runner against the pretend Oracle, with a temp home, a fake vault passphrase and typed answers for the three hand jobs. Covers dry-run, a full live run, rerun-safety, no-capacity then resume, the paid guard and drift.
// Flo: temp home + test config > preload typed lines > run commands > check exit codes, state, mock counters
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: test results
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (test file)
// =====================================================================
const std = @import("std");
const cmds = @import("cm-cmds.zig");
const line = @import("co-line.zig");
const stat = @import("co-state.zig");
const rsak = @import("pv-rsak.zig");
const keyz = @import("te-keys.zig");
const mock = @import("te-mock.zig");

// what the human types for the three hand jobs: g, region, then the console preview block
const handz = [_][]const u8{ "g", "mock-region-1", "[DEFAULT]", "user=ocid1.user.oc1..mockuser", "fingerprint=4a:04:cc:eb:79:70:d0:f9:84:ea:72:73:48:c3:b7:1e", "tenancy=ocid1.tenancy.oc1..mocktena", "region=mock-region-1" };

const Rig = struct {
    aren: std.heap.ArenaAllocator,
    tmpz: std.testing.TmpDir,
    mok: *mock.Mock,
    home: []const u8,
    confPath: []const u8,
    stepPath: []const u8,
    envz: std.process.Environ.Map,

    fn up(self: *Rig, tweak: []const [2][]const u8) !void {
        self.aren = std.heap.ArenaAllocator.init(std.testing.allocator);
        const gpa = self.aren.allocator();
        const io = std.testing.io;
        self.tmpz = std.testing.tmpDir(.{});
        var buff: [std.fs.max_path_bytes]u8 = undefined;
        const size = try self.tmpz.dir.realPath(io, &buff);
        const base = try gpa.dupe(u8, buff[0..size]);
        self.home = try std.fs.path.join(gpa, &.{ base, "home" });
        try std.Io.Dir.cwd().createDirPath(io, self.home);
        self.mok = try mock.Mock.star(io);

        // the throwaway key as a file, the config pointed at the mock
        const keyf = try std.fs.path.join(gpa, &.{ base, "test-key.pem" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = keyf, .data = keyz.pem1 });
        var text = try std.Io.Dir.cwd().readFileAlloc(io, "00-config.json", gpa, .limited(1 << 20));
        const iden = try self.mok.base(gpa, "idn");
        const iaas = try self.mok.base(gpa, "iaa");
        const subs = [_][2][]const u8{
            .{ "https://identity.{regi}.oraclecloud.com", iden },
            .{ "https://iaas.{regi}.oraclecloud.com", iaas },
            .{ "\"guid\": { \"open\": true, \"clip\": true, \"poll\": 5, \"wait\": 900 }", "\"guid\": { \"open\": false, \"clip\": false, \"poll\": 1, \"wait\": 6 }" },
            .{ "\"wait\": 600, \"poll\": 10", "\"wait\": 6, \"poll\": 1" },
            .{ "\"time\": 3, \"memo\": 65536, \"para\": 1", "\"time\": 1, \"memo\": 64, \"para\": 1" },
            .{ "\"file\": \"\", \"tool\": \"openssl\"", try std.fmt.allocPrint(gpa, "\"file\": \"{s}\", \"tool\": \"openssl\"", .{keyf}) },
        };
        for (subs) |item| text = try std.mem.replaceOwned(u8, gpa, text, item[0], item[1]);
        for (tweak) |item| text = try std.mem.replaceOwned(u8, gpa, text, item[0], item[1]);
        self.confPath = try std.fs.path.join(gpa, &.{ base, "conf.json" });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.confPath, .data = text });
        self.stepPath = try std.fs.path.join(gpa, &.{ base, "steps.json" });
        const steps = try std.Io.Dir.cwd().readFileAlloc(io, "10-steps.json", gpa, .limited(1 << 20));
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.stepPath, .data = steps });

        self.envz = std.process.Environ.Map.init(gpa);
        try self.envz.put("HOME", self.home);
        try self.envz.put("PATH", "/usr/bin:/bin:/usr/local/bin");
        try self.envz.put("CLOUD_HOUSE_VAULT_PASS", "test pass phrase");
    }

    fn down(self: *Rig) void {
        self.mok.halt();
        self.tmpz.cleanup();
        self.aren.deinit();
    }

    // the human adds the public key in the console
    fn consoleKey(self: *Rig) !void {
        const gpa = self.aren.allocator();
        const held = try rsak.pemPars(gpa, keyz.pem1);
        try self.mok.keyAdd(try rsak.publicPem(gpa, held.key), keyz.fing);
    }

    // run one command with typed lines (smp_allocator owns them, as the reader thread would)
    fn go(self: *Rig, cmd: cmds.Cmd, live: bool, paid: bool, typed: []const []const u8) !u8 {
        const gpa = self.aren.allocator();
        var inpu = line.Inpu{ .io = std.testing.io };
        defer inpu.list.deinit(std.heap.smp_allocator);
        for (typed) |item| try inpu.list.append(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, item));
        defer for (inpu.list.items) |item| std.heap.smp_allocator.free(item);
        return cmds.execute(gpa, std.testing.io, &self.envz, .{ .cmd = cmd, .live = live, .paid = paid, .confPath = self.confPath, .stepPath = self.stepPath }, &inpu);
    }

    fn hands(self: *Rig) []const []const u8 {
        _ = self;
        return &handz;
    }

    fn loadState(self: *Rig) !stat.Stat {
        const gpa = self.aren.allocator();
        return stat.Stat.load(gpa, std.testing.io, try std.fs.path.join(gpa, &.{ self.home, ".05-cloud-house-secre", "oracle-state.json" }));
    }
};

test "dry-run and plan touch nothing" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, false, false, &.{}));
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.plan, false, false, &.{}));
    try std.testing.expectEqual(@as(u32, 0), rig.mok.seen);
    const root = try std.fs.path.join(rig.aren.allocator(), &.{ rig.home, ".05-cloud-house-secre" });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, root, .{}));
}

test "full live run, then a rerun that changes nothing" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, rig.hands()));
    const st = try rig.loadState();
    for (st.data.step) |item| try std.testing.expect(item.mark != .todo);
    try std.testing.expectEqual(@as(usize, 12), st.data.step.len);
    try std.testing.expect(st.markGetz("keep-aliv") == .skip);
    try std.testing.expectEqualStrings("203.0.113.", st.data.idsz.pubi[0..10]);
    try std.testing.expectEqual(@as(u32, 1), rig.mok.launches);
    try std.testing.expectEqual(@as(u32, 0), rig.mok.sigBad);
    try std.testing.expectEqual(@as(u32, 0), rig.mok.delSeen);

    // what the VM was given
    const vm = rig.mok.instOne().?;
    try std.testing.expect(std.mem.startsWith(u8, vm.ssh, "ssh-ed25519 "));
    try std.testing.expect(std.mem.indexOf(u8, vm.data, "useradd --system") != null);
    try std.testing.expect(std.mem.indexOf(u8, vm.data, "--dport 8080") != null);
    try std.testing.expectEqual(@as(i64, 50), vm.boot);

    // the backup holds ids and config, never a key
    const gpa = rig.aren.allocator();
    const dirz = try std.fs.path.join(gpa, &.{ rig.home, ".05-cloud-house-secre", "oracle-backup" });
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dirz, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iter = dir.iterate();
    const ent = (try iter.next(std.testing.io)).?;
    const back = try dir.readFileAlloc(std.testing.io, ent.name, gpa, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, back, "ocid1.compartment") != null);
    try std.testing.expect(std.mem.indexOf(u8, back, "PRIVATE") == null);
    try std.testing.expect(std.mem.indexOf(u8, back, "test-key.pem") != null); // a path, not the key

    // the vault holds the secrets, the state file and the audit log do not
    const root = try std.fs.path.join(gpa, &.{ rig.home, ".05-cloud-house-secre" });
    inline for (.{ "oracle-state.json", "oracle-audit.log", "oracle-vault.json" }) |name| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(gpa, &.{ root, name }), gpa, .limited(1 << 22));
        try std.testing.expect(std.mem.indexOf(u8, text, "MIIEow") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "BEGIN") == null);
    }

    // rerun: no typed input, no new calls that create things
    const before = rig.mok.launches;
    const posts = rig.mok.seenCoun("POST");
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, &.{}));
    try std.testing.expectEqual(before, rig.mok.launches);
    try std.testing.expectEqual(posts, rig.mok.seenCoun("POST"));
}

test "a fresh machine finds what exists and creates nothing twice" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, rig.hands()));
    const posts = rig.mok.seenCoun("POST");
    // wipe the local state by pointing HOME elsewhere; Oracle still has everything
    const gpa = rig.aren.allocator();
    const home2 = try std.fs.path.join(gpa, &.{ rig.home, "second" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, home2);
    try rig.envz.put("HOME", home2);
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, rig.hands()));
    try std.testing.expectEqual(posts, rig.mok.seenCoun("POST"));
    try std.testing.expectEqual(@as(u32, 1), rig.mok.launches);
}

test "no capacity stops cleanly and the rerun resumes at the VM" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    rig.mok.launchFail = 2; // primary and fallback shape both sold out
    try std.testing.expectEqual(@as(u8, 1), try rig.go(.run, true, false, rig.hands()));
    var st = try rig.loadState();
    try std.testing.expect(st.markGetz("netw-make") == .done);
    try std.testing.expect(st.markGetz("inst-make") == .todo);
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, &.{}));
    st = try rig.loadState();
    try std.testing.expect(st.markGetz("inst-make") == .done);
    try std.testing.expectEqual(@as(u32, 3), rig.mok.launches);
}

test "Arm sold out: the fallback shape launches in the same run" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    rig.mok.launchFail = 1;
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, rig.hands()));
    try std.testing.expectEqual(@as(u32, 2), rig.mok.launches);
    try std.testing.expectEqualStrings("VM.Standard.E2.1.Micro", rig.mok.instOne().?.shap);
}

test "a paid shape needs paid.okay in config and --paid on the command line" {
    var rig: Rig = undefined;
    try rig.up(&.{
        .{ "\"shap\": \"VM.Standard.A1.Flex\", \"free\"", "\"shap\": \"VM.Standard.E4.Flex\", \"free\"" },
        .{ "\"paid\": { \"okay\": false, \"cap\": 0 }", "\"paid\": { \"okay\": true, \"cap\": 5 }" },
    });
    defer rig.down();
    try rig.consoleKey();
    try std.testing.expectEqual(@as(u8, 1), try rig.go(.run, true, false, rig.hands()));
    try std.testing.expectEqual(@as(u32, 0), rig.mok.launches);
}

test "drift finds a foreign firewall rule and exits 3; the app removes nothing" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, rig.hands()));
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.drift, true, false, &.{}));
    rig.mok.extraRule = true;
    try std.testing.expectEqual(@as(u8, 3), try rig.go(.drift, true, false, &.{}));
    try std.testing.expectEqual(@as(u32, 0), rig.mok.delSeen);
}

test "wrong key fingerprint pasted is rejected, a bad config exits 2" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    // sign-card g, region, then a preview whose fingerprint is not ours, then x to stop
    const typed = [_][]const u8{ "g", mock.Mock.region(), "user=ocid1.user.oc1..mockuser", "fingerprint=aa:bb", "x" };
    try std.testing.expectEqual(@as(u8, 4), try rig.go(.run, true, false, &typed));
    const st = try rig.loadState();
    try std.testing.expect(st.markGetz("cons-keyz") == .todo);
    rig.confPath = "/nonexistent/conf.json";
    try std.testing.expectEqual(@as(u8, 2), try rig.go(.plan, false, false, &.{}));
}

test "a wrong fingerprint pasted before the ids is still caught" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    const typed = [_][]const u8{ "g", mock.Mock.region(), "fingerprint=aa:bb", "user=ocid1.user.oc1..mockuser", "tenancy=ocid1.tenancy.oc1..mocktena", "x" };
    try std.testing.expectEqual(@as(u8, 4), try rig.go(.run, true, false, &typed));
    const st = try rig.loadState();
    try std.testing.expect(st.markGetz("cons-keyz") == .todo);
    try std.testing.expectEqual(@as(u32, 0), rig.mok.launches);
}

test "revoke drops both vault keys and sshkey refuses to overwrite" {
    var rig: Rig = undefined;
    try rig.up(&.{});
    defer rig.down();
    try rig.consoleKey();
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.run, true, false, rig.hands()));
    const gpa = rig.aren.allocator();
    const outf = try std.fs.path.join(gpa, &.{ rig.home, "vm-login-key" });
    var inpu = line.Inpu{ .io = std.testing.io };
    const opts = cmds.Opts{ .cmd = .sshkey, .live = true, .confPath = rig.confPath, .stepPath = rig.stepPath, .arg = outf };
    try std.testing.expectEqual(@as(u8, 0), try cmds.execute(gpa, std.testing.io, &rig.envz, opts, &inpu));
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, outf, gpa, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, text, "OPENSSH") != null);
    try std.testing.expectEqual(@as(u8, 1), try cmds.execute(gpa, std.testing.io, &rig.envz, opts, &inpu)); // exists now
    try std.testing.expectEqual(@as(u8, 0), try rig.go(.revoke, true, false, &.{}));
    try std.testing.expectEqual(@as(u8, 1), try cmds.execute(gpa, std.testing.io, &rig.envz, opts, &inpu)); // key gone from the vault
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
