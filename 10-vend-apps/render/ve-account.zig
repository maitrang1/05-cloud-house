// =====================================================================
// Des: Steps 1-3: the two hand jobs (sign up, paste one API key) and finding the workspace id.
// Flo: sign: show the page, wait for g > key: ask hidden, vault, prove with GET /owners > owner: save its id
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx
// Out: engine Done values; key in the vault, owner id in the state file
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const engi = @import("co-engine.zig");
const ctxz = @import("co-ctx.zig");
const rend = @import("ap-render.zig");

const Ctx = ctxz.Ctx;

// the sign-up page cannot be detected by API, so the human types g
fn never(raw: *anyopaque) anyerror!bool {
    _ = raw;
    return false;
}

fn signForm(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    _ = gpa;
    if (c.vaul.getz(c.conf.vaul.keyz) != null) return .{ .skip = "api key already vaulted, no sign-up needed" };
    return .{ .wait = .{ .urlz = c.conf.rend.sign, .line = .{ "Click the GitHub button to sign up. No card needed.", "Already have an account? Just log in.", "When you see the dashboard, type g." }, .poll = never, .ctx = c } };
}

fn keyzAsk(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    _ = gpa;
    var asked = false;
    if (c.vaul.getz(c.conf.vaul.keyz) == null) {
        if (c.conf.guid.open) _ = osyz.urlzOpen(c.io, c.gpa, c.conf.rend.keyp);
        osyz.outz(c.io, "  open: {s}\n  Account Settings > API Keys > Create API Key. Copy it.\n", .{c.conf.rend.keyp});
        const line = c.inpu.hidd("  paste the API key (hidden): ") orelse return error.NoKey;
        if (!std.mem.startsWith(u8, line, c.conf.rend.keyf)) return error.KeyForm;
        try c.vaul.putz(c.conf.vaul.keyz, line);
        asked = true;
    }
    c.rend.toke = c.vaul.getz(c.conf.vaul.keyz).?;
    _ = c.rend.owner("") catch |erro| {
        if (erro == error.RendAuth) {
            try c.vaul.drop(c.conf.vaul.keyz);
            osyz.errz("  the key was refused ({s}): it is removed from the vault, run again with a fresh key\n", .{c.rend.mess});
            return error.KeyBad;
        }
        return erro;
    };
    return if (asked) .{ .askd = "key vaulted and accepted" } else .{ .okay = "key accepted" };
}

fn owneFind(c: *Ctx, gpa: std.mem.Allocator) anyerror!engi.Done {
    const owne = try c.rend.owner(c.conf.rend.owne);
    c.stat.data.idsz.owneId = try gpa.dupe(u8, owne.id);
    return .{ .okay = try std.fmt.allocPrint(gpa, "workspace {s}", .{owne.name}) };
}

pub fn rows(ctx: *Ctx) [3]engi.Row {
    return .{
        ctxz.row(ctx, "sign-form", "Sign up with GitHub login (hand job 1)", true, signForm),
        ctxz.row(ctx, "keyz-ask", "Create and paste one API key (hand job 2)", true, keyzAsk),
        ctxz.row(ctx, "owne-find", "Find the workspace id", false, owneFind),
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
