// =====================================================================
// Des: Steps 0-6 of the GitLab setup: read GitHub identity from the vault, pick a free username, guide the sign-up and email hand jobs, run device login, read who the token belongs to.
// Flo: read vault > free-username check > guided sign-up > guided email (if needed) > device login (hand job) > read /user > save commit-privacy email
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, vault, gitl adapter, state); each step reads/writes the vault and state
// Out: Row list for the engine; on success the vault holds the GitLab token, state holds the user id
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const vaul = @import("vault-file.zig");
const stat = @import("state-file.zig");
const engi = @import("step-engine.zig");
const gitl = @import("gitl-adapter.zig");

const CF = .{ .vaulGhUser = "gith.user", .vaulGhMail = "gith.mail", .vaulGlUser = "gitl.user", .vaulGlToke = "gitl.token", .vaulGlRefr = "gitl.refresh", .vaulOautCli = "oaut.clid" };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    conf: *const conf.Conf,
    vaul: *vaul.Vaul,
    stat: *stat.Stat,
    gitl: *gitl.Gitl,
    devi: ?gitl.Devi = null,

    // step 1: read GitHub login from the vault; a skip (not a failure) when the GitHub app never ran
    pub fn readGith(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        _ = gpa;
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const ghUs = self.vaul.getz(CF.vaulGhUser) orelse return engi.skipAlwa("no GitHub login in the vault; run the GitHub app first");
        return .{ .okay = ghUs };
    }

    // step 2: pick the username (GitHub login first), check it is free
    pub fn freeName(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const want = self.vaul.getz(CF.vaulGhUser) orelse self.conf.gitl.user;
        if (want.len == 0) return error.NoUsername;
        if (try self.gitl.userFind(want)) |_| return error.UsernameTaken;
        try self.vaul.putz(CF.vaulGlUser, want);
        _ = gpa;
        return .{ .okay = want };
    }

    // step 3: guided sign-up; detected once the public lookup finds the username
    pub fn signUpzz(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const name = self.vaul.getz(CF.vaulGlUser) orelse return error.NoUsername;
        return pollDone(self, gpa, self.conf.gitl.sign, struct {
            fn f(c: *anyopaque) anyerror!bool {
                const inner: *Ctx = @ptrCast(@alignCast(c));
                const want = inner.vaul.getz(CF.vaulGlUser) orelse return false;
                return (try inner.gitl.userFind(want)) != null;
            }
        }.f, .{ "Press \"Continue with GitHub\" (or fill the form).", "Click the email link if asked.", name });
    }

    // step 4: guided email link. No token exists yet at this point (device login is
    // next), so there is no API call that can detect "confirmed" here — the human
    // types `g` once the link is clicked, or once GitHub sign-in skipped it entirely.
    pub fn emailLink(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        _ = gpa;
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        return .{
            .wait = .{
                .line = .{ "Open your inbox and click the GitLab link, if one arrived.", "Type g once done, or if GitHub sign-in skipped this.", "" },
                .poll = struct {
                    fn f(c: *anyopaque) anyerror!bool {
                        _ = c;
                        return false; // never auto-detected; the human always types g here
                    }
                }.f,
                .ctx = self,
            },
        };
    }

    // step 5: device login; the token lands in the vault, never printed
    pub fn deviLogi(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const clid = self.conf.oaut.clid;
        if (clid.len == 0) return error.NoClientId;
        if (self.devi == null) self.devi = try self.gitl.deviStar(clid, self.conf.oaut.scop);
        const devi = self.devi.?;
        return pollDone(self, gpa, devi.verification_uri_complete orelse devi.verification_uri, struct {
            fn f(c: *anyopaque) anyerror!bool {
                const inner: *Ctx = @ptrCast(@alignCast(c));
                const poll = try inner.gitl.deviPoll(inner.conf.oaut.clid, inner.devi.?.device_code);
                switch (poll) {
                    .okay => |toke| {
                        inner.gitl.toke = try inner.gpaCopy(toke.access_token);
                        try inner.vaul.putz(CF.vaulGlToke, toke.access_token);
                        if (toke.refresh_token) |refr| try inner.vaul.putz(CF.vaulGlRefr, refr);
                        return true;
                    },
                    .pend, .slow => return false,
                    .deny => return error.LoginDenied,
                    .expi => return error.LoginExpired,
                }
            }
        }.f, .{ "Type the code shown, then approve.", devi.user_code, "" });
    }

    // step 6: read identity, build the commit-privacy email, save it
    pub fn readSelf(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        _ = gpa;
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, self.gitl.toke, "")) self.gitl.toke = self.vaul.getz(CF.vaulGlToke) orelse return error.NoToken;
        const self1 = try self.gitl.userSelf();
        const mail = self1.commit_email orelse self1.email orelse return error.NoEmail;
        try self.vaul.putz(CF.vaulGhMail, mail);
        self.stat.data.idsz.glUsid = self1.id;
        self.stat.data.idsz.glMail = try self.gpaCopy(mail);
        return .{ .okay = mail };
    }

    fn gpaCopy(self: *Ctx, text: []const u8) ![]const u8 {
        return self.gpa.dupe(u8, text);
    }

    // shared guided-step helper: open url (if any), poll, mark the step done on success
    fn pollDone(self: *Ctx, gpa: std.mem.Allocator, urlz: ?[]const u8, pollFn: *const fn (c: *anyopaque) anyerror!bool, line: [3][]const u8) !engi.Done {
        _ = gpa;
        return .{ .wait = .{ .urlz = urlz, .line = line, .poll = pollFn, .ctx = self } };
    }
};

// the ordered rows for steps 0-6 (step 0 preflight is engine-level, not here)
pub fn rows(ctx: *Ctx) [5]engi.Row {
    return .{
        .{ .iden = "acc-read-gith", .name = "read GitHub identity from the vault", .runz = Ctx.readGith, .ctx = ctx },
        .{ .iden = "acc-free-name", .name = "pick a free GitLab username", .runz = Ctx.freeName, .ctx = ctx },
        .{ .iden = "acc-sign-up", .name = "sign up (hand job)", .hand = true, .runz = Ctx.signUpzz, .ctx = ctx },
        .{ .iden = "acc-email", .name = "confirm email, if asked (hand job)", .hand = true, .runz = Ctx.emailLink, .ctx = ctx },
        .{ .iden = "acc-devi-logi", .name = "device login (hand job)", .hand = true, .runz = Ctx.deviLogi, .ctx = ctx },
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
