// =====================================================================
// Des: Step actions that put the service live: image path, deploy, tick URL handoff, and the final check with the quota report.
// Flo: image: direct or pull-through repo > deploy: create or patch on drift, public invoker > handoff file (+ optional probe) > final: ready? usage?
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
const arty = @import("ap-arty.zig");
const runs = @import("ap-runs.zig");
const moni = @import("ap-moni.zig");
const hand = @import("rw-hand.zig");

const Ctx = ctxm.Ctx;
const Outc = engi.Outc;

const CF = .{ .keySacc = "sacc", .keyImag = "image", .keyUri = "uri", .headRun = "X-Run-Id", .probeN = 2 };

// image reference: the config one as is, or a path through the remote repo
pub fn imagPath(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    if (cfg.imag.sour.len == 0) {
        try ctx.st.putz(CF.keyImag, cfg.imag.refe);
        return .{ .skip = try std.fmt.allocPrint(ctx.a, "using imag.refe as is: {s}", .{cfg.imag.refe}) };
    }
    const pid = ctx.projId();
    arty.repoEnsure(ctx.gcp, cfg.apis.arti, pid, cfg.goog.regi, cfg.goog.arty, cfg.imag.upst) catch |erro| {
        if (erro == error.UpstDiff) return .{ .fail = .{ .what = "remote repo has another upstream", .why = "an upstream cannot be changed after creation", .fix = "set another goog.arty name, then re-run" } };
        return .{ .fail = .{ .what = "remote repo not made", .why = @errorName(erro), .fix = "check billing and the artifactregistry API, then re-run" } };
    };
    const image = try std.fmt.allocPrint(ctx.a, "{s}-docker.pkg.dev/{s}/{s}/{s}", .{ cfg.goog.regi, pid, cfg.goog.arty, cfg.imag.sour });
    try ctx.st.putz(CF.keyImag, image);
    return .{ .done = image };
}

// the spec of the service, all from config and state
fn specOf(ctx: *Ctx) runs.Spec {
    const sv = ctx.conf.serv;
    return .{ .image = ctx.st.valu(CF.keyImag), .sacc = ctx.st.valu(CF.keySacc), .mini = sv.mini, .maxi = sv.maxi, .cpuz = sv.cpuz, .memo = sv.memo, .idle = sv.idle, .conc = sv.conc, .time = sv.time, .ingr = sv.ingr, .port = sv.port };
}

// create the service, or patch it when it drifted; make it public when asked
pub fn servDepl(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const pid = ctx.projId();
    const spec = specOf(ctx);
    if (spec.image.len == 0 or spec.sacc.len == 0) return .{ .fail = .{ .what = "image or service account unknown", .why = "earlier steps did not record them", .fix = "re-run from the start" } };
    const name = try runs.svcName(ctx.a, pid, cfg.goog.regi, cfg.goog.serv);
    var what: []const u8 = "unchanged";
    const cur = try runs.getz(ctx.gcp, cfg.apis.runz, name);
    if (cur == null) {
        try runs.deploy(ctx.gcp, cfg.apis.runz, pid, cfg.goog.regi, cfg.goog.serv, spec, false);
        what = "created";
    } else if (runs.drift(cur.?.val, spec)) {
        try runs.deploy(ctx.gcp, cfg.apis.runz, pid, cfg.goog.regi, cfg.goog.serv, spec, true);
        what = "patched";
    }
    const now = (try runs.getz(ctx.gcp, cfg.apis.runz, name)) orelse return .{ .fail = .{ .what = "service missing after deploy", .why = "GET found nothing", .fix = "re-run" } };
    if (!runs.ready(now.val) or runs.uri(now.val).len == 0) return .{ .fail = .{ .what = "service is not Ready", .why = "terminalCondition is not CONDITION_SUCCEEDED", .fix = "open Cloud Run logs for the revision, fix the image, re-run" } };
    var publ: []const u8 = "private";
    if (cfg.serv.publ) {
        _ = runs.publSet(ctx.gcp, cfg.apis.runz, name) catch |erro| return .{ .fail = .{ .what = "could not allow public calls", .why = @errorName(erro), .fix = "an org policy may forbid allUsers; set serv.publ=false or ask the org admin" } };
        publ = "public";
    }
    try ctx.st.putz(CF.keyUri, runs.uri(now.val));
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} ({s}, min {d} max {d}) {s}", .{ what, publ, spec.mini, spec.maxi, runs.uri(now.val) }) };
}

// write the handoff file; probe the tick path twice when switched on
pub fn tickWire(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const uri = ctx.st.valu(CF.keyUri);
    if (uri.len == 0) return .{ .fail = .{ .what = "service url unknown", .why = "the deploy step did not record it", .fix = "re-run" } };
    const tick = try std.fmt.allocPrint(ctx.a, "{s}{s}", .{ uri, cfg.tick.path });
    const path = try std.fs.path.join(ctx.a, &.{ ctx.root, cfg.data.hand });
    const changed = try hand.write(ctx.io, ctx.a, path, .{ .proj = ctx.projId(), .regi = cfg.goog.regi, .serv = cfg.goog.serv, .uri = uri, .tick_url = tick });
    if (!cfg.tick.prob) return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} ({s}, probe off)", .{ tick, if (changed) "written" else "unchanged" }) };
    var seen: u32 = 0;
    while (seen < CF.probeN) : (seen += 1) {
        const resp = try ctx.http.call(.{ .meth = .POST, .urlz = tick, .body = "{}", .xtra = &.{.{ .name = CF.headRun, .value = cfg.tick.ruid }} });
        var okay = false;
        for (cfg.tick.okay) |code| {
            if (code == resp.code) okay = true;
        }
        if (!okay) return .{ .fail = .{ .what = "tick probe refused", .why = try std.fmt.allocPrint(ctx.a, "answered {d}", .{resp.code}), .fix = "deploy the dispatcher image (imag.sour) or set tick.prob=false" } };
    }
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} (probe ok twice)", .{tick}) };
}

// percent of a limit used (0 when the limit is 0)
pub fn pctOf(used: f64, limi: u64) f64 {
    if (limi == 0) return 0;
    return used * 100.0 / @as(f64, @floatFromInt(limi));
}

// print this month's use against the free grant; true when any is at or over the warn percent
pub fn usageShow(ctx: *Ctx) !bool {
    const cfg = ctx.conf;
    const use = try moni.usage(ctx.gcp, cfg.apis.moni, ctx.projId(), ctx.nowSecs());
    const rows = [_]struct { name: []const u8, used: f64, limi: u64 }{ .{ .name = "requests", .used = use.reqs, .limi = cfg.limi.reqs }, .{ .name = "vCPU-seconds", .used = use.vcpu, .limi = cfg.limi.vcpu }, .{ .name = "GiB-seconds", .used = use.gibs, .limi = cfg.limi.gibs } };
    var warn = false;
    for (rows) |row| {
        const pct = pctOf(row.used, row.limi);
        const hot = pct >= @as(f64, @floatFromInt(cfg.limi.warn));
        if (hot) warn = true;
        ctx.say("   {s}: {d:.0} of {d} ({d:.1}%){s}\n", .{ row.name, row.used, row.limi, pct, if (hot) "  WARNING" else "" });
    }
    return warn;
}

// last step: service Ready, quota report (a failing report never fails the setup)
pub fn finaChec(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const name = try runs.svcName(ctx.a, ctx.projId(), cfg.goog.regi, cfg.goog.serv);
    const cur = (try runs.getz(ctx.gcp, cfg.apis.runz, name)) orelse return .{ .fail = .{ .what = "service missing", .why = "GET found nothing", .fix = "re-run" } };
    if (!runs.ready(cur.val)) return .{ .fail = .{ .what = "service is not Ready", .why = "terminalCondition is not CONDITION_SUCCEEDED", .fix = "check Cloud Run logs" } };
    ctx.say("   url: {s}\n", .{runs.uri(cur.val)});
    _ = usageShow(ctx) catch |erro| ctx.say("   quota: n/a ({s}); metrics can lag a few minutes\n", .{@errorName(erro)});
    return .{ .done = "ready" };
}

test "percent of a limit" {
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), pctOf(1000, 2000), 0.001);
    try std.testing.expectEqual(@as(f64, 0), pctOf(5, 0));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
