// =====================================================================
// Des: Steps 1-3: sign-up (hand), API token (hand, vaulted), find the account id.
// Flo: check vault > guide the human > verify token by one call > save ids
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: shared run context
// Out: engine rows
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const engi = @import("co-engine.zig");
const ctxz = @import("co-ctx.zig");

const Ctx = ctxz.Ctx;

// the sign-up page cannot be detected by API, so the human types g
fn never(raw: *anyopaque) anyerror!bool {
    _ = raw;
    return false;
}

fn signForm(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    _ = gpa;
    if (c.vaul.getz(c.conf.vaul.keyz) != null) return .{ .skip = "token already vaulted, no sign-up needed" };
    return .{ .wait = .{ .urlz = c.conf.cfla.sign, .line = .{ "Sign up (no card needed) and click the link in the email.", "Already have an account? Just log in.", "When you see the dashboard, type g." }, .poll = never, .ctx = c } };
}

fn tokeAsk(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    _ = gpa;
    var asked = false;
    if (c.vaul.getz(c.conf.vaul.keyz) == null) {
        if (c.conf.guid.open) _ = osyz.urlzOpen(c.io, c.gpa, c.conf.cfla.keyp);
        osyz.outz(c.io, "  open: {s}\n  Create Token > Create Custom Token. Permissions: Account / Workers Scripts / Edit and Account / Account Settings / Read. Copy the token.\n", .{c.conf.cfla.keyp});
        const line = c.inpu.hidd("  paste the API token (hidden): ") orelse return error.NoKey;
        if (line.len < c.conf.cfla.minl) return error.KeyForm;
        try c.vaul.putz(c.conf.vaul.keyz, line);
        asked = true;
    }
    c.cfla.toke = c.vaul.getz(c.conf.vaul.keyz).?;
    const proof: ?anyerror = blk: {
        if (c.conf.cfla.acco.len > 0) {
            _ = c.cfla.subGet(c.conf.cfla.acco) catch |erro| break :blk erro;
        } else {
            _ = c.cfla.account("") catch |erro| break :blk erro;
        }
        break :blk null;
    };
    if (proof) |erro| {
        if (erro == error.CflaAuth) {
            try c.vaul.drop(c.conf.vaul.keyz);
            osyz.errz("  the token was refused ({s}): it is removed from the vault, run again with a fresh token\n", .{c.cfla.mess});
            return error.KeyBad;
        }
        return erro;
    }
    return if (asked) .{ .askd = "token vaulted and accepted" } else .{ .okay = "token accepted" };
}

fn accoFind(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const acco = try c.cfla.account(c.conf.cfla.acco);
    c.stat.data.idsz.acctId = try gpa.dupe(u8, acco.id);
    return .{ .okay = try std.fmt.allocPrint(gpa, "account {s}", .{if (acco.name.len > 0) acco.name else acco.id}) };
}

pub fn rows(ctx: *Ctx) [3]engi.Row {
    return .{
        ctxz.row(ctx, "sign-form", "Sign up and verify email (hand job 1)", true, signForm),
        ctxz.row(ctx, "toke-ask", "Create and paste one API token (hand job 2)", true, tokeAsk),
        ctxz.row(ctx, "acco-find", "Find the account id", false, accoFind),
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
