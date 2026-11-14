// =====================================================================
// Des: Adds or removes one member on one role of an IAM policy. Reads the policy, edits only that binding, keeps every other field and the etag, writes it back.
// Flo: get policy > find role binding > add or remove member > if nothing changed stop > set policy with the same etag
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: get request (method, url, body), set url, role, member
// Out: true when the policy changed
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");

pub const Erro = error{ PolGet, PolSet, PolShape };

// how to read the policy of one resource
pub const Where = struct { get_meth: std.http.Method, get_url: []const u8, get_body: ?[]const u8, set_url: []const u8 };

// the binding with this role inside the bindings array, or null
fn findRole(bind: *std.json.Array, role: []const u8) ?*std.json.Value {
    for (bind.items) |*item| {
        if (item.* != .object) continue;
        if (std.mem.eql(u8, gcp.str(gcp.obj(item.*, "role")), role)) return item;
    }
    return null;
}

// index of a member in a members array, or null
fn findMember(mems: *std.json.Array, member: []const u8) ?usize {
    for (mems.items, 0..) |item, indx| if (item == .string and std.mem.eql(u8, item.string, member)) return indx;
    return null;
}

// make the policy contain (add) or lack (not add) the member; true when it changed
pub fn edit(g: *gcp.Gcp, wher: Where, role: []const u8, member: []const u8, add: bool) !bool {
    const a = g.a;
    const rep = try g.call(wher.get_meth, wher.get_url, wher.get_body);
    if (!rep.okay()) return error.PolGet;
    var pol = rep.val;
    if (pol != .object) return error.PolShape;
    var changed = false;
    if (pol.object.getPtr("bindings") == null) {
        if (!add) return false;
        try pol.object.put(a, "bindings", .{ .array = std.json.Array.init(a) });
    }
    const bind = &pol.object.getPtr("bindings").?.array;
    if (findRole(bind, role)) |item| {
        const memv = item.object.getPtr("members") orelse return error.PolShape;
        if (memv.* != .array) return error.PolShape;
        const hit = findMember(&memv.array, member);
        if (add and hit == null) {
            try memv.array.append(.{ .string = member });
            changed = true;
        }
        if (!add and hit != null) {
            _ = memv.array.orderedRemove(hit.?);
            changed = true;
        }
    } else if (add) {
        var one: std.json.ObjectMap = .empty;
        try one.put(a, "role", .{ .string = role });
        var mems = std.json.Array.init(a);
        try mems.append(.{ .string = member });
        try one.put(a, "members", .{ .array = mems });
        try bind.append(.{ .object = one });
        changed = true;
    }
    if (!changed) return false;
    var top: std.json.ObjectMap = .empty;
    try top.put(a, "policy", pol);
    const body = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = top }, .{});
    const set = try g.call(.POST, wher.set_url, body);
    if (!set.okay()) return error.PolSet;
    return true;
}

test "policy edit shape compiles" {
    _ = edit;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
