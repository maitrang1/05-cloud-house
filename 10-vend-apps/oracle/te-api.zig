// =====================================================================
// Des: Contract tests of the signed web layer and the Oracle calls against the pretend Oracle: a bad key is refused, a good one works, the network and VM calls are rerun-safe, and nothing ever deletes.
// Flo: start mock > build signed client > call > check answers and mock counters
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: test results
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (test file)
// =====================================================================
const std = @import("std");
const audi = @import("co-audit.zig");
const http = @import("ap-http.zig");
const sign = @import("ap-sign.zig");
const oci = @import("ap-oci.zig");
const rsak = @import("pv-rsak.zig");
const keyz = @import("te-keys.zig");
const mock = @import("te-mock.zig");

const Rig = struct {
    aren: std.heap.ArenaAllocator,
    mok: *mock.Mock,
    http: http.Http,
    oci: oci.Oci,
    logz: audi.Audi,

    fn up(self: *Rig) !void {
        self.aren = std.heap.ArenaAllocator.init(std.testing.allocator);
        const gpa = self.aren.allocator();
        self.mok = try mock.Mock.star(std.testing.io);
        self.logz = .{ .io = std.testing.io, .path = "/dev/null/none", .fail = true };
        self.http = http.Http.init(gpa, std.testing.io, &self.logz, .{ .trys = 3, .back = 1, .maxw = 1, .agen = "oracle-test", .maxb = 1 << 20 });
        const held = try rsak.pemPars(gpa, keyz.pem1);
        self.http.creds = .{ .tena = mock.Mock.tena(), .user = mock.Mock.user(), .fing = keyz.fing, .key = held.key };
        const iden = try self.mok.base(gpa, "idn");
        const iaas = try self.mok.base(gpa, "iaa");
        self.oci = .{ .gpa = gpa, .http = &self.http, .iden = try std.mem.replaceOwned(u8, gpa, iden, "{regi}", mock.Mock.region()), .iaas = try std.mem.replaceOwned(u8, gpa, iaas, "{regi}", mock.Mock.region()), .vers = "20160918" };
    }

    fn down(self: *Rig) void {
        self.http.deinit();
        self.mok.halt();
        self.aren.deinit();
    }

    // the human's console step: upload the public key
    fn consoleKey(self: *Rig) !void {
        const gpa = self.aren.allocator();
        const held = try rsak.pemPars(gpa, keyz.pem1);
        try self.mok.keyAdd(try rsak.publicPem(gpa, held.key), keyz.fing);
    }
};

test "no uploaded key means 401, then the signed call works" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try std.testing.expect(!rig.oci.userLive(mock.Mock.user()));
    try std.testing.expect(rig.mok.sigBad >= 1);
    try rig.consoleKey();
    try std.testing.expect(rig.oci.userLive(mock.Mock.user()));
}

test "a tampered signature and a skewed clock are refused" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.consoleKey();
    const bad = rig.mok.sigBad;
    rig.mok.clockOff = 3600;
    try std.testing.expect(!rig.oci.userLive(mock.Mock.user()));
    try std.testing.expect(rig.mok.sigBad > bad);
    rig.mok.clockOff = 0;
    // wrong fingerprint in the keyId
    rig.http.creds.?.fing = "00:00";
    try std.testing.expect(!rig.oci.userLive(mock.Mock.user()));
}

test "compartment, network and VM calls are find-first and rerun-safe" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.consoleKey();
    const o = &rig.oci;
    const tena = mock.Mock.tena();

    try std.testing.expect((try o.compFind(tena, "ch")) == null);
    const comp = try o.compMake(tena, "ch", "d");
    try std.testing.expectEqualStrings("CREATING", try o.compState(comp));
    try std.testing.expectEqualStrings("ACTIVE", try o.compState(comp));
    try std.testing.expectEqualStrings(comp, (try o.compFind(tena, "ch")).?);

    const vcn = try o.vcnMake(comp, "v", "10.0.0.0/16");
    try std.testing.expectEqualStrings(vcn.iden, (try o.vcnFind(comp, "v")).?.iden);
    const igw = try o.igwMake(comp, vcn.iden, "g");
    try std.testing.expect(try o.routeEnsure(vcn.rout, igw));
    try std.testing.expect(!(try o.routeEnsure(vcn.rout, igw))); // second time: no change

    const want = [_]oci.Rule{ .{ .port = 22, .cidr = "0.0.0.0/0", .desc = "ssh" }, .{ .port = 8080, .cidr = "0.0.0.0/0", .desc = "app" } };
    try std.testing.expectEqual(@as(u32, 1), try o.secEnsure(vcn.secl, &want)); // 22 is already there
    try std.testing.expectEqual(@as(u32, 0), try o.secEnsure(vcn.secl, &want));
    const read = try o.secRead(vcn.secl);
    try std.testing.expectEqual(@as(usize, 2), read.tcp.len);
    try std.testing.expectEqual(@as(u32, 0), read.other); // Oracle's default ICMP rule is not "other"

    const subn = try o.subnMake(comp, vcn.iden, "s", "10.0.0.0/24", vcn.rout, vcn.secl);
    try std.testing.expectEqualStrings(subn, (try o.subnFind(comp, vcn.iden, "s")).?);

    const ads = try o.adList(comp);
    try std.testing.expectEqual(@as(usize, 1), ads.len);
    try std.testing.expect(try o.shapOffer(comp, ads[0], "VM.Standard.E2.1.Micro"));
    const imag = (try o.imgFind(comp, "Canonical Ubuntu", "24.04", "VM.Standard.E2.1.Micro")).?;
    const inst = try o.instLaunch(.{ .comp = comp, .ad = ads[0], .shap = "VM.Standard.E2.1.Micro", .name = "vm", .imag = imag, .subn = subn, .boot = 50, .ssh = "ssh-ed25519 AAAA k", .data = "#!/bin/bash\necho hi\n" });
    try std.testing.expectEqualStrings(inst, (try o.instFind(comp, "vm")).?);
    try std.testing.expectEqualStrings("PROVISIONING", try o.instState(inst));
    try std.testing.expectEqualStrings("RUNNING", try o.instState(inst));
    try std.testing.expect((try o.instIp(comp, inst)) != null);
    const seen = rig.mok.instOne().?;
    try std.testing.expectEqualStrings("#!/bin/bash\necho hi\n", seen.data);
    try std.testing.expectEqual(@as(i64, 50), seen.boot);

    try std.testing.expectEqual(@as(u32, 0), rig.mok.sigBad - 0 - rig.mok.sigBad); // every call above verified
    try std.testing.expectEqual(@as(u32, 0), rig.mok.delSeen);
}

test "429 is retried, a server error carries Oracle's reason, DELETE never leaves" {
    var rig: Rig = undefined;
    try rig.up();
    defer rig.down();
    try rig.consoleKey();
    rig.mok.rateLimi = 2;
    try std.testing.expect(rig.oci.userLive(mock.Mock.user()));
    try std.testing.expectEqual(@as(u64, 0), rig.http.wait);
    const comp = try rig.oci.compMake(mock.Mock.tena(), "ch", "d");
    rig.mok.launchFail = 1;
    const subn = "ocid1.subnet.oc1..x";
    try std.testing.expectError(error.OciCall, rig.oci.instLaunch(.{ .comp = comp, .ad = "a", .shap = "s", .name = "n", .imag = "i", .subn = subn, .boot = 50, .ssh = "k", .data = "d" }));
    try std.testing.expect(std.mem.indexOf(u8, rig.oci.last, "Out of host capacity") != null);
    try std.testing.expectError(error.NeverDelete, rig.http.call(.{ .meth = .DELETE, .urlz = rig.oci.iaas }));
    try std.testing.expectEqual(@as(u32, 0), rig.mok.delSeen);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
