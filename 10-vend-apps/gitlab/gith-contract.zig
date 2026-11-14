// =====================================================================
// Des: Contract tests for the GitHub mirror side against the mock GitHub. Proves a secret is sealed to the real public key and decrypts correctly, plus variables and run status.
// Flo: start mock > point the adapter at it > seal + upload a secret > check the mock decrypted the real value > stop the mock
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (self-contained tests)
// Out: pass/fail
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");
const audi = @import("audit-log.zig");
const http = @import("http-call.zig");
const gith = @import("gith-adapter.zig");
const mock = @import("mock-server.zig");

const testOpts = http.Opts{ .trys = 3, .back = 1, .maxw = 2, .agen = "gitlab-test/1", .maxb = 1 << 20 };

const Rig = struct {
    aren: std.heap.ArenaAllocator,
    mock: *mock.Mock,
    logz: audi.Audi,
    http: http.Http,
    gith: gith.Gith,

    fn star(self: *Rig, io: std.Io) !void {
        self.aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        const gpa = self.aren.allocator();
        self.mock = try mock.Mock.star(io);
        self.logz = .{ .io = io, .path = "/dev/null/no-such-dir/audit.log", .fail = true };
        self.http = http.Http.init(gpa, io, &self.logz, testOpts);
        const apiz = try self.mock.base(gpa, "/gh");
        self.gith = .{ .gpa = gpa, .io = io, .http = &self.http, .apiz = apiz, .vers = "2022-11-28", .toke = mock.ghToke, .owne = "ghowner", .repo = "cloud-house" };
    }

    fn halt(self: *Rig) void {
        self.http.deinit();
        self.mock.halt();
        self.aren.deinit();
    }
};

test "secret is sealed with the real public key and decrypts to the real value" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    try std.testing.expect(!(try rig.gith.secrHave("GITLAB_MIRROR_TOKEN")));
    try rig.gith.secrPutz("GITLAB_MIRROR_TOKEN", "glpat-real-mirror-secret");
    try std.testing.expect(try rig.gith.secrHave("GITLAB_MIRROR_TOKEN"));
    try std.testing.expectEqualStrings("glpat-real-mirror-secret", rig.mock.secrGetz("GITLAB_MIRROR_TOKEN").?);
    // rotate: a second seal replaces the value, never appends
    try rig.gith.secrPutz("GITLAB_MIRROR_TOKEN", "glpat-rotated-secret");
    try std.testing.expectEqualStrings("glpat-rotated-secret", rig.mock.secrGetz("GITLAB_MIRROR_TOKEN").?);
}

test "wrong bearer token or missing api version is refused" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    rig.gith.toke = "bad-token";
    try std.testing.expectError(error.Unauthorized, rig.gith.secrHave("X"));
    rig.gith.toke = mock.ghToke;
    rig.gith.vers = "2020-01-01";
    try std.testing.expectError(error.ApiError, rig.gith.secrHave("X"));
}

test "kill switch variable: create once, read back, duplicate refused" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    try std.testing.expect((try rig.gith.varzGetz("MIRROR_ON")) == null);
    try rig.gith.varzMake("MIRROR_ON", "1");
    try std.testing.expectEqualStrings("1", (try rig.gith.varzGetz("MIRROR_ON")).?);
    try std.testing.expectError(error.Conflict, rig.gith.varzMake("MIRROR_ON", "0"));
}

test "mirror workflow run status: none yet, then green" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    rig.mock.runzDone = false;
    try std.testing.expect((try rig.gith.runzLast("mirror.yml")) == null);
    rig.mock.runzDone = true;
    const runz = (try rig.gith.runzLast("mirror.yml")).?;
    try std.testing.expectEqualStrings("completed", runz.status.?);
    try std.testing.expectEqualStrings("success", runz.conclusion.?);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
