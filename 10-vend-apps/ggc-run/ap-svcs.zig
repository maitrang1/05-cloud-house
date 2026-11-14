// =====================================================================
// Des: Talks to Service Usage: lists which APIs are on in the project and turns on the missing ones.
// Flo: list ENABLED services > diff against the wanted list > batchEnable the missing > wait for the operation
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, project id, wanted API names
// Out: list of missing names; APIs enabled
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");

pub const Erro = error{SvcsHttp};

const CF = .{ .svcMark = "/services/", .pageMax = 10 };

// wanted APIs that are not enabled yet
pub fn missing(g: *gcp.Gcp, base: []const u8, proj: []const u8, want: []const []const u8) ![]const []const u8 {
    var have: std.ArrayList([]const u8) = .empty;
    var token: []const u8 = "";
    var pages: u32 = 0;
    while (pages < CF.pageMax) : (pages += 1) {
        const tail = if (token.len == 0) "" else try std.fmt.allocPrint(g.a, "&pageToken={s}", .{token});
        const rep = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/services?filter=state%3AENABLED&pageSize=200{s}", .{ base, proj, tail }), null);
        if (!rep.okay()) return error.SvcsHttp;
        const arr = gcp.obj(rep.val, "services");
        if (arr == .array) for (arr.array.items) |item| {
            const name = gcp.str(gcp.obj(item, "name"));
            if (std.mem.indexOf(u8, name, CF.svcMark)) |at| try have.append(g.a, name[at + CF.svcMark.len ..]);
        };
        token = gcp.str(gcp.obj(rep.val, "nextPageToken"));
        if (token.len == 0) break;
    }
    var outp: std.ArrayList([]const u8) = .empty;
    for (want) |name| {
        var hit = false;
        for (have.items) |item| {
            if (std.mem.eql(u8, item, name)) hit = true;
        }
        if (!hit) try outp.append(g.a, name);
    }
    return outp.toOwnedSlice(g.a);
}

// turn the listed APIs on and wait
pub fn enable(g: *gcp.Gcp, base: []const u8, proj: []const u8, ids: []const []const u8) !void {
    const Body = struct { serviceIds: []const []const u8 };
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .serviceIds = ids }, .{});
    const rep = try g.call(.POST, try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/services:batchEnable", .{ base, proj }), body);
    if (!rep.okay()) return error.SvcsHttp;
    try g.lroOf(try std.fmt.allocPrint(g.a, "{s}/v1", .{base}), rep);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
