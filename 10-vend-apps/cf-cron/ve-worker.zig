// =====================================================================
// Des: Steps 4-7: workers.dev name, upload the tick Worker, route on, cron schedule. Each step checks first and only changes what differs.
// Flo: read live > compare > change if needed > save hash
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: shared run context
// Out: engine rows
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const engi = @import("co-engine.zig");
const ctxz = @import("co-ctx.zig");
const cfla = @import("ap-cflare.zig");

const Ctx = ctxz.Ctx;

const source = @embedFile("df-worker.js");
const CF = .{ .subPref = "ch-", .bindUrlz = "TRIGGER_URL", .bindMeth = "TRIGGER_METHOD", .bindHead = "SECRET_HEADER", .bindSecr = "TICK_SECRET" };

// the cron text for the period in config
pub fn cronText(gpa: std.mem.Allocator, peri: u32) ![]u8 {
    return std.fmt.allocPrint(gpa, "*/{d} * * * *", .{peri});
}

// the workers.dev name: config, else a stable one from the account id
fn subName(c: *Ctx, gpa: std.mem.Allocator) ![]u8 {
    if (c.conf.cfla.subd.len > 0) return gpa.dupe(u8, c.conf.cfla.subd);
    return std.fmt.allocPrint(gpa, "{s}{x:0>8}", .{ CF.subPref, @as(u32, @truncate(std.hash.Wyhash.hash(0, c.stat.data.idsz.acctId))) });
}

fn subdMake(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const acco = c.stat.data.idsz.acctId;
    if (acco.len == 0) return error.NoAccount;
    if (try c.cfla.subGet(acco)) |name| {
        c.stat.data.idsz.subdomain = try gpa.dupe(u8, name);
        return .{ .okay = try std.fmt.allocPrint(gpa, "workers.dev name {s} already there", .{name}) };
    }
    const name = try subName(c, gpa);
    c.cfla.subSet(acco, name) catch |erro| {
        osyz.errz("  could not register {s}: {s}\n", .{ name, c.cfla.mess });
        return erro;
    };
    c.stat.data.idsz.subdomain = name;
    return .{ .okay = try std.fmt.allocPrint(gpa, "workers.dev name {s} registered", .{name}) };
}

// base url + path with exactly one slash between
pub fn joinUrl(gpa: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ std.mem.trimEnd(u8, base, "/"), path });
}

test "url join keeps one slash" {
    const outp = try joinUrl(std.testing.allocator, "https://x.test/", "/tick");
    defer std.testing.allocator.free(outp);
    try std.testing.expectEqualStrings("https://x.test/tick", outp);
}

// bindings from config + vault (the tick secret is optional)
fn bindList(c: *Ctx, gpa: std.mem.Allocator) ![]cfla.Bind {
    var list: std.ArrayList(cfla.Bind) = .empty;
    const urlz = try joinUrl(gpa, c.conf.trig.url, c.conf.trig.path);
    try list.append(gpa, .{ .name = CF.bindUrlz, .text = urlz, .secret = false });
    try list.append(gpa, .{ .name = CF.bindMeth, .text = c.conf.trig.meth, .secret = false });
    try list.append(gpa, .{ .name = CF.bindHead, .text = c.conf.trig.head, .secret = false });
    if (c.vaul.getz(c.conf.trig.secr)) |secr| try list.append(gpa, .{ .name = CF.bindSecr, .text = secr, .secret = true });
    return list.items;
}

fn bindHash(c: *Ctx, gpa: std.mem.Allocator, binds: []const cfla.Bind) ![]u8 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(source);
    hash.update(c.conf.cfla.comp);
    hash.update(c.conf.cfla.scri);
    for (binds) |item| {
        hash.update(item.name);
        hash.update("=");
        hash.update(item.text);
        hash.update("\n");
    }
    return std.fmt.allocPrint(gpa, "{x}", .{hash.final()});
}

fn workPush(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const idsz = &c.stat.data.idsz;
    if (c.conf.trig.url.len == 0) {
        osyz.errz("  trig.url is empty: set the Trigger url in 00-config.json\n", .{});
        return error.NoTrigger;
    }
    const binds = try bindList(c, gpa);
    const hexz = try bindHash(c, gpa, binds);
    if (std.mem.eql(u8, hexz, idsz.workHash) and try c.cfla.exists(idsz.acctId, c.conf.cfla.scri)) return .{ .skip = "worker unchanged" };
    c.cfla.push(idsz.acctId, c.conf.cfla.scri, c.conf.cfla.comp, source, binds) catch |erro| {
        osyz.errz("  upload failed: {s}\n", .{c.cfla.mess});
        return erro;
    };
    idsz.workHash = hexz;
    return .{ .okay = try std.fmt.allocPrint(gpa, "worker {s} uploaded with {d} bindings", .{ c.conf.cfla.scri, binds.len }) };
}

// the public address of the Worker (template from config)
pub fn workUrl(c: *Ctx, gpa: std.mem.Allocator) ![]u8 {
    const one = try std.mem.replaceOwned(u8, gpa, c.conf.cfla.rout, "{scri}", c.conf.cfla.scri);
    return std.mem.replaceOwned(u8, gpa, one, "{subd}", c.stat.data.idsz.subdomain);
}

fn workRout(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const idsz = &c.stat.data.idsz;
    const onzz = try c.cfla.route(idsz.acctId, c.conf.cfla.scri);
    if (!onzz) return error.RouteOff;
    idsz.workUrl = try workUrl(c, gpa);
    return .{ .okay = try std.fmt.allocPrint(gpa, "route on: {s}", .{idsz.workUrl}) };
}

fn cronSet(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const idsz = &c.stat.data.idsz;
    const want = try cronText(gpa, c.conf.cron.peri);
    const have = try c.cfla.schedGet(idsz.acctId, c.conf.cfla.scri);
    if (have.len == 1 and std.mem.eql(u8, have[0], want)) {
        idsz.cronNow = want;
        return .{ .okay = try std.fmt.allocPrint(gpa, "cron {s} already set", .{want}) };
    }
    c.cfla.sched(idsz.acctId, c.conf.cfla.scri, &.{want}) catch |erro| {
        osyz.errz("  cron not set: {s}\n", .{c.cfla.mess});
        return erro;
    };
    const back = try c.cfla.schedGet(idsz.acctId, c.conf.cfla.scri);
    if (back.len != 1 or !std.mem.eql(u8, back[0], want)) return error.CronDrift;
    idsz.cronNow = want;
    return .{ .okay = try std.fmt.allocPrint(gpa, "cron {s} set (live in up to 15 min)", .{want}) };
}

pub fn rows(ctx: *Ctx) [4]engi.Row {
    return .{
        ctxz.row(ctx, "subd-make", "Make sure the workers.dev name exists", false, subdMake),
        ctxz.row(ctx, "work-push", "Upload the tick Worker", false, workPush),
        ctxz.row(ctx, "work-rout", "Turn on the workers.dev address", false, workRout),
        ctxz.row(ctx, "cron-set", "Set the cron trigger", false, cronSet),
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
