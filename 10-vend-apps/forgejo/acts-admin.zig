// =====================================================================
// Des: The admin steps. Create the admin user by CLI (random password, never kept) and mint one scoped access token by CLI into the vault. Also revoke: kill only the token the app made.
// Flo: check the user list > create if missing > mint the token if the vault has none > verify it against the API
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Conf, State, Vault, Tool, Forg
// Out: Row list (2 rows) + revoke
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const vaul = @import("vault-file.zig");
const stat = @import("state-file.zig");
const engi = @import("step-engine.zig");
const tool = @import("tool-exec.zig");
const forg = @import("forg-adapter.zig");

const CF = .{ .vaulToke = "forg.token", .passSize = 24, .passAlph = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789" };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conf: *const conf.Conf,
    vaul: *vaul.Vaul,
    stat: *stat.Stat,
    tool: *tool.Tool,
    forg: *forg.Forg,

    // the forgejo CLI call: [runa prefix] bina <args> --config conf
    fn cliArgv(self: *Ctx, args: []const []const u8) ![]const []const u8 {
        const pars = [_]conf.Pair{ .{ "svcu", self.conf.host.svcu }, .{ "bina", self.conf.host.bina } };
        const pref = try conf.argvFill(self.gpa, self.conf.cmds.runa, &pars);
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(self.gpa, pref);
        try list.append(self.gpa, self.conf.host.bina);
        try list.appendSlice(self.gpa, args);
        try list.appendSlice(self.gpa, &.{ "--config", self.conf.host.conf });
        return list.toOwnedSlice(self.gpa);
    }

    // true when the user list holds the name as its 2nd column
    fn userHave(text: []const u8, name: []const u8) bool {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var cols = std.mem.tokenizeAny(u8, line, " \t\r");
            _ = cols.next() orelse continue;
            const seco = cols.next() orelse continue;
            if (std.mem.eql(u8, seco, name)) return true;
        }
        return false;
    }

    // step 6: the admin user
    pub fn adminMake(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const name = self.conf.admi.user;
        if (name.len == 0 or self.conf.admi.mail.len == 0) return error.NoAdminName;
        const list = try self.tool.runz(try self.cliArgv(&.{ "admin", "user", "list" }), null);
        if (!list.okay()) return error.UserListFail;
        self.stat.data.idsz.adminUser = try self.gpa.dupe(u8, name);
        if (userHave(list.outz, name)) return .{ .okay = "admin exists" };
        const made = try self.tool.runz(try self.cliArgv(&.{ "admin", "user", "create", "--admin", "--username", name, "--email", self.conf.admi.mail, "--random-password", "--must-change-password=false" }), null);
        if (!made.okay()) return error.UserCreateFail;
        return .{ .okay = "admin created, password discarded" };
    }

    // step 7: one scoped token by CLI; the vault keeps it
    pub fn tokeMake(ctx: *anyopaque, gpa: std.mem.Allocator) !engi.Done {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        _ = gpa;
        const name = self.conf.admi.user;
        if (self.vaul.getz(CF.vaulToke)) |have| {
            self.forg.toke = have;
            if (self.forg.userSelf()) |me| {
                if (std.mem.eql(u8, me.login, name)) {
                    self.stat.data.idsz.tokeName = try self.gpa.dupe(u8, self.conf.toke.name);
                    return .{ .okay = "vault token still valid" };
                }
            } else |_| {}
        }
        const scop = try std.mem.join(self.gpa, ",", self.conf.toke.scop);
        const mint = try self.tool.runz(try self.cliArgv(&.{ "admin", "user", "generate-access-token", "--username", name, "--token-name", self.conf.toke.name, "--scopes", scop, "--raw" }), null);
        // a name clash means the secret is lost: the fix is revoke, then run again
        if (!mint.okay()) return error.TokenMintFail;
        const toke = mint.text();
        if (toke.len == 0 or std.mem.indexOfAny(u8, toke, " \t\r\n") != null) return error.TokenBad;
        try self.vaul.putz(CF.vaulToke, toke);
        self.forg.toke = self.vaul.getz(CF.vaulToke).?;
        const me = try self.forg.userSelf();
        if (!std.mem.eql(u8, me.login, name)) return error.TokenWrongUser;
        self.stat.data.idsz.tokeName = try self.gpa.dupe(u8, self.conf.toke.name);
        return .{ .okay = "token minted into the vault" };
    }

    // revoke: set a one-time password by CLI, delete the app-made token with basic auth, drop it from the vault
    pub fn revoToke(self: *Ctx) !void {
        const name = self.conf.admi.user;
        const tname = self.stat.data.idsz.tokeName;
        if (tname.len == 0) {
            try self.vaul.drop(CF.vaulToke);
            return;
        }
        var rand: [CF.passSize]u8 = undefined;
        self.io.random(&rand);
        var pass: [CF.passSize]u8 = undefined;
        for (rand, 0..) |byte, indx| pass[indx] = CF.passAlph[byte % CF.passAlph.len];
        const chng = try self.tool.runz(try self.cliArgv(&.{ "admin", "user", "change-password", "--username", name, "--password", &pass }), null);
        if (!chng.okay()) return error.PassSetFail;
        const basi = try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ name, pass });
        try self.forg.tokeDele(name, tname, basi);
        try self.vaul.drop(CF.vaulToke);
        self.stat.data.idsz.tokeName = "";
        try self.stat.save();
    }
};

pub fn rows(ctx: *Ctx) [2]engi.Row {
    return .{
        .{ .iden = "adm-user", .name = "admin user by CLI", .runz = Ctx.adminMake, .ctx = ctx },
        .{ .iden = "adm-token", .name = "scoped access token by CLI", .runz = Ctx.tokeMake, .ctx = ctx },
    };
}

test "user list parsing" {
    try std.testing.expect(Ctx.userHave("ID Username Email\n1 ann a@b.co true true\n", "ann"));
    try std.testing.expect(!Ctx.userHave("ID Username Email\n1 bob a@b.co true true\n", "ann"));
    try std.testing.expect(!Ctx.userHave("", "ann"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
