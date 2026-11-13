// =====================================================================
// Des: Steps 5, 6 and 9: the compartment, the network (VCN, gateway, route, firewall rules, subnet) and the check that only the configured firewall rules exist. Every make is find-first. Foreign rules are reported, never removed.
// Flo: find or make > wait until ACTIVE > save ids > later re-read the firewall and compare with config
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, signed client)
// Out: engine rows comp-make, netw-make, ingr-lock
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const oci = @import("ap-oci.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;

const CF = .{ .stateOkay = "ACTIVE" };

pub fn rows(ctx: *Ctx) [2]engi.Row {
    return .{ ctxx.row(ctx, "comp-make", &compMake), ctxx.row(ctx, "netw-make", &netwMake) };
}

pub fn rowLock(ctx: *Ctx) engi.Row {
    return ctxx.row(ctx, "ingr-lock", &ingrLock);
}

// the configured firewall rules as the client type
pub fn wantRules(ctx: *Ctx) []const oci.Rule {
    const list = ctx.gpa.alloc(oci.Rule, ctx.conf.ingr.len) catch return &.{};
    for (ctx.conf.ingr, 0..) |item, indx| list[indx] = .{ .port = item.port, .cidr = item.cidr, .desc = item.desc };
    return list;
}

fn live(ctx: *Ctx) !void {
    if (!try ctx.ociUp()) return error.NoCreds;
}

// step 5
fn compMake(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    var iden: []const u8 = (try ctx.oci.compFind(idsz.tena, ctx.conf.comp.name)) orelse "";
    var note: []const u8 = "compartment found";
    if (iden.len == 0) {
        iden = try ctx.oci.compMake(idsz.tena, ctx.conf.comp.name, ctx.conf.comp.desc);
        note = "compartment made";
    }
    var left: u64 = ctx.conf.inst.wait;
    while (!std.mem.eql(u8, try ctx.oci.compState(iden), CF.stateOkay)) {
        if (left <= ctx.conf.inst.poll) return error.WaitTime;
        left -= ctx.conf.inst.poll;
        ctx.sleepSecs(ctx.conf.inst.poll);
    }
    idsz.comp = iden;
    try ctx.stat.save();
    return .{ .okay = note };
}

// step 6
fn netwMake(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = &ctx.stat.data.idsz;
    const net = ctx.conf.netw;
    if (idsz.comp.len == 0) return error.NoCompartment;
    const vcn = (try ctx.oci.vcnFind(idsz.comp, net.vcnn)) orelse try ctx.oci.vcnMake(idsz.comp, net.vcnn, net.vcnc);
    idsz.vcnn = vcn.iden;
    idsz.rout = vcn.rout;
    idsz.secl = vcn.secl;
    idsz.igwn = (try ctx.oci.igwFind(idsz.comp, vcn.iden, net.igwn)) orelse try ctx.oci.igwMake(idsz.comp, vcn.iden, net.igwn);
    _ = try ctx.oci.routeEnsure(vcn.rout, idsz.igwn);
    _ = try ctx.oci.secEnsure(vcn.secl, wantRules(ctx));
    idsz.subn = (try ctx.oci.subnFind(idsz.comp, vcn.iden, net.subn)) orelse try ctx.oci.subnMake(idsz.comp, vcn.iden, net.subn, net.subc, vcn.rout, vcn.secl);
    try ctx.stat.save();

    // re-read: what we asked for is what Oracle holds
    const back = try ctx.oci.secRead(vcn.secl);
    for (ctx.conf.ingr) |want| {
        var found = false;
        for (back.tcp) |item| if (item.port == want.port and std.mem.eql(u8, item.cidr, want.cidr)) {
            found = true;
        };
        if (!found) return error.NetwVerify;
    }
    return .{ .okay = "vcn, gateway, route, firewall, subnet ready" };
}

// step 9: only the configured tcp rules (plus Oracle's default ICMP) may exist
pub fn ingrLock(ctx: *Ctx) anyerror!Done {
    try live(ctx);
    const idsz = ctx.stat.data.idsz;
    const back = try ctx.oci.secRead(idsz.secl);
    var extra: u32 = back.other;
    for (back.tcp) |item| {
        var known = false;
        for (ctx.conf.ingr) |want| if (item.port == want.port and std.mem.eql(u8, item.cidr, want.cidr)) {
            known = true;
        };
        if (!known) {
            extra += 1;
            ctx.say("  foreign rule: tcp {d} from {s} (left untouched)\n", .{ item.port, item.cidr });
        }
    }
    if (extra > 0) {
        ctx.drift = true;
        osyz.errz("drift: {d} firewall rule(s) are not in config. The app never removes them. Review them in the console\n", .{extra});
        return .{ .okay = "DRIFT: extra firewall rules found, none removed" };
    }
    return .{ .okay = "firewall equals config" };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
