// =====================================================================
// Des: Talks to Cloud Billing and Billing Budgets: lists open billing accounts, links a project, and makes the budget with alerts.
// Flo: list accounts > read/link project billing > list budgets > create budget with threshold rules
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api bases, project id and number, billing account id, budget settings
// Out: account list, linked account id, budget exists
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");

pub const Erro = error{BillHttp};

const CF = .{ .acctPref = "billingAccounts/", .pageSize = 50 };

pub const Acct = struct { iden: []const u8, name: []const u8 };

// open billing accounts the user can see
pub fn openList(g: *gcp.Gcp, base: []const u8) ![]Acct {
    const rep = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v1/billingAccounts?filter=open%3Dtrue&pageSize={d}", .{ base, CF.pageSize }), null);
    if (!rep.okay()) return error.BillHttp;
    var outp: std.ArrayList(Acct) = .empty;
    const arr = gcp.obj(rep.val, "billingAccounts");
    if (arr == .array) for (arr.array.items) |item| {
        const name = gcp.str(gcp.obj(item, "name"));
        const open = gcp.obj(item, "open");
        if (open == .bool and !open.bool) continue;
        if (!std.mem.startsWith(u8, name, CF.acctPref)) continue;
        try outp.append(g.a, .{ .iden = name[CF.acctPref.len..], .name = gcp.str(gcp.obj(item, "displayName")) });
    };
    return outp.toOwnedSlice(g.a);
}

// the billing account id the project is linked to (billing on), else null
pub fn linked(g: *gcp.Gcp, base: []const u8, proj: []const u8) !?[]const u8 {
    const rep = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/billingInfo", .{ base, proj }), null);
    if (!rep.okay()) return error.BillHttp;
    const on = gcp.obj(rep.val, "billingEnabled");
    const name = gcp.str(gcp.obj(rep.val, "billingAccountName"));
    if (on != .bool or !on.bool or !std.mem.startsWith(u8, name, CF.acctPref)) return null;
    return name[CF.acctPref.len..];
}

// link the project to the account
pub fn link(g: *gcp.Gcp, base: []const u8, proj: []const u8, acct: []const u8) !void {
    const Body = struct { billingAccountName: []const u8 };
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .billingAccountName = try std.fmt.allocPrint(g.a, "{s}{s}", .{ CF.acctPref, acct }) }, .{});
    const rep = try g.call(.PUT, try std.fmt.allocPrint(g.a, "{s}/v1/projects/{s}/billingInfo", .{ base, proj }), body);
    if (!rep.okay()) return error.BillHttp;
}

// true when a budget with this display name exists on the account
pub fn budgFind(g: *gcp.Gcp, base: []const u8, acct: []const u8, name: []const u8) !bool {
    const rep = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v1/billingAccounts/{s}/budgets?pageSize=100", .{ base, acct }), null);
    if (!rep.okay()) return error.BillHttp;
    const arr = gcp.obj(rep.val, "budgets");
    if (arr == .array) for (arr.array.items) |item| if (std.mem.eql(u8, gcp.str(gcp.obj(item, "displayName")), name)) return true;
    return false;
}

// make the budget: whole-unit amount in the account's own currency, alerts at each threshold
pub fn budgMake(g: *gcp.Gcp, base: []const u8, acct: []const u8, name: []const u8, number: []const u8, amou: u32, steps: []const f64) !void {
    const Rule = struct { thresholdPercent: f64 };
    const Body = struct { displayName: []const u8, budgetFilter: struct { projects: []const []const u8 }, amount: struct { specifiedAmount: struct { units: []const u8 } }, thresholdRules: []const Rule };
    const rules = try g.a.alloc(Rule, steps.len);
    for (steps, 0..) |pct, indx| rules[indx] = .{ .thresholdPercent = pct };
    const projs = try g.a.alloc([]const u8, 1);
    projs[0] = try std.fmt.allocPrint(g.a, "projects/{s}", .{number});
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .displayName = name, .budgetFilter = .{ .projects = projs }, .amount = .{ .specifiedAmount = .{ .units = try std.fmt.allocPrint(g.a, "{d}", .{amou}) } }, .thresholdRules = rules }, .{});
    const rep = try g.call(.POST, try std.fmt.allocPrint(g.a, "{s}/v1/billingAccounts/{s}/budgets", .{ base, acct }), body);
    if (!rep.okay()) return error.BillHttp;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
