// =====================================================================
// Des: Steps 12 and 13: write a backup of the config and the saved ids (never a secret), then the final report: ticks a month against the free quota, the cost estimate, and the things only a human can do (deactivate the bootstrap key, confirm the budget email, the account plan).
// Flo: copy config + ids into the backup folder > sha256 > ticks per month > percent of quota > cost estimate > print the to-do lines
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state)
// Out: engine rows back-conf, repo-fina
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const conf = @import("co-conf.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const tmpo = @import("co-time.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;
const Sha = std.crypto.hash.sha2.Sha256;

const CF = .{ .fileMaxz = 1 << 20, .pcntFull = 100, .perMill = 1000000.0 };

pub fn rows(ctx: *Ctx) [2]engi.Row {
    return .{ ctxx.row(ctx, "back-conf", &backConf), ctxx.row(ctx, "repo-fina", &repoFina) };
}

// percent used, rounded up, never above what the numbers say
pub fn pcntUsed(used: u64, maxx: u64) u64 {
    if (maxx == 0) return CF.pcntFull;
    return (used * CF.pcntFull + maxx - 1) / maxx;
}

// estimated dollars a month: events put on the bus plus API destination calls (the Scheduler part is inside the free quota)
pub fn costMont(mont: u64, free: u64, evtp: f64, apip: f64) f64 {
    const over: f64 = @floatFromInt(mont -| free);
    const evnt: f64 = @floatFromInt(mont);
    return (evnt * evtp + evnt * apip + over * evtp) / CF.perMill;
}

// step 12
fn backConf(ctx: *Ctx) anyerror!Done {
    const dirz = try std.fs.path.join(ctx.gpa, &.{ ctx.root, ctx.conf.data.back });
    try std.Io.Dir.cwd().createDirPath(ctx.io, dirz);
    const day = tmpo.isoDay(ctx.nowSecs());
    const ids = try std.json.Stringify.valueAlloc(ctx.gpa, ctx.stat.data.idsz, .{ .whitespace = .indent_2 });
    const cfgt = std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.confPath, ctx.gpa, .limited(CF.fileMaxz)) catch "";
    const text = try std.fmt.allocPrint(ctx.gpa, "{{\n\"day\": \"{s}\",\n\"ids\": {s},\n\"config\": {s}\n}}\n", .{ day, ids, if (cfgt.len > 0) cfgt else "null" });
    const file = try std.fmt.allocPrint(ctx.gpa, "awseb-{s}.json", .{day});
    const path = try std.fs.path.join(ctx.gpa, &.{ dirz, file });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = text });
    var dige: [Sha.digest_length]u8 = undefined;
    Sha.hash(text, &dige, .{});
    return .{ .okay = try std.fmt.allocPrint(ctx.gpa, "{s} sha256 {x}", .{ file, dige[0..8] }) };
}

// step 13
fn repoFina(ctx: *Ctx) anyerror!Done {
    const tick = ctx.conf.tick;
    const mont = conf.rateMont(tick.rate, ctx.conf.quot.days) orelse return error.BadRate;
    const pcnt = pcntUsed(mont, ctx.conf.quot.free);
    ctx.say("  ticks a month: {d} of {d} free ({d}%)\n", .{ mont, ctx.conf.quot.free, pcnt });
    if (pcnt >= ctx.conf.quot.warn) osyz.errz("warning: free quota is at or above {d}%\n", .{ctx.conf.quot.warn});
    ctx.say("  estimated cost a month: about ${d:.2} (budget alert: {s} {s} at {d}%)\n", .{ costMont(mont, ctx.conf.quot.free, ctx.conf.quot.evtp, ctx.conf.quot.apip), ctx.conf.budg.limi, ctx.conf.budg.unit, ctx.conf.budg.warn });
    if (tick.urlz.len == 0) ctx.say("  to do: set tick.urlz in the config, then run again to finish the tick\n", .{}) else ctx.say("  tick: {s} every {s} -> {s} (header {s}; get the secret: aws-eventbridge-setup tickkey <file>)\n", .{ if (tick.on) "ON" else "OFF", tick.rate, tick.urlz, tick.keyn });
    if (ctx.usedBoot) ctx.say("  to do: deactivate the access key you pasted: {s}  (the app never deletes it for you)\n", .{ctx.conf.urls.keys});
    ctx.say("  to do: click the confirmation link in the budget email once\n  to do: check the account plan is Paid: {s}\n", .{ctx.conf.urls.plan});
    return .{ .okay = "report printed" };
}

test "percent and cost maths" {
    try std.testing.expectEqual(@as(u64, 1), pcntUsed(43200, 14000000) -| 0);
    try std.testing.expectEqual(@as(u64, 100), pcntUsed(1, 0));
    const cost = costMont(43200, 14000000, 1.0, 0.2);
    try std.testing.expect(cost > 0.051 and cost < 0.053); // 43200 * 1.2 / 1e6
    try std.testing.expect(costMont(15000000, 14000000, 1.0, 0.2) > 18.0); // above the quota costs real money
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
