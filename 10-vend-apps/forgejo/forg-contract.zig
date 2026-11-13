// =====================================================================
// Des: Contract tests for the Forgejo adapter against the pretend server: every call it makes, plus the error mapping and retry.
// Flo: start mock > call the adapter > check the typed answer and the mock's own state
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: test results
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (test-only file)
// =====================================================================
const std = @import("std");
const audi = @import("audit-log.zig");
const http = @import("http-call.zig");
const forg = @import("forg-adapter.zig");
const mock = @import("mock-server.zig");

const testOpts = http.Opts{ .trys = 3, .back = 1, .maxw = 2, .agen = "forgejo-test/1", .maxb = 1 << 20 };
const testToke = "mocktoken-test";

const Rig = struct {
    aren: std.heap.ArenaAllocator,
    mock1: *mock.Mock,
    logz: audi.Audi,
    http1: http.Http,
    forg1: forg.Forg,

    // wire a mock, an http client and an adapter; caller must call done
    fn init(self: *Rig) !void {
        self.aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        const gpa = self.aren.allocator();
        const io = std.testing.io;
        self.mock1 = try mock.Mock.star(io);
        self.logz = .{ .io = io, .path = "/dev/null/none", .fail = true };
        self.http1 = http.Http.init(gpa, io, &self.logz, testOpts);
        self.forg1 = .{ .gpa = gpa, .http = &self.http1, .apiz = try self.mock1.base(gpa, "/api/v1"), .toke = testToke };
    }

    fn done(self: *Rig) void {
        self.http1.deinit();
        self.mock1.halt();
        self.aren.deinit();
    }
};

fn boolOf(sett: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, std.heap.smp_allocator, sett, .{});
}

test "version needs no token and retries a 503" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    rig.mock1.downN = 1;
    rig.forg1.toke = "";
    const vers = try rig.forg1.versGetz();
    try std.testing.expect(std.mem.startsWith(u8, vers.version, "15."));
    try std.testing.expectEqual(@as(u32, 2), rig.mock1.seenCoun("GET /api/v1/version"));
}

test "no token or a wrong one is Unauthorized" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    rig.forg1.toke = "nope";
    try std.testing.expectError(error.Unauthorized, rig.forg1.userSelf());
    rig.forg1.toke = testToke;
    const me = try rig.forg1.userSelf();
    try std.testing.expectEqualStrings("ann", me.login);
}

test "ssh keys: add, list, bad key refused, duplicate refused" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    try std.testing.expectEqual(@as(usize, 0), (try rig.forg1.keysList()).len);
    const iden = try rig.forg1.keysAddz("cloud-house", "ssh-ed25519 AAAAC3Nz test");
    const list = try rig.forg1.keysList();
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(iden, list[0].id);
    try std.testing.expectError(error.Conflict, rig.forg1.keysAddz("x", "ssh-ed25519 AAAAC3Nz test"));
    try std.testing.expectError(error.Conflict, rig.forg1.keysAddz("x", "ssh-rsa AAAA"));
}

test "repo: missing, create private, edit settings off" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    try std.testing.expect((try rig.forg1.repoFind("ann", "cloud-house")) == null);
    const made = try rig.forg1.repoMake("cloud-house", true, "main");
    try std.testing.expect(made.private and made.id == 77);
    try std.testing.expectError(error.Conflict, rig.forg1.repoMake("cloud-house", true, "main"));
    const sett = try boolOf("{\"has_wiki\":false,\"has_issues\":false,\"has_pull_requests\":false,\"has_projects\":false,\"has_actions\":false}");
    const edit = try rig.forg1.repoEdit("ann", "cloud-house", sett);
    try std.testing.expect(!edit.has_wiki and !edit.has_issues and !edit.has_actions and !edit.has_pull_requests);
    try std.testing.expect(!rig.mock1.hasProjects);
    try std.testing.expect((try rig.forg1.repoFind("ann", "cloud-house")) != null);
    try std.testing.expect((try rig.forg1.repoFind("bob", "cloud-house")) == null);
    // never public: the mock refuses it, so a bad config could not slip through
    try std.testing.expectError(error.Conflict, rig.forg1.repoEdit("ann", "cloud-house", try boolOf("{\"private\":false}")));
}

test "branch protection: create once, no force push, head lookup" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    _ = try rig.forg1.repoMake("cloud-house", true, "main");
    try std.testing.expect((try rig.forg1.protFind("ann", "cloud-house", "main")) == null);
    const body = try boolOf("{\"enable_push\":true,\"enable_force_push\":false}");
    const prot = try rig.forg1.protMake("ann", "cloud-house", "main", body);
    try std.testing.expect(prot.enable_push and !prot.enable_force_push and std.mem.eql(u8, prot.branch_name, "main"));
    try std.testing.expect(rig.mock1.protHave and !rig.mock1.protForc);
    try std.testing.expectError(error.Forbidden, rig.forg1.protMake("ann", "cloud-house", "main", body));
    try std.testing.expect((try rig.forg1.protFind("ann", "cloud-house", "main")) != null);
    // an empty body still gets the branch name
    rig.mock1.protHave = false;
    _ = try rig.forg1.protMake("ann", "cloud-house", "main", try boolOf("{}"));
    try std.testing.expect(rig.mock1.protHave);

    try std.testing.expect((try rig.forg1.branHead("ann", "cloud-house", "main")) == null);
    rig.mock1.headId = "0123456789abcdef0123456789abcdef01234567";
    try std.testing.expectEqualStrings(rig.mock1.headId, (try rig.forg1.branHead("ann", "cloud-house", "main")).?);
}

test "token delete takes basic auth and is rerun-safe" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    try std.testing.expectError(error.Unauthorized, rig.forg1.tokeDele("ann", "cloud-house", "ann:"));
    try std.testing.expectError(error.Unauthorized, rig.forg1.tokeDele("ann", "cloud-house", "bob:pw"));
    try rig.forg1.tokeDele("ann", "cloud-house", "ann:pw123");
    try std.testing.expect(rig.mock1.tokeGone);
    try std.testing.expectEqualStrings("pw123", rig.mock1.basiPass);
    try rig.forg1.tokeDele("ann", "cloud-house", "ann:pw123"); // 404 on a repeat is fine
    rig.forg1.toke = testToke;
    try std.testing.expectError(error.Unauthorized, rig.forg1.userSelf()); // the token is dead
}

test "429 is retried then succeeds" {
    var rig: Rig = undefined;
    try rig.init();
    defer rig.done();
    rig.mock1.rateLimi = 1;
    const me = try rig.forg1.userSelf();
    try std.testing.expectEqualStrings("ann", me.login);
    try std.testing.expectEqual(@as(u32, 2), rig.mock1.seenCoun("GET /api/v1/user"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
