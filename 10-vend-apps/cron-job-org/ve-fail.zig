// =====================================================================
// Des: Turns a vendor reply or a call error into the three-line failure the engine prints (what / why / fix). One place for every vendor error rule: dead key, locked IP, rate limit, daily limit, refused job.
// Flo: reply code > pick what/why/fix > on a dead key: drop it from the vault and reopen the key step
// Inp: Ctx, Reply or error, a short label of the call
// Out: Outc.fail (or the error itself when it is not one we explain)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const cron = @import("ap-cron.zig");

const Ctx = ctxm.Ctx;
const Outc = engi.Outc;

const CF = .{ .codeKey = 401, .codeLock = 403, .codeLimi = 429, .codeBad = 400, .codeGone = 404, .idenKeyz = "keyz-make", .exitHand = 4, .exitFail = 1 };

// a vault error as a failure
pub fn vaulFail(erro: anyerror) ?engi.Fail {
    return switch (erro) {
        error.VaulWeak => .{ .what = "vault passphrase not accepted", .why = "it is empty or shorter than 8 characters", .fix = "use a longer passphrase (env var vaul.envz or the prompt)" },
        error.VaulPass => .{ .what = "vault would not open", .why = "wrong passphrase, or the vault file was changed", .fix = "type the passphrase you used first; the vault file is never overwritten" },
        error.VaulForm => .{ .what = "vault file is damaged", .why = "it is not in the vault format", .fix = "restore it from a copy; move it away to start a new vault" },
        error.NoPassphrase => .{ .what = "no vault passphrase", .why = "the env var is empty and nothing was typed", .fix = "set the env var named in vaul.envz, or run in a terminal" },
        else => null,
    };
}

// a vault error in a read-only command: say it in three lines, exit 1; any other error goes on up
pub fn vaulExit(ctx: *Ctx, erro: anyerror) !u8 {
    const one = vaulFail(erro) orelse return erro;
    ctx.say("failed: {s}\nwhy: {s}\nfix: {s}\n", .{ one.what, one.why, one.fix });
    return CF.exitFail;
}

// a non-2xx reply as a failure; a dead key is dropped so the next run asks for a new one
pub fn replFail(ctx: *Ctx, rep: cron.Reply, what: []const u8) !Outc {
    const text = rep.errText();
    switch (rep.code) {
        CF.codeKey => {
            if (ctx.vlt != null) {
                const vlt = try ctx.vault();
                try vlt.drop(ctx.conf.vaul.keya);
            }
            ctx.cron.key = "";
            try ctx.st.setz(CF.idenKeyz, .todo, "key refused", ctx.nowSecs());
            try ctx.handDrop(CF.idenKeyz);
            return .{ .fail = .{ .what = what, .why = try std.fmt.allocPrint(ctx.a, "the API key was refused (HTTP 401: {s})", .{text}), .fix = "run again: it asks for a new key (Console > Settings > API)", .code = CF.exitHand } };
        },
        CF.codeLock => return .{ .fail = .{ .what = what, .why = try std.fmt.allocPrint(ctx.a, "HTTP 403: the key may be locked to other IPs ({s})", .{text}), .fix = "allow this IP in Console > Settings > API, or remove the lock, then re-run" } },
        CF.codeLimi => return .{ .fail = .{ .what = what, .why = "HTTP 429: rate or daily limit (100 requests/day, create 5/min)", .fix = "wait a minute (or until the next UTC day), then re-run" } },
        CF.codeBad => return .{ .fail = .{ .what = what, .why = try std.fmt.allocPrint(ctx.a, "the vendor refused the job (HTTP 400: {s})", .{text}), .fix = "check the jobz, noti and tick settings in 00-config.json" } },
        else => return .{ .fail = .{ .what = what, .why = try std.fmt.allocPrint(ctx.a, "HTTP {d}: {s}", .{ rep.code, text }), .fix = "see the audit log, then re-run" } },
    }
}

// the daily-limit error as a failure; any other error goes on up
pub fn callFail(ctx: *Ctx, erro: anyerror, what: []const u8) anyerror!Outc {
    if (erro == error.QuotaDay) return .{ .fail = .{ .what = what, .why = try std.fmt.allocPrint(ctx.a, "the daily request limit is used up ({d} of {d})", .{ ctx.cron.used(), ctx.conf.limi.dayl }) , .fix = "wait for the next UTC day; raise limi.dayl only with a sustaining membership" } };
    return erro;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
