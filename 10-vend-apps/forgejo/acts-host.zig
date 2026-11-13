// =====================================================================
// Des: The host steps. Make the service user, fetch + verify the Forgejo binary, write app.ini (SQLite, registration off), write the systemd unit, wait until the server answers. Runs on the Linux host itself.
// Flo: check what exists > act only if missing > verify > never overwrite a file the owner may have edited
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Conf, State, Tool, Http, Forg
// Out: Row list (5 rows) for the step engine
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const conf = @import("config-load.zig");
const stat = @import("state-file.zig");
const engi = @import("step-engine.zig");
const tool = @import("tool-exec.zig");
const http = @import("http-call.zig");
const forg = @import("forg-adapter.zig");

const Sha = std.crypto.hash.sha2.Sha256;
const CF = .{ .sumsMaxz = 4096, .confMaxz = 1 << 20, .msecSecs = 1000 };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conf: *const conf.Conf,
    stat: *stat.Stat,
    tool: *tool.Tool,
    down: *http.Http, // big-body client for the binary
    forg: *forg.Forg,

    // the {name} fills every host template uses
    fn pair(self: *Ctx) ![]const conf.Pair {
        const host = self.conf.host;
        const list = try self.gpa.alloc(conf.Pair, 9);
        list[0] = .{ "svcu", host.svcu };
        list[1] = .{ "work", host.work };
        list[2] = .{ "bina", host.bina };
        list[3] = .{ "conf", host.conf };
        list[4] = .{ "pubh", host.pubh };
        list[5] = .{ "port", try std.fmt.allocPrint(self.gpa, "{d}", .{host.port}) };
        list[6] = .{ "sshp", try std.fmt.allocPrint(self.gpa, "{d}", .{host.sshp}) };
        list[7] = .{ "vers", self.conf.rele.vers };
        list[8] = .{ "arch", self.conf.rele.arch };
        return list;
    }

    fn exis(self: *Ctx, path: []const u8) bool {
        return if (std.Io.Dir.accessAbsolute(self.io, path, .{})) true else |_| false;
    }

    fn needLinx() !void {
        if (builtin.os.tag != .linux) return error.NeedLinux;
    }

    // make the folder that holds a file
    fn parentMake(self: *Ctx, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dirz| try std.Io.Dir.cwd().createDirPath(self.io, dirz);
    }

    // step 1: the service user
    pub fn userMake(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        try needLinx();
        const pars = try self.pair();
        const chek = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.chek, pars), null);
        if (chek.okay()) return .{ .okay = "service user exists" };
        const made = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.mkus, pars), null);
        if (!made.okay()) return error.UserMakeFail;
        return .{ .okay = "service user made" };
    }

    // first token of a "<hex>  <file>" line
    fn sumsHash(text: []const u8) ?[]const u8 {
        var iter = std.mem.tokenizeAny(u8, text, " \t\r\n");
        const frst = iter.next() orelse return null;
        return if (frst.len == Sha.digest_length * 2) frst else null;
    }

    // hex sha256 of some bytes
    fn hashHex(data: []const u8, buff: *[Sha.digest_length * 2]u8) []const u8 {
        var dige: [Sha.digest_length]u8 = undefined;
        Sha.hash(data, &dige, .{});
        return std.fmt.bufPrint(buff, "{x}", .{dige[0..]}) catch unreachable; // buffer is sized for the hex digest
    }

    // step 2: download the release, verify its checksum, install; skip when the installed file already matches
    pub fn binaFetc(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const pars = try self.pair();
        const file = try conf.tmplFill(self.gpa, self.conf.rele.file, pars);
        const urlz = try std.fmt.allocPrint(self.gpa, "{s}/v{s}/{s}", .{ self.conf.rele.base, self.conf.rele.vers, file });
        const sumz = try std.mem.concat(self.gpa, u8, &.{ urlz, self.conf.rele.sums });

        const sres = try self.down.call(.{ .urlz = sumz });
        if (!sres.okay()) return error.SumsFetchFail;
        const want = sumsHash(sres.body) orelse return error.SumsBad;

        var hbuf: [Sha.digest_length * 2]u8 = undefined;
        if (self.exis(self.conf.host.bina)) {
            const have = try std.Io.Dir.cwd().readFileAlloc(self.io, self.conf.host.bina, self.gpa, .limited(self.conf.rele.maxb));
            if (std.ascii.eqlIgnoreCase(hashHex(have, &hbuf), want)) {
                self.stat.data.idsz.binaSha = try self.gpa.dupe(u8, want);
                return .{ .okay = "binary already installed and matches" };
            }
            return error.BinaDiffers; // never overwrite a binary we did not verify
        }

        const bres = try self.down.call(.{ .urlz = urlz });
        if (!bres.okay()) return error.BinaFetchFail;
        if (!std.ascii.eqlIgnoreCase(hashHex(bres.body, &hbuf), want)) return error.SumMismatch;
        try self.parentMake(self.conf.host.bina);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.conf.host.bina, .data = bres.body });
        const chmo = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.chmo, pars), null);
        if (!chmo.okay()) return error.ChmodFail;
        self.stat.data.idsz.binaSha = try self.gpa.dupe(u8, want);
        return .{ .okay = "binary installed, checksum verified" };
    }

    // step 3: app.ini; an existing file is the owner's, so it is kept
    pub fn confWrit(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const pars = try self.pair();
        try std.Io.Dir.cwd().createDirPath(self.io, self.conf.host.work);
        try self.parentMake(self.conf.host.conf);
        const chow = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.chow, pars), null);
        if (!chow.okay()) return error.ChownFail;
        if (self.exis(self.conf.host.conf)) return .{ .okay = "app.ini exists, kept" };
        const text = try conf.linzFill(self.gpa, self.conf.ini, pars);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.conf.host.conf, .data = text });
        return .{ .okay = "app.ini written (SQLite, registration off)" };
    }

    // step 4: systemd unit, then enable + start
    pub fn unitWrit(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const pars = try self.pair();
        const text = try conf.linzFill(self.gpa, self.conf.unit, pars);
        var note: []const u8 = "unit written";
        if (self.exis(self.conf.host.unit)) {
            const have = try std.Io.Dir.cwd().readFileAlloc(self.io, self.conf.host.unit, self.gpa, .limited(CF.confMaxz));
            note = if (std.mem.eql(u8, have, text)) "unit already in place" else "unit exists with other text, kept";
        } else {
            try self.parentMake(self.conf.host.unit);
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.conf.host.unit, .data = text });
        }
        const reld = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.reld, pars), null);
        if (!reld.okay()) return error.ReloadFail;
        const enab = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.enab, pars), null);
        if (!enab.okay()) return error.EnableFail;
        if (self.conf.bkup.onzz) {
            try self.unitKeep(self.conf.bkup.svcf, try conf.linzFill(self.gpa, self.conf.bkup.svc, pars));
            try self.unitKeep(self.conf.bkup.tmrf, try conf.linzFill(self.gpa, self.conf.bkup.tmr, pars));
            const rl = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.cmds.reld, pars), null);
            if (!rl.okay()) return error.ReloadFail;
            const be = try self.tool.runz(try conf.argvFill(self.gpa, self.conf.bkup.enab, pars), null);
            if (!be.okay()) return error.EnableFail;
            note = try std.fmt.allocPrint(self.gpa, "{s}; nightly dump timer on", .{note});
        }
        return .{ .okay = note };
    }

    // write a unit file only when it is absent; an existing one is never touched
    fn unitKeep(self: *Ctx, path: []const u8, text: []const u8) !void {
        if (self.exis(path)) return;
        try self.parentMake(path);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = text });
    }

    // step 5: wait until the API answers
    pub fn bootWait(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        var left: u64 = self.conf.boot.wait;
        while (true) {
            if (self.forg.versGetz()) |vers| {
                return .{ .okay = try std.fmt.allocPrint(self.gpa, "server up, version {s}", .{vers.version}) };
            } else |_| {}
            if (left <= self.conf.boot.poll) return error.BootTime;
            left -= self.conf.boot.poll;
            std.Io.sleep(self.io, .fromMilliseconds(@as(i64, self.conf.boot.poll) * CF.msecSecs), .awake) catch return error.Canceled;
        }
    }
};

pub fn rows(ctx: *Ctx) [5]engi.Row {
    return .{
        .{ .iden = "hst-user", .name = "service user", .runz = Ctx.userMake, .ctx = ctx },
        .{ .iden = "hst-binary", .name = "fetch + verify the Forgejo binary", .runz = Ctx.binaFetc, .ctx = ctx },
        .{ .iden = "hst-config", .name = "write app.ini (SQLite, registration off)", .runz = Ctx.confWrit, .ctx = ctx },
        .{ .iden = "hst-unit", .name = "systemd unit, enable + start", .runz = Ctx.unitWrit, .ctx = ctx },
        .{ .iden = "hst-boot", .name = "wait until the API answers", .runz = Ctx.bootWait, .ctx = ctx },
    };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
