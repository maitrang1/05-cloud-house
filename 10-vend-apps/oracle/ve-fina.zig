// =====================================================================
// Des: Steps 10 and 11: write a backup of the config and the saved ids (never a secret), then the final check and report: free-quota use, the SSH command, and a warning at the configured percent.
// Flo: copy config + ids into the backup folder > sha256 > read live VM count > percent of quota > print the report
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, signed client)
// Out: engine rows back-conf, repo-fina
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const tmpo = @import("co-time.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;
const Sha = std.crypto.hash.sha2.Sha256;

const CF = .{ .fileMaxz = 1 << 20, .pcntFull = 100 };

pub fn rows(ctx: *Ctx) [2]engi.Row {
    return .{ ctxx.row(ctx, "back-conf", &backConf), ctxx.row(ctx, "repo-fina", &repoFina) };
}

// percent used, rounded up, never above what the numbers say
pub fn pcntUsed(used: u32, maxx: u32) u32 {
    if (maxx == 0) return CF.pcntFull;
    return (used * CF.pcntFull + maxx - 1) / maxx;
}

// step 10
fn backConf(ctx: *Ctx) anyerror!Done {
    const dirz = try std.fs.path.join(ctx.gpa, &.{ ctx.root, ctx.conf.data.back });
    try std.Io.Dir.cwd().createDirPath(ctx.io, dirz);
    const day = tmpo.isoDay(ctx.nowSecs());
    const ids = try std.json.Stringify.valueAlloc(ctx.gpa, ctx.stat.data.idsz, .{ .whitespace = .indent_2 });
    const cfgt = std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.confPath, ctx.gpa, .limited(CF.fileMaxz)) catch "";
    const text = try std.fmt.allocPrint(ctx.gpa, "{{\n\"day\": \"{s}\",\n\"ids\": {s},\n\"config\": {s}\n}}\n", .{ day, ids, if (cfgt.len > 0) cfgt else "null" });
    const file = try std.fmt.allocPrint(ctx.gpa, "oracle-{s}.json", .{day});
    const path = try std.fs.path.join(ctx.gpa, &.{ dirz, file });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = text });
    var dige: [Sha.digest_length]u8 = undefined;
    Sha.hash(text, &dige, .{});
    return .{ .okay = try std.fmt.allocPrint(ctx.gpa, "{s} sha256 {x}", .{ file, dige[0..8] }) };
}

// step 11
fn repoFina(ctx: *Ctx) anyerror!Done {
    if (!try ctx.ociUp()) return error.NoCreds;
    const idsz = ctx.stat.data.idsz;
    const live = try ctx.oci.instList(idsz.comp);
    const used: u32 = @intCast(live.len);
    const vmpc = pcntUsed(used, ctx.conf.quot.vmax);
    const gbpc = pcntUsed(used * ctx.conf.inst.boot, ctx.conf.quot.bmax);
    ctx.say("  free quota: VMs {d}/{d} ({d}%), boot disk {d}/{d} GB ({d}%)\n", .{ used, ctx.conf.quot.vmax, vmpc, used * ctx.conf.inst.boot, ctx.conf.quot.bmax, gbpc });
    if (vmpc >= ctx.conf.quot.warn or gbpc >= ctx.conf.quot.warn) osyz.errz("warning: free quota is at or above {d}%\n", .{ctx.conf.quot.warn});
    ctx.say("  VM: {s}  ip: {s}\n  log in: ssh -i <key file> {s}@{s}   (get the key file: oracle-setup sshkey <path>)\n", .{ ctx.conf.inst.name, idsz.pubi, ctx.conf.inst.user, idsz.pubi });
    return .{ .okay = "report printed" };
}

test "percent is rounded up and safe on zero" {
    try std.testing.expectEqual(@as(u32, 50), pcntUsed(1, 2));
    try std.testing.expectEqual(@as(u32, 100), pcntUsed(2, 2));
    try std.testing.expectEqual(@as(u32, 100), pcntUsed(1, 0));
    try std.testing.expectEqual(@as(u32, 25), pcntUsed(50, 200));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
