// =====================================================================
// Des: Talks to Cloud Resource Manager: finds a project, creates it, and reads the project number.
// Flo: GET project (403/404 = not there) > POST create > wait for the operation
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, project id, display name
// Out: Info{number, state} or null
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");

pub const Erro = error{ ProjHttp, IdTaken };

pub const Info = struct { number: []const u8, state: []const u8 };

// the project, or null when it does not exist (Google answers 403 or 404 for a missing id)
pub fn getz(g: *gcp.Gcp, base: []const u8, iden: []const u8) !?Info {
    const rep = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v3/projects/{s}", .{ base, iden }), null);
    if (rep.code == 403 or rep.code == 404) return null;
    if (!rep.okay()) return error.ProjHttp;
    const name = gcp.str(gcp.obj(rep.val, "name"));
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return error.ProjHttp;
    return .{ .number = name[slash + 1 ..], .state = gcp.str(gcp.obj(rep.val, "state")) };
}

// create the project and wait; error.IdTaken when the id is used by someone else
pub fn make(g: *gcp.Gcp, base: []const u8, iden: []const u8, name: []const u8) !void {
    const Body = struct { projectId: []const u8, displayName: []const u8 };
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .projectId = iden, .displayName = name }, .{});
    const rep = try g.call(.POST, try std.fmt.allocPrint(g.a, "{s}/v3/projects", .{base}), body);
    if (rep.code == 409) return error.IdTaken;
    if (!rep.okay()) return error.ProjHttp;
    try g.lroOf(try std.fmt.allocPrint(g.a, "{s}/v3", .{base}), rep);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
