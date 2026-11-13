// =====================================================================
// Des: Contract tests for the GitLab adapter against the mock GitLab. Proves device login, user lookup, ssh keys, project create, protect branch, and project access tokens all work end to end.
// Flo: start mock > point the adapter at it > run the real flow > check the mock's state > stop the mock
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none (self-contained tests)
// Out: pass/fail
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (test-only library file)
// =====================================================================
const std = @import("std");
const audi = @import("audit-log.zig");
const http = @import("http-call.zig");
const gitl = @import("gitl-adapter.zig");
const mock = @import("mock-server.zig");

const testOpts = http.Opts{ .trys = 3, .back = 1, .maxw = 2, .agen = "gitlab-test/1", .maxb = 1 << 20 };

// one wired-up adapter + mock pair for a test; init in place so no field address dangles
const Rig = struct {
    aren: std.heap.ArenaAllocator,
    mock: *mock.Mock,
    logz: audi.Audi,
    http: http.Http,
    gitl: gitl.Gitl,

    fn star(self: *Rig, io: std.Io) !void {
        self.aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        const gpa = self.aren.allocator();
        self.mock = try mock.Mock.star(io);
        self.logz = .{ .io = io, .path = "/dev/null/no-such-dir/audit.log", .fail = true };
        self.http = http.Http.init(gpa, io, &self.logz, testOpts);
        const apiz = try self.mock.base(gpa, "/api/v4");
        const oaut = try self.mock.base(gpa, "/oauth");
        self.gitl = .{ .gpa = gpa, .http = &self.http, .apiz = apiz, .oaut = oaut };
    }

    fn halt(self: *Rig) void {
        self.http.deinit();
        self.mock.halt();
        self.aren.deinit();
    }
};

test "public user lookup finds nobody, then the signed-up user" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    try std.testing.expect((try rig.gitl.userFind("ann")) == null);
    rig.mock.sign("ann");
    const user = (try rig.gitl.userFind("ann")).?;
    try std.testing.expectEqualStrings("ann", user.username);
    try std.testing.expect((try rig.gitl.userFind("Ann")) != null); // GitLab usernames are case-insensitive
}

test "device login: pending then slow_down then success, token works" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    rig.mock.sign("ann");
    rig.mock.pollNeed = 2;
    rig.mock.slowOnce = true;

    const devi = try rig.gitl.deviStar(mock.clid, "api");
    try std.testing.expectEqualStrings("ABCD-1234", devi.user_code);

    try std.testing.expectEqual(gitl.Poll.slow, try rig.gitl.deviPoll(mock.clid, devi.device_code));
    try std.testing.expectEqual(gitl.Poll.pend, try rig.gitl.deviPoll(mock.clid, devi.device_code));
    const poll = try rig.gitl.deviPoll(mock.clid, devi.device_code);
    try std.testing.expect(poll == .okay);
    rig.gitl.toke = poll.okay.access_token;

    const self = try rig.gitl.userSelf();
    try std.testing.expectEqualStrings("ann", self.username);

    // the old access token is burned once refreshed; the refresh token works once
    const fres = try rig.gitl.tokeRefr(mock.clid, poll.okay.refresh_token.?);
    rig.gitl.toke = fres.access_token;
    try std.testing.expect((try rig.gitl.userSelf()).id > 0);
    try std.testing.expectError(error.Unauthorized, blk: {
        rig.gitl.toke = "stale-token";
        break :blk rig.gitl.userSelf();
    });
}

test "device login denied when nobody signed up" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    const devi = try rig.gitl.deviStar(mock.clid, "api");
    try std.testing.expectEqual(gitl.Poll.deny, try rig.gitl.deviPoll(mock.clid, devi.device_code));
}

test "ssh key add, duplicate refused, delete" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    rig.mock.sign("ann");
    rig.gitl.toke = try tokeGetz(&rig);

    const iden = try rig.gitl.keysAddz("cloud-house", "ssh-ed25519 AAAATESTKEY ann@host");
    try std.testing.expect(iden > 0);
    try std.testing.expectError(error.ApiError, rig.gitl.keysAddz("dupe", "ssh-ed25519 AAAATESTKEY ann@host"));
    const list = try rig.gitl.keysList();
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try rig.gitl.keysDele(iden);
    try std.testing.expectEqual(@as(usize, 0), (try rig.gitl.keysList()).len);
    try std.testing.expectError(error.NotFound, rig.gitl.keysDele(iden));
}

test "project create, settings edit, protect main, access token lifecycle" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    rig.mock.sign("ann");
    rig.gitl.toke = try tokeGetz(&rig);

    try std.testing.expect((try rig.gitl.projFind("ann/cloud-house")) == null);
    const made = try rig.gitl.projMake("cloud-house", "private", "main");
    try std.testing.expectEqual(@as(i64, @intCast(mock.prid)), made.object.get("id").?.integer);
    try std.testing.expectError(error.ApiError, rig.gitl.projMake("cloud-house", "private", "main"));

    const sett = try std.json.parseFromSliceLeaky(std.json.Value, rig.gitl.gpa, "{\"shared_runners_enabled\":false,\"builds_access_level\":\"disabled\"}", .{});
    const edit = try rig.gitl.projEdit(mock.prid, sett);
    try std.testing.expect(!edit.object.get("shared_runners_enabled").?.bool);
    try std.testing.expectEqualStrings("disabled", edit.object.get("builds_access_level").?.string);

    try std.testing.expect((try rig.gitl.protFind(mock.prid, "main")) == null);
    const prot = try rig.gitl.protMake(mock.prid, "main", 30, 40, false);
    try std.testing.expectEqual(@as(u64, 30), gitl.leveFrst(prot.push_access_levels));
    try std.testing.expect(!prot.allow_force_push);
    try std.testing.expectError(error.Conflict, rig.gitl.protMake(mock.prid, "main", 30, 40, false));
    try std.testing.expect((try rig.gitl.protFind(mock.prid, "main")) != null);

    const atok = try rig.gitl.atokMake(mock.prid, "mirror", &.{"write_repository"}, 30, "2027-02-10");
    try std.testing.expect(atok.token != null);
    const seen = (try rig.gitl.atokFind(mock.prid, atok.id)).?;
    try std.testing.expect(seen.token == null); // the secret is never returned again
    try std.testing.expectEqual(@as(usize, 1), (try rig.gitl.atokList(mock.prid)).len);
    try rig.gitl.atokDele(mock.prid, atok.id);
    const afte = (try rig.gitl.atokFind(mock.prid, atok.id)).?; // GitLab keeps a revoked token's row, just inactive
    try std.testing.expect(afte.revoked and !afte.active);
    try std.testing.expectError(error.NotFound, rig.gitl.atokDele(mock.prid, atok.id));
}

test "429 is retried with Retry-After honored" {
    var rig: Rig = undefined;
    try rig.star(std.testing.io);
    defer rig.halt();
    rig.mock.sign("ann");
    rig.mock.rateLimi = 1;
    const user = (try rig.gitl.userFind("ann")).?;
    try std.testing.expectEqualStrings("ann", user.username);
    try std.testing.expect(rig.http.wait >= 1);
}

// device-login helper shared by the project/keys tests
fn tokeGetz(rig: *Rig) ![]const u8 {
    const devi = try rig.gitl.deviStar(mock.clid, "api");
    rig.mock.pollNeed = 0;
    const poll = try rig.gitl.deviPoll(mock.clid, devi.device_code);
    return poll.okay.access_token;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
