// =====================================================================
// Des: Step actions that build the account side: project, APIs, budget, and the small runtime service account. Each checks first, acts only if missing, then verifies.
// Flo: project: id from state or new random > create > number; APIs: list missing > enable; budget: find or make; service account: find or make, bind the one log role
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: Outc per action
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const proj = @import("ap-proj.zig");
const svcs = @import("ap-svcs.zig");
const bill = @import("ap-bill.zig");
const iam = @import("ap-iam.zig");
const pol = @import("ap-policy.zig");

const Ctx = ctxm.Ctx;
const Outc = engi.Outc;

const CF = .{ .keyProj = "proj", .keyNumb = "pnum", .keyBill = "bill", .keySacc = "sacc", .suffLen = 6, .idTrys = 3, .alphabet = "abcdefghijklmnopqrstuvwxyz0123456789", .saPause = 5, .getBody = "{\"options\":{\"requestedPolicyVersion\":3}}" };

// base + "-" + 6 random lowercase letters or digits
fn projIdNew(ctx: *Ctx) ![]const u8 {
    if (ctx.conf.goog.proj_iden.len != 0) return ctx.conf.goog.proj_iden;
    var raw: [CF.suffLen]u8 = undefined;
    ctx.io.random(&raw);
    var suff: [CF.suffLen]u8 = undefined;
    for (raw, 0..) |byte, indx| suff[indx] = CF.alphabet[byte % CF.alphabet.len];
    return std.fmt.allocPrint(ctx.a, "{s}-{s}", .{ ctx.conf.goog.proj_base, suff });
}

// the project: id kept in state before the create call, so a stopped run finds it again
pub fn projMake(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    var iden = ctx.projId();
    if (iden.len == 0) {
        iden = try projIdNew(ctx);
        try ctx.st.putz(CF.keyProj, iden);
        try ctx.st.save(ctx.io);
    }
    var made = false;
    var trys: u32 = 0;
    while (true) {
        if (try proj.getz(ctx.gcp, cfg.apis.crmz, iden)) |info| {
            if (!std.mem.eql(u8, info.state, "ACTIVE")) return .{ .fail = .{ .what = "project is not ACTIVE", .why = info.state, .fix = "use another goog.proj_iden or wait, then re-run" } };
            try ctx.st.putz(CF.keyNumb, info.number);
            return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} ({s}{s})", .{ iden, info.number, if (made) ", created" else "" }) };
        }
        proj.make(ctx.gcp, cfg.apis.crmz, iden, cfg.goog.proj_name) catch |erro| {
            if (erro == error.IdTaken and cfg.goog.proj_iden.len == 0 and trys + 1 < CF.idTrys) {
                trys += 1;
                iden = try projIdNew(ctx);
                try ctx.st.putz(CF.keyProj, iden);
                try ctx.st.save(ctx.io);
                continue;
            }
            return .{ .fail = .{ .what = "project not created", .why = @errorName(erro), .fix = "check the account may create projects; or set goog.proj_iden" } };
        };
        made = true;
    }
}

// turn on the wanted APIs (no quota header yet: the project has none of them on)
pub fn apisEnab(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const pid = ctx.projId();
    ctx.projUse("");
    const miss = try svcs.missing(ctx.gcp, cfg.apis.usag, pid, cfg.enab);
    if (miss.len != 0) {
        try svcs.enable(ctx.gcp, cfg.apis.usag, pid, miss);
        const left = try svcs.missing(ctx.gcp, cfg.apis.usag, pid, cfg.enab);
        if (left.len != 0) return .{ .fail = .{ .what = "APIs still off", .why = left[0], .fix = "re-run; check billing is linked" } };
    }
    ctx.projUse(pid);
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{d} APIs on ({d} newly enabled)", .{ cfg.enab.len, miss.len }) };
}

// the budget, before any deploy
pub fn budgMake(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const acct = ctx.st.valu(CF.keyBill);
    const numb = ctx.st.valu(CF.keyNumb);
    if (acct.len == 0 or numb.len == 0) return .{ .fail = .{ .what = "billing account or project number unknown", .why = "earlier steps did not record them", .fix = "re-run from the start" } };
    if (try bill.budgFind(ctx.gcp, cfg.apis.budg, acct, cfg.budg.name)) return .{ .done = "budget already there" };
    try bill.budgMake(ctx.gcp, cfg.apis.budg, acct, cfg.budg.name, numb, cfg.budg.amou, cfg.budg.step);
    if (!try bill.budgFind(ctx.gcp, cfg.apis.budg, acct, cfg.budg.name)) return .{ .fail = .{ .what = "budget not found after create", .why = "the list did not show it", .fix = "re-run" } };
    return .{ .done = try std.fmt.allocPrint(ctx.a, "budget {d} with {d} alerts (a budget warns, it does not cap spend)", .{ cfg.budg.amou, cfg.budg.step.len }) };
}

// the runtime account: one log role, no key
pub fn saccMake(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const pid = ctx.projId();
    const mail = try iam.saEnsure(ctx.gcp, cfg.apis.iamz, pid, cfg.goog.sacc, "cloud-house runtime");
    try ctx.st.putz(CF.keySacc, mail);
    const member = try std.fmt.allocPrint(ctx.a, "serviceAccount:{s}", .{mail});
    const wher: pol.Where = .{ .get_meth = .POST, .get_url = try std.fmt.allocPrint(ctx.a, "{s}/v1/projects/{s}:getIamPolicy", .{ cfg.apis.crmz, pid }), .get_body = CF.getBody, .set_url = try std.fmt.allocPrint(ctx.a, "{s}/v1/projects/{s}:setIamPolicy", .{ cfg.apis.crmz, pid }) };
    var trys: u32 = 0;
    while (true) {
        const changed = pol.edit(ctx.gcp, wher, cfg.serv.role, member, true) catch |erro| {
            // a brand-new account can take a few seconds to be known to IAM
            if (erro == error.PolSet and trys < CF.saPause) {
                trys += 1;
                std.Io.sleep(ctx.io, .fromMilliseconds(cfg.http.lro_msec), .awake) catch {};
                continue;
            }
            return .{ .fail = .{ .what = "role not bound", .why = @errorName(erro), .fix = "re-run in a minute" } };
        };
        return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} has only {s}{s}", .{ mail, cfg.serv.role, if (changed) "" else " (already)" }) };
    }
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
