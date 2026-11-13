// =====================================================================
// Des: Talks to Artifact Registry: makes a pull-through (remote) Docker repo for a public registry such as ghcr.io, so Cloud Run can pull images from it with no stored credential.
// Flo: GET repo > if present check its upstream > else POST create > wait for the operation
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, project id, region, repo id, upstream url
// Out: repo exists with the wanted upstream
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");

pub const Erro = error{ ArtyHttp, UpstDiff };

// make the remote repo when missing; refuse when it points at another upstream (it cannot be changed)
pub fn repoEnsure(g: *gcp.Gcp, base: []const u8, proj: []const u8, regi: []const u8, repo: []const u8, upst: []const u8) !void {
    const urlz = try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/locations/{s}/repositories", .{ base, proj, regi });
    const got = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/{s}", .{ urlz, repo }), null);
    if (got.okay()) {
        const have = gcp.str(gcp.obj(gcp.obj(gcp.obj(gcp.obj(got.val, "remoteRepositoryConfig"), "dockerRepository"), "customRepository"), "uri"));
        if (!std.mem.eql(u8, have, upst)) return error.UpstDiff;
        return;
    }
    if (got.code != 404) return error.ArtyHttp;
    const Body = struct { format: []const u8, mode: []const u8, description: []const u8, remoteRepositoryConfig: struct { dockerRepository: struct { customRepository: struct { uri: []const u8 } } } };
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .format = "DOCKER", .mode = "REMOTE_REPOSITORY", .description = "pull-through cache for cloud-house", .remoteRepositoryConfig = .{ .dockerRepository = .{ .customRepository = .{ .uri = upst } } } }, .{});
    const rep = try g.call(.POST, try std.fmt.allocPrint(g.a, "{s}?repositoryId={s}", .{ urlz, repo }), body);
    if (!rep.okay()) return error.ArtyHttp;
    try g.lroOf(try std.fmt.allocPrint(g.a, "{s}/v1", .{base}), rep);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
