// =====================================================================
// Des: Steps 4-6: create the free web service from the public image, keep plan and health path right, and push env vars from the vault.
// Flo: find or create service > check plan free + health path > hash env vars, replace them + deploy once only when changed
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: service id + url + env hash in the state file
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const engi = @import("co-engine.zig");
const ctxz = @import("co-ctx.zig");
const rend = @import("ap-render.zig");

const Ctx = ctxz.Ctx;

const CF = .{ .suspState = "suspended" };

// remember the plain ids of a service
fn idsSave(c: *Ctx, gpa: std.mem.Allocator, serv: rend.Serv) !void {
    c.stat.data.idsz.servId = try gpa.dupe(u8, serv.id);
    c.stat.data.idsz.servUrl = try gpa.dupe(u8, serv.serviceDetails.url);
    c.stat.data.idsz.servDash = try gpa.dupe(u8, serv.dashboardUrl);
}

fn servMake(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const conf = c.conf.rend;
    if (conf.imag.len == 0) {
        osyz.errz("  rend.imag is empty: set the public image path in 00-config.json\n", .{});
        return error.NoImage;
    }
    if (c.stat.data.idsz.owneId.len == 0) return error.NoOwner;
    if (c.stat.data.idsz.servId.len > 0) {
        if (c.rend.get(c.stat.data.idsz.servId)) |serv| {
            try idsSave(c, gpa, serv);
            return .{ .okay = "service already there" };
        } else |erro| if (erro != error.RendMiss) return erro;
    }
    if (try c.rend.find(conf.name, conf.kind)) |serv| {
        try idsSave(c, gpa, serv);
        return .{ .okay = "found existing service by name" };
    }
    const serv = c.rend.make(.{ .name = conf.name, .owne = c.stat.data.idsz.owneId, .imag = conf.imag, .plan = conf.plan, .regi = conf.regi, .heal = conf.heal, .inst = conf.inst }) catch |erro| {
        osyz.errz("  create failed: {s}\n", .{c.rend.mess});
        return erro;
    };
    try idsSave(c, gpa, serv);
    return .{ .okay = "service created" };
}

fn servSett(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    _ = gpa;
    const conf = c.conf.rend;
    const serv = try c.rend.get(c.stat.data.idsz.servId);
    if (std.mem.eql(u8, serv.suspended, CF.suspState)) {
        osyz.errz("  the service is suspended: resume it in the dashboard\n", .{});
        return error.Suspended;
    }
    if (!std.mem.eql(u8, serv.serviceDetails.plan, conf.plan)) {
        osyz.errz("  plan is {s} but config says {s}: the app never changes plans, fix by hand\n", .{ serv.serviceDetails.plan, conf.plan });
        return error.PlanDrift;
    }
    const have = serv.serviceDetails.healthCheckPath orelse "";
    if (std.mem.eql(u8, have, conf.heal)) return .{ .okay = "plan and health path match" };
    try c.rend.heal(serv.id, conf.heal);
    return .{ .okay = "health path fixed" };
}

fn envvSync(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    var list: std.ArrayList(rend.EnvPair) = .empty;
    var hash = std.hash.Wyhash.init(0);
    for (c.conf.envs) |item| {
        const valu = c.vaul.getz(item.vaul) orelse {
            if (item.need) {
                osyz.errz("  env var {s} is needed but vault key {s} is empty\n", .{ item.name, item.vaul });
                return error.EnvMissing;
            }
            continue;
        };
        try list.append(gpa, .{ .key = item.name, .value = valu });
        hash.update(item.name);
        hash.update("=");
        hash.update(valu);
        hash.update("\n");
    }
    if (list.items.len == 0) return .{ .skip = "no env vars to send" };
    const hexz = try std.fmt.allocPrint(gpa, "{x}", .{hash.final()});
    if (std.mem.eql(u8, hexz, c.stat.data.idsz.envHash)) return .{ .skip = "env vars unchanged" };
    try c.rend.envs(c.stat.data.idsz.servId, list.items);
    try c.rend.deploy(c.stat.data.idsz.servId);
    c.stat.data.idsz.envHash = hexz;
    return .{ .okay = try std.fmt.allocPrint(gpa, "{d} env vars sent, one deploy started", .{list.items.len}) };
}

pub fn rows(ctx: *Ctx) [3]engi.Row {
    return .{
        ctxz.row(ctx, "serv-make", "Create the free web service from the image", false, servMake),
        ctxz.row(ctx, "serv-sett", "Check plan free and health path", false, servSett),
        ctxz.row(ctx, "envv-sync", "Env vars from the vault, deploy once", false, envvSync),
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
