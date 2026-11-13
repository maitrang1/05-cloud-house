// =====================================================================
// Des: Gets a short-lived Google access token and tells who is logged in. Tokens come from gcloud (print-access-token) or from an env var. Nothing is saved to disk.
// Flo: who? > gcloud auth list or env var > login: gcloud auth login (human types the code) > token: cached up to life_secs > revoke: gcloud auth revoke
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Conf, Tool, environment map
// Out: account name, bearer token text (memory only)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("co-cfg.zig");
const tool = @import("co-tool.zig");

const CF = .{ .envAcct = "env-token", .msecSecs = 1000 };

pub const Erro = error{ NoToken, ToolFail };

pub const Auth = struct {
    a: std.mem.Allocator,
    io: std.Io,
    conf: *const conf.Conf,
    tool: *tool.Tool,
    env: *const std.process.Environ.Map,
    cache: []const u8 = "",
    got: i64 = 0,

    // the tool name followed by its arguments
    fn argv(self: *const Auth, rest: []const []const u8) ![]const []const u8 {
        const full = try self.a.alloc([]const u8, rest.len + 1);
        full[0] = self.conf.tool.gclo;
        @memcpy(full[1..], rest);
        return full;
    }

    // the token in the env var, trimmed, or null
    fn envTok(self: *const Auth) ?[]const u8 {
        const raw = self.env.get(self.conf.auth.toke_envz) orelse return null;
        const text = std.mem.trim(u8, raw, " \r\n\t");
        return if (text.len == 0) null else text;
    }

    fn nowSecs(self: *const Auth) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), CF.msecSecs);
    }

    // the active account, null when nobody is logged in
    pub fn who(self: *Auth) !?[]const u8 {
        if (!self.conf.gcloMode()) return if (self.envTok() != null) CF.envAcct else null;
        const outp = try self.tool.runz(try self.argv(self.conf.gclo.acct), null);
        if (!outp.okay()) return null;
        const first = std.mem.trim(u8, outp.text(), " \r\n\t");
        const line = if (std.mem.indexOfScalar(u8, first, '\n')) |nl| std.mem.trim(u8, first[0..nl], " \r") else first;
        return if (line.len == 0) null else line;
    }

    // run the interactive login; true when gcloud says it worked
    pub fn login(self: *Auth) !bool {
        if (!self.conf.gcloMode()) return false;
        return (try self.tool.inte(try self.argv(self.conf.gclo.logi))) == 0;
    }

    // a bearer token; gcloud ones are cached for life_secs
    pub fn token(self: *Auth) ![]const u8 {
        if (!self.conf.gcloMode()) return self.envTok() orelse error.NoToken;
        const nowz = self.nowSecs();
        if (self.cache.len != 0 and nowz - self.got < self.conf.auth.life_secs) return self.cache;
        const outp = try self.tool.runz(try self.argv(self.conf.gclo.toke), null);
        if (!outp.okay() or outp.text().len == 0) return error.NoToken;
        self.cache = try self.a.dupe(u8, outp.text());
        self.got = nowz;
        return self.cache;
    }

    // log an account out of gcloud (only ever the one the app logged in)
    pub fn revoke(self: *Auth, acct: []const u8) !bool {
        if (!self.conf.gcloMode()) return false;
        const rest = try conf.argvFill(self.a, self.conf.gclo.revo, &.{.{ "acct", acct }});
        const outp = try self.tool.runz(try self.argv(rest), null);
        self.cache = "";
        return outp.okay();
    }
};

test "env mode: token and account come from the env var" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = conf.Diag{};
    var cfg = try conf.confLoad(gpa, std.testing.io, "00-config.json", &diag);
    cfg.auth.mode = "env";
    var env = std.process.Environ.Map.init(gpa);
    var logz = @import("co-audit.zig").Audi{ .io = std.testing.io, .path = "/dev/null/none", .fail = true };
    var tl = try tool.Tool.init(gpa, std.testing.io, &logz, &env, 5);
    var au: Auth = .{ .a = gpa, .io = std.testing.io, .conf = &cfg, .tool = &tl, .env = &env };
    try std.testing.expect((try au.who()) == null);
    try std.testing.expectError(error.NoToken, au.token());
    try env.put(cfg.auth.toke_envz, "  ya29.fake \n");
    try std.testing.expectEqualStrings("env-token", (try au.who()).?);
    try std.testing.expectEqualStrings("ya29.fake", try au.token());
    try std.testing.expect(!(try au.login()));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
