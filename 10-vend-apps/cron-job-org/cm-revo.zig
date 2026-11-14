// =====================================================================
// Des: The revoke command: takes back only what this app added. It turns the tick job off and forgets the API key and the tick secret in the vault. Nothing is deleted at the vendor.
// Flo: no --go: say what would happen > --go: PATCH enabled=false > drop both vault keys > reopen the key step
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, live flag
// Out: exit code
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const fail = @import("ve-fail.zig");

const CF = .{ .exitOkay = 0, .exitFail = 1, .keyJob = "jobid", .bodyOff = "{\"job\":{\"enabled\":false}}", .idenKeyz = "keyz-make", .codeKey = 401, .codeGone = 404 };

pub fn revoke(ctx: *ctxm.Ctx, live: bool) !u8 {
    const iden = ctx.st.valu(CF.keyJob);
    if (!live) {
        ctx.say("dry-run: would turn job {s} off and forget the API key and the tick secret in the vault.\nNothing is deleted. Pass --go to do it.\n", .{if (iden.len == 0) "(none known)" else iden});
        return CF.exitOkay;
    }
    const hadKey = ctx.keyLoad() catch |erro| return fail.vaulExit(ctx, erro);
    if (!hadKey and iden.len != 0) ctx.say("no API key in the vault: cannot turn job {s} off from here; do it in the Console\n", .{iden});
    if (hadKey and iden.len != 0) {
        const rep = ctx.cron.patch(iden, CF.bodyOff) catch |erro| {
            ctx.say("could not turn the job off: {s}. The key stays in the vault. Re-run revoke.\n", .{@errorName(erro)});
            return CF.exitFail;
        };
        if (rep.okay()) {
            ctx.say("job {s}: turned off\n", .{iden});
        } else if (rep.code == CF.codeKey or rep.code == CF.codeGone) {
            ctx.say("job {s}: the vendor says HTTP {d} (key dead or job gone), nothing more to turn off\n", .{ iden, rep.code });
        } else {
            ctx.say("could not turn the job off (HTTP {d}: {s}). The key stays in the vault. Re-run revoke.\n", .{ rep.code, rep.errText() });
            return CF.exitFail;
        }
    }
    const vlt = try ctx.vault();
    try vlt.drop(ctx.conf.vaul.keya);
    try vlt.drop(ctx.conf.vaul.keyt);
    try ctx.st.setz(CF.idenKeyz, .todo, "revoked", ctx.nowSecs());
    try ctx.handDrop(CF.idenKeyz);
    try ctx.st.save(ctx.io);
    ctx.say("vault: API key and tick secret forgotten here\nlast hand step: revoke the key itself in the Console (Settings > API)\n", .{});
    return CF.exitOkay;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
