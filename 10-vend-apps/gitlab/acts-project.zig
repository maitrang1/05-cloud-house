// =====================================================================
// Des: Steps 7-11: own SSH key for GitLab, create the private project, turn off runners/CI/registry/wiki, protect main, and add GitLab as a second push URL.
// Flo: make/read ed25519 key > upload it > create (or find) the project > edit settings > protect main > extra push remote
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, vault, gitl adapter, state, tool runner)
// Out: Row list for the engine; state holds the project id, vault holds the key path
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const vaul = @import("vault-file.zig");
const stat = @import("state-file.zig");
const engi = @import("step-engine.zig");
const tool = @import("tool-exec.zig");
const gitl = @import("gitl-adapter.zig");

pub fn usagText(gpa: std.mem.Allocator, used: u64, lim: anytype) ![]const u8 {
    const pct: u64 = used * 100 / lim.stor;
    const flag: []const u8 = if (pct >= lim.warn) " WARN: near the cap, move big files to Releases" else "";
    return std.fmt.allocPrint(gpa, "usage: storage {d} of {d} MiB ({d}%){s}; CI off (free {d} min/mo untouched); mirrors max {d}, users max {d}", .{ used >> 20, lim.stor >> 20, pct, flag, lim.cimn, lim.mirx, lim.usrx });
}

test "usagText shows the percent and warns past the limit" {
    const gpa = std.testing.allocator;
    const lim = .{ .stor = @as(u64, 1000) << 20, .warn = @as(u32, 80), .cimn = @as(u32, 400), .mirx = @as(u32, 10), .usrx = @as(u32, 5) };
    const low = try usagText(gpa, 10 << 20, lim);
    defer gpa.free(low);
    try std.testing.expect(std.mem.indexOf(u8, low, "(1%)") != null and std.mem.indexOf(u8, low, "WARN") == null);
    const hi = try usagText(gpa, @as(u64, 900) << 20, lim);
    defer gpa.free(hi);
    try std.testing.expect(std.mem.indexOf(u8, hi, "WARN") != null);
}

const CF = .{ .vaulGlProj = "gitl.proj_path", .keyzComm = "cloud-house for gitlab" };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    conf: *const conf.Conf,
    vaul: *vaul.Vaul,
    stat: *stat.Stat,
    tool: *tool.Tool,
    gitl: *gitl.Gitl,

    // step 7: an ed25519 key just for GitLab; make it if missing, upload if not already there
    pub fn sshKeyz(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const path = self.conf.sshz.file;
        const have = if (std.Io.Dir.accessAbsolute(self.tool.io, path, .{})) true else |_| false;
        if (!have) _ = try self.tool.runz(&.{ self.conf.tool.sshk, "-t", "ed25519", "-f", path, "-N", "", "-C", CF.keyzComm }, null);
        const publ = try self.tool.runz(&.{ self.conf.tool.sshk, "-y", "-f", path }, null);
        if (!publ.okay()) return error.SshKeyRead;
        const keys = try self.gitl.keysList();
        for (keys) |item| if (std.mem.eql(u8, item.key, publ.text())) return .{ .okay = "already uploaded" };
        _ = try self.gitl.keysAddz(self.conf.sshz.titl, publ.text());
        _ = gpa;
        return .{ .okay = "key uploaded" };
    }

    // step 8-9: create the project (or find it, on a re-run), then apply the off-by-default settings
    pub fn projMake(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const user = self.vaul.getz("gitl.user") orelse return error.NoUsername;
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ user, self.conf.gitl.proj });
        var json: std.json.Value = undefined;
        if (try self.gitl.projFind(path)) |foun| {
            json = foun;
        } else {
            json = try self.gitl.projMake(self.conf.gitl.proj, self.conf.gitl.visi, self.conf.repo.bran);
        }
        const iden = json.object.get("id").?.integer;
        self.stat.data.idsz.glProj = @intCast(iden);
        try self.vaul.putz(CF.vaulGlProj, path);
        _ = try self.gitl.projEdit(@intCast(iden), self.conf.gitl.sett);
        return .{ .okay = path };
    }

    // free-tier line: storage vs the 10 GiB per-project cap, CI minutes left at 0 spend, warn past limi.warn %
    pub fn usagLine(self: *Ctx, gpa: std.mem.Allocator) ![]const u8 {
        const path = self.vaul.getz(CF.vaulGlProj) orelse return try gpa.dupe(u8, "usage: project not made yet");
        const foun = (try self.gitl.projFind(path)) orelse return try gpa.dupe(u8, "usage: project not found");
        var used: u64 = 0;
        if (foun.object.get("statistics")) |sta| if (sta == .object) if (sta.object.get("storage_size")) |sz| if (sz == .integer) {
            used = @intCast(sz.integer);
        };
        return usagText(gpa, used, self.conf.limi);
    }

    // step 10: protect main, no force push
    pub fn protMain(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const iden = self.stat.data.idsz.glProj;
        if (iden == 0) return error.NoProject;
        if (try self.gitl.protFind(iden, self.conf.repo.bran)) |_| return .{ .okay = "already protected" };
        _ = try self.gitl.protMake(iden, self.conf.repo.bran, self.conf.prot.push, self.conf.prot.merg, self.conf.prot.forc);
        return .{ .okay = "protected" };
    }

    // step 11: add GitLab as an extra push url, github url must already be first
    pub fn pushUrlz(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const path = self.vaul.getz(CF.vaulGlProj) orelse return error.NoProject;
        const urlz = try std.fmt.allocPrint(self.gpa, "git@{s}:{s}.git", .{ self.conf.gitl.host, path });
        const list = try self.tool.runz(&.{ self.conf.tool.gitz, "remote", "get-url", "--all", self.conf.repo.remo }, self.conf.repo.path);
        if (list.okay() and std.mem.indexOf(u8, list.outz, urlz) != null) return .{ .okay = "already added" };
        const push = try self.tool.runz(&.{ self.conf.tool.gitz, "remote", "set-url", "--add", "--push", self.conf.repo.remo, urlz }, self.conf.repo.path);
        if (!push.okay()) return error.PushUrlFail;
        return .{ .okay = urlz };
    }
};

pub fn rows(ctx: *Ctx) [4]engi.Row {
    return .{
        .{ .iden = "prj-ssh-key", .name = "own ed25519 key for GitLab", .runz = Ctx.sshKeyz, .ctx = ctx },
        .{ .iden = "prj-make", .name = "create project (visibility from config), settings off", .runz = Ctx.projMake, .ctx = ctx },
        .{ .iden = "prj-prot-main", .name = "protect main, no force push", .runz = Ctx.protMain, .ctx = ctx },
        .{ .iden = "prj-push-urlz", .name = "add GitLab as a second push url", .runz = Ctx.pushUrlz, .ctx = ctx },
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
