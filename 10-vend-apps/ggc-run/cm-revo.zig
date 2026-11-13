// =====================================================================
// Des: The revoke command: takes back only what this app added. It removes public access to the service and logs out the gcloud account that the app itself logged in. Nothing is deleted.
// Flo: no --go: say what would happen > --go: drop allUsers invoker > gcloud auth revoke (only if the app made the login) > mark the steps open again
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, live flag
// Out: exit code
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const runs = @import("ap-runs.zig");

const CF = .{ .exitOkay = 0, .exitFail = 1, .valApp = "app" };

pub fn revoke(ctx: *ctxm.Ctx, live: bool) !u8 {
    const cfg = ctx.conf;
    const pid = ctx.projId();
    const fromApp = std.mem.eql(u8, ctx.st.valu("logi_from"), CF.valApp);
    if (!live) {
        ctx.say("dry-run: would remove public access to {s}{s}\nPass --go to do it.\n", .{ cfg.goog.serv, if (fromApp) " and log out the gcloud account the app logged in" else "" });
        return CF.exitOkay;
    }
    if (pid.len != 0) {
        const name = try runs.svcName(ctx.a, pid, cfg.goog.regi, cfg.goog.serv);
        const changed = runs.publDrop(ctx.gcp, cfg.apis.runz, name) catch |erro| {
            ctx.say("could not remove public access: {s}\n", .{@errorName(erro)});
            return CF.exitFail;
        };
        ctx.say("public access: {s}\n", .{if (changed) "removed" else "was not there"});
        try ctx.st.setz("serv-depl", .todo, "revoked: re-run to check", ctx.nowSecs());
    }
    if (fromApp) {
        if (try ctx.auth.who()) |acct| {
            const okay = try ctx.auth.revoke(acct);
            ctx.say("gcloud login for {s}: {s}\n", .{ acct, if (okay) "revoked" else "revoke failed" });
            if (okay) {
                try ctx.st.putz("logi_from", "");
                try ctx.st.setz("goog-logi", .todo, "revoked", ctx.nowSecs());
            }
        }
    }
    try ctx.st.save(ctx.io);
    return CF.exitOkay;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
