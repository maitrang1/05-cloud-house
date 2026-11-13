// =====================================================================
// Des: Talks to IAM: makes the small runtime service account the Cloud Run service will use. No key is ever made.
// Flo: GET account (404 = missing) > POST create
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, project id, account id, display name
// Out: service account e-mail
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");

pub const Erro = error{IamHttp};

// make the account when missing; returns its e-mail
pub fn saEnsure(g: *gcp.Gcp, base: []const u8, proj: []const u8, accid: []const u8, disp: []const u8) ![]const u8 {
    const mail = try std.fmt.allocPrint(g.a, "{s}@{s}.iam.gserviceaccount.com", .{ accid, proj });
    const got = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/serviceAccounts/{s}", .{ base, proj, mail }), null);
    if (got.okay()) return mail;
    if (got.code != 404) return error.IamHttp;
    const Body = struct { accountId: []const u8, serviceAccount: struct { displayName: []const u8 } };
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .accountId = accid, .serviceAccount = .{ .displayName = disp } }, .{});
    const rep = try g.call(.POST, try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/serviceAccounts", .{ base, proj }), body);
    if (!rep.okay()) return error.IamHttp;
    return mail;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
