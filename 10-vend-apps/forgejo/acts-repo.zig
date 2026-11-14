// =====================================================================
// Des: The repo steps. Own ed25519 key for Forgejo, private repo with features off, protected main (no force push), a second push URL, and a drift check against the origin head.
// Flo: check > create if missing > verify; drift compares the Forgejo main head with `git ls-remote` of the origin
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Conf, State, Tool, Forg
// Out: Row list (4 rows) + driftChec
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const stat = @import("state-file.zig");
const engi = @import("step-engine.zig");
const tool = @import("tool-exec.zig");
const forg = @import("forg-adapter.zig");

const CF = .{ .keyzComm = "cloud-house for forgejo", .headMin = 40 };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    conf: *const conf.Conf,
    stat: *stat.Stat,
    tool: *tool.Tool,
    forg: *forg.Forg,

    // step 8: an ed25519 key just for Forgejo; make it if missing, upload if not already there
    pub fn sshKeyz(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const path = self.conf.sshz.file;
        const have = if (std.Io.Dir.accessAbsolute(self.tool.io, path, .{})) true else |_| false;
        if (!have) {
            if (std.fs.path.dirname(path)) |dirz| try std.Io.Dir.cwd().createDirPath(self.tool.io, dirz);
            const made = try self.tool.runz(&.{ self.conf.tool.sshk, "-t", "ed25519", "-f", path, "-N", "", "-C", CF.keyzComm }, null);
            if (!made.okay()) return error.SshKeyMake;
        }
        const publ = try self.tool.runz(&.{ self.conf.tool.sshk, "-y", "-f", path }, null);
        if (!publ.okay()) return error.SshKeyRead;
        const keys = try self.forg.keysList();
        for (keys) |item| if (std.mem.startsWith(u8, publ.text(), std.mem.trim(u8, item.key, " \r\n")) or std.mem.startsWith(u8, std.mem.trim(u8, item.key, " \r\n"), publ.text())) {
            self.stat.data.idsz.keyzIden = item.id;
            return .{ .okay = "key already uploaded" };
        };
        self.stat.data.idsz.keyzIden = try self.forg.keysAddz(self.conf.sshz.titl, publ.text());
        return .{ .okay = "key uploaded" };
    }

    // step 9: the repo (private unless frep.visi says public), then the off-by-default settings
    pub fn repoMake(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const owne = self.stat.data.idsz.adminUser;
        if (owne.len == 0) return error.NoAdmin;
        const name = self.conf.frep.name;
        const foun = try self.forg.repoFind(owne, name);
        const want_priv = !std.mem.eql(u8, self.conf.frep.visi, "public");
        const repo = foun orelse try self.forg.repoMake(name, want_priv, self.conf.repo.bran);
        if (repo.private != want_priv) return error.VisibilityDiffers; // never change visibility of an existing repo
        _ = try self.forg.repoEdit(owne, name, self.conf.frep.sett);
        self.stat.data.idsz.repoIden = repo.id;
        self.stat.data.idsz.repoPath = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ owne, name });
        return .{ .okay = self.stat.data.idsz.repoPath };
    }

    // step 10: protect main, no force push
    pub fn protMain(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const owne = self.stat.data.idsz.adminUser;
        const name = self.conf.frep.name;
        if (try self.forg.protFind(owne, name, self.conf.repo.bran)) |_| return .{ .okay = "already protected" };
        const prot = try self.forg.protMake(owne, name, self.conf.repo.bran, self.conf.prot);
        if (prot.enable_force_push) return error.ForcePushOn;
        return .{ .okay = "protected" };
    }

    // step 11: add Forgejo as an extra push url; origin keeps its own
    pub fn pushUrlz(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const path = self.stat.data.idsz.repoPath;
        if (path.len == 0) return error.NoRepo;
        const pars = [_]conf.Pair{ .{ "pubh", self.conf.host.pubh }, .{ "sshp", try std.fmt.allocPrint(self.gpa, "{d}", .{self.conf.host.sshp}) }, .{ "path", path } };
        const urlz = try conf.tmplFill(self.gpa, self.conf.repo.push, &pars);
        const list = try self.tool.runz(&.{ self.conf.tool.gitz, "remote", "get-url", "--push", "--all", self.conf.repo.remo }, self.conf.repo.path);
        if (list.okay() and std.mem.indexOf(u8, list.outz, urlz) != null) return .{ .okay = "already added" };
        // no explicit push url yet: pin the origin url first so pushes still reach it
        const expl = try self.tool.runz(&.{ self.conf.tool.gitz, "config", "--get-all", try std.fmt.allocPrint(self.gpa, "remote.{s}.pushurl", .{self.conf.repo.remo}) }, self.conf.repo.path);
        if (expl.text().len == 0) {
            const orig = try self.tool.runz(&.{ self.conf.tool.gitz, "remote", "get-url", self.conf.repo.remo }, self.conf.repo.path);
            if (!orig.okay()) return error.OriginUrlRead;
            const pin = try self.tool.runz(&.{ self.conf.tool.gitz, "remote", "set-url", "--add", "--push", self.conf.repo.remo, orig.text() }, self.conf.repo.path);
            if (!pin.okay()) return error.PushUrlFail;
        }
        const push = try self.tool.runz(&.{ self.conf.tool.gitz, "remote", "set-url", "--add", "--push", self.conf.repo.remo, urlz }, self.conf.repo.path);
        if (!push.okay()) return error.PushUrlFail;
        self.stat.data.idsz.pushUrlz = urlz;
        return .{ .okay = urlz };
    }

    // drift: is the Forgejo main head the same commit as the origin main head
    pub fn driftChec(self: *Ctx) !engi.Done {
        const owne = self.stat.data.idsz.adminUser;
        const mine = try self.forg.branHead(owne, self.conf.frep.name, self.conf.repo.bran) orelse return .{ .skip = "forgejo has no main yet" };
        const refz = try std.fmt.allocPrint(self.gpa, "refs/heads/{s}", .{self.conf.repo.bran});
        const lsrm = try self.tool.runz(&.{ self.conf.tool.gitz, "ls-remote", self.conf.repo.remo, refz }, self.conf.repo.path);
        if (!lsrm.okay() or lsrm.text().len < CF.headMin) return error.OriginHeadRead;
        const orig = lsrm.text()[0..CF.headMin];
        if (!std.mem.eql(u8, mine, orig)) return error.Drift;
        return .{ .okay = "heads match" };
    }
};

pub fn rows(ctx: *Ctx) [4]engi.Row {
    return .{
        .{ .iden = "rep-ssh-key", .name = "own ed25519 key for Forgejo", .runz = Ctx.sshKeyz, .ctx = ctx },
        .{ .iden = "rep-make", .name = "repo (visibility from config), features off", .runz = Ctx.repoMake, .ctx = ctx },
        .{ .iden = "rep-prot-main", .name = "protect main, no force push", .runz = Ctx.protMain, .ctx = ctx },
        .{ .iden = "rep-push-url", .name = "add Forgejo as a second push url", .runz = Ctx.pushUrlz, .ctx = ctx },
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
