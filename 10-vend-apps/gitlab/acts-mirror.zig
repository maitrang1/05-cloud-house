// =====================================================================
// Des: Steps 12-15: make the project access token, hand it to GitHub as a sealed secret, write the mirror workflow and kill-switch variable, rotate the token before it expires, and report drift.
// Flo: make GitLab token > vault it > seal to GitHub > commit the workflow file > set MIRROR_ON > check the run > rotate if due
// Cre: 2026-11-12                          - | Mod: 2026-11-12 (aaa audit: toke.role, not prot.push, for atokMake)
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, vault, gitl + gith adapters, state, tool runner, io for dates)
// Out: Row list for the engine; vault holds the mirror token id + expiry, GitHub gets the secret
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const vaul = @import("vault-file.zig");
const stat = @import("state-file.zig");
const engi = @import("step-engine.zig");
const date = @import("date-math.zig");
const gitl = @import("gitl-adapter.zig");
const gith = @import("gith-adapter.zig");

const CF = .{ .vaulMirr = "gitl.mirror_token" };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conf: *const conf.Conf,
    vaul: *vaul.Vaul,
    stat: *stat.Stat,
    gitl: *gitl.Gitl,
    gith: *gith.Gith,

    // step 12: make the project access token, scope write_repository, Developer role, 90 days
    pub fn tokeMake(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        _ = gpa;
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const iden = self.stat.data.idsz.glProj;
        if (iden == 0) return error.NoProject;
        if (self.stat.data.idsz.tokeIden != 0) return .{ .okay = "already made" };
        const expi = date.datePlus(@divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000), self.conf.toke.days);
        const atok = try self.gitl.atokMake(iden, self.conf.toke.name, self.conf.toke.scop, self.conf.toke.role, &expi);
        try self.vaul.putz(CF.vaulMirr, atok.token.?);
        self.stat.data.idsz.tokeIden = atok.id;
        self.stat.data.idsz.tokeExpi = try self.gpaCopy(&expi);
        return .{ .okay = "token made" };
    }

    // step 13: hand the token to GitHub as a sealed secret, write the mirror workflow, set the kill switch
    pub fn mirrGith(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const toke = self.vaul.getz(CF.vaulMirr) orelse return error.NoMirrorToken;
        try self.gith.secrPutz(self.conf.gith.secr, toke);
        self.stat.data.idsz.secrIden = self.stat.data.idsz.secrIden + 1;
        if ((try self.gith.varzGetz(self.conf.gith.varz)) == null) try self.gith.varzMake(self.conf.gith.varz, "1");
        const wrote = try self.flowWrite(gpa);
        return .{ .okay = if (wrote) "secret + variable set, workflow written (publish commits it)" else "secret + variable set, workflow already in place" };
    }

    // the mirror workflow in the copy folder: filled from the template, written only when it differs; `github publish` commits and pushes it
    fn flowWrite(self: *Ctx, gpa: std.mem.Allocator) !bool {
        const raw = std.Io.Dir.cwd().readFileAlloc(self.io, self.conf.gith.tmpl, gpa, .limited(64 * 1024)) catch return error.TemplateMissing;
        const path = self.vaul.getz("gitl.proj_path") orelse return error.NoProject;
        const text = try conf.tmplFill(gpa, raw, &.{ .{ "branch", self.conf.repo.bran }, .{ "varz", self.conf.gith.varz }, .{ "secr", self.conf.gith.secr }, .{ "ping", self.conf.gith.ping }, .{ "host", self.conf.gitl.host }, .{ "path", path } });
        const dest = try std.fs.path.join(gpa, &.{ self.conf.repo.path, self.conf.gith.flow });
        const have = std.Io.Dir.cwd().readFileAlloc(self.io, dest, gpa, .limited(256 * 1024)) catch null;
        if (have != null and std.mem.eql(u8, have.?, text)) return false;
        if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(self.io, d);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = dest, .data = text });
        return true;
    }

    // step 14: rotate 14 days before expiry
    pub fn rotaToke(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        _ = gpa;
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const iden = self.stat.data.idsz.glProj;
        const tide = self.stat.data.idsz.tokeIden;
        if (iden == 0 or tide == 0) return error.NoToken;
        const nowz = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
        if (!(try date.rotaDuez(self.stat.data.idsz.tokeExpi, nowz, self.conf.toke.rota))) return .{ .okay = "not due" };
        const expi = date.datePlus(nowz, self.conf.toke.days);
        const next = try self.gitl.atokMake(iden, self.conf.toke.name, self.conf.toke.scop, self.conf.toke.role, &expi);
        try self.gith.secrPutz(self.conf.gith.secr, next.token.?);
        try self.vaul.putz(CF.vaulMirr, next.token.?);
        try self.gitl.atokDele(iden, tide);
        self.stat.data.idsz.tokeIden = next.id;
        self.stat.data.idsz.tokeExpi = try self.gpaCopy(&expi);
        return .{ .okay = "rotated" };
    }

    // step 15: drift check — does GitHub's last mirror run exist and succeed
    pub fn driftChec(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        _ = gpa;
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const runz = (try self.gith.runzLast(self.conf.gith.flow)) orelse return .{ .skip = "mirror has not run yet" };
        if (!std.mem.eql(u8, runz.conclusion orelse "", "success")) return error.MirrorFailed;
        self.stat.data.idsz.pingSent = true;
        return .{ .okay = "mirror run is green" };
    }

    fn gpaCopy(self: *Ctx, text: []const u8) ![]const u8 {
        return self.gpa.dupe(u8, text);
    }
};

pub fn rows(ctx: *Ctx) [4]engi.Row {
    return .{
        .{ .iden = "mir-toke-make", .name = "project access token, write_repository, 90 days", .runz = Ctx.tokeMake, .ctx = ctx },
        .{ .iden = "mir-gith-secr", .name = "hand GitHub the sealed mirror secret", .runz = Ctx.mirrGith, .ctx = ctx },
        .{ .iden = "mir-rota-toke", .name = "rotate the token if due", .runz = Ctx.rotaToke, .ctx = ctx },
        .{ .iden = "mir-drift", .name = "drift check: mirror run green", .runz = Ctx.driftChec, .ctx = ctx },
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
