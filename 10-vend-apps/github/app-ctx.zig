// =====================================================================
// Des: Holds everything one run shares - settings, saved state, the vault, the log - and the small helpers every step uses to ask, show and wait
// Flo: open(paths, config, steps, state, audit) > steps call vault / secret / page / clip / ask / poll > close saves nothing by itself
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: io, arena, environment, Conf, Steps, home folder, repo folder
// Out: Ctx (used by the engine and the vendor adapter) ; Outc = what a step ended as
// Run: not run directly - imported by step-engine.zig and the github-*.zig files
// Exe: n/a
// =====================================================================
const std = @import("std");
const conf = @import("config-load.zig");
const state = @import("state-file.zig");
const vault = @import("vault-file.zig");
const audit = @import("audit-log.zig");
const http = @import("net-http.zig");
const git = @import("git-run.zig");
const os = @import("os-layer.zig");
const out = @import("out-text.zig");

const CF = .{ .pass_minz = 8 };

pub const Fail = struct { what: []const u8, why: []const u8, fix: []const u8, code: u8 = 1 };

// how one step ended; `wait` = a human or the vendor is not done yet ----
pub const Outc = union(enum) { done: []const u8, skip: []const u8, wait: []const u8, back, stop, fail: Fail };

pub const Mode = enum { chec, acts };

pub const Poll = enum { done, back, stop, wait };

pub const CtxErro = error{ NoHome, NoPass, VaultFail, OutOfMemory };

pub const Ctx = struct {
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    conf: conf.Conf,
    steps: conf.Steps,
    stat: *state.State,
    audi: *audit.Audit,
    home: []const u8,
    root: []const u8,
    conf_dirz: []const u8,
    // the user's home folder (for {home} in key paths); the secret folder is `home` ----
    user_home: []const u8 = "",
    live: bool = false,
    vaul: ?vault.Vault = null,
    // why the vault could not open, in plain words ----
    vaul_why: []const u8 = "",
    clip_when: i64 = 0,
    // gh mode: the token read from `gh auth token` once per run (never a stale vaulted copy) ----
    gh_tok: []const u8 = "",

    pub fn nowMsec(self: *const Ctx) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    pub fn nowSecs(self: *const Ctx) i64 {
        return @divFloor(self.nowMsec(), 1000);
    }

    pub fn sleep(self: *const Ctx, secs: u32) void {
        std.Io.sleep(self.io, .fromMilliseconds(@as(i64, secs) * 1000), .awake) catch {};
    }

    pub fn path(self: *const Ctx, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(self.a, parts);
    }

    pub fn keysPath(self: *const Ctx, publ: bool) ![]const u8 {
        const name = if (publ) try std.mem.concat(self.a, u8, &.{ self.conf.sshz.keyz_name, ".pub" }) else self.conf.sshz.keyz_name;
        return self.path(&.{ self.home, self.conf.data.keys, name });
    }

    pub fn hostPath(self: *const Ctx) ![]const u8 {
        return self.path(&.{ self.home, self.conf.data.host });
    }

    // repo name = folder name unless the config names one ----
    pub fn repoName(self: *const Ctx) []const u8 {
        if (self.conf.repo.name.len > 0) return self.conf.repo.name;
        return std.fs.path.basename(std.mem.trimEnd(u8, self.root, "/\\"));
    }

    pub fn httpOpts(self: *const Ctx) http.Opts {
        const h = self.conf.http;
        return .{ .tmos_secs = h.tmos_secs, .retr_maxz = h.retr_maxz, .wait_maxz_secs = h.wait_maxz_secs, .body_maxz_kbyt = h.body_maxz_kbyt, .user_agen = h.user_agen, .audi = self.audi };
    }

    pub fn gitz(self: *const Ctx, sshz: []const u8) git.Git {
        return .{ .io = self.io, .a = self.a, .env = self.env, .root = self.root, .bin = self.conf.tool.gitz, .tmos_secs = self.conf.gitz.tmos_secs, .sshz = sshz, .audi = self.audi };
    }

    // passphrase: the named environment variable, else typed hidden (twice for a new vault) ----
    fn passRead(self: *Ctx, fresh: bool) CtxErro![]const u8 {
        if (self.env.get(self.conf.vaul.pass_envz)) |p| if (p.len > 0) {
            if (p.len < CF.pass_minz) {
                self.vaul_why = "the passphrase needs 8 characters or more";
                return error.NoPass;
            }
            return p;
        };
        out.err(self.io, "{s}", .{if (fresh) "New vault. Choose a passphrase (hidden): " else "Vault passphrase (hidden): "});
        const one = try self.a.dupe(u8, os.hideRead(self.io) orelse return error.NoPass);
        if (one.len < CF.pass_minz) {
            self.vaul_why = "the passphrase needs 8 characters or more";
            return error.NoPass;
        }
        if (!fresh or !os.isTerm(self.io)) return one;
        out.err(self.io, "Type it again: ", .{});
        const two = os.hideRead(self.io) orelse return error.NoPass;
        if (!std.mem.eql(u8, one, two)) {
            self.vaul_why = "the two passphrases differ";
            return error.NoPass;
        }
        return one;
    }

    // a dry-run (plan, or run without --live) must stay read-only: it never opens the vault, so it
    // never prompts for a passphrase or blocks on stdin. A caller outside --live gets NoPass. ----
    pub fn vaultOpen(self: *Ctx) CtxErro!*vault.Vault {
        if (self.vaul != null) return &self.vaul.?;
        if (!self.live) return error.NoPass;
        const file = self.path(&.{ self.home, self.conf.data.vaul }) catch return error.OutOfMemory;
        const v = self.conf.vaul;
        const pass = try self.passRead(!vault.exists(self.io, file));
        self.vaul = vault.open(self.io, self.a, file, pass, .{ .time = v.argo_time, .memo = v.argo_memo_kbyt, .para = v.argo_para }) catch |e| {
            self.vaul_why = switch (e) {
                error.BadKey => "wrong passphrase, or the vault file is damaged",
                error.NotSealed => "the vault file is not a vault",
                else => @errorName(e),
            };
            return error.VaultFail;
        };
        for (self.vaul.?.list.items) |p| self.audi.hideAdd(p.valu);
        return &self.vaul.?;
    }

    pub fn secret(self: *Ctx, keyz: []const u8) CtxErro!?[]const u8 {
        return (try self.vaultOpen()).getz(keyz);
    }

    pub fn secretPut(self: *Ctx, keyz: []const u8, valu: []const u8) CtxErro!void {
        const v = try self.vaultOpen();
        self.audi.hideAdd(valu);
        v.putz(keyz, valu) catch return error.OutOfMemory;
        v.save(self.io) catch |e| {
            self.vaul_why = @errorName(e);
            return error.VaultFail;
        };
    }

    pub fn secretDrop(self: *Ctx, keyz: []const u8) CtxErro!void {
        const v = try self.vaultOpen();
        if (!v.drop(keyz)) return;
        v.save(self.io) catch return error.VaultFail;
    }

    pub fn say(self: *const Ctx, comptime fmt: []const u8, args: anytype) void {
        out.say(self.io, fmt, args);
    }

    pub fn ask(self: *const Ctx, prompt: []const u8) ?[]const u8 {
        out.err(self.io, "{s}", .{prompt});
        const line = os.lineRead(self.io) orelse return null;
        return self.a.dupe(u8, line) catch null;
    }

    pub fn askHide(self: *const Ctx, prompt: []const u8) ?[]const u8 {
        out.err(self.io, "{s}", .{prompt});
        const line = os.hideRead(self.io) orelse return null;
        return self.a.dupe(u8, line) catch null;
    }

    // open the page, or print the link when the browser is off or will not start ----
    pub fn page(self: *const Ctx, url: []const u8) void {
        const o = self.conf.osiz;
        if (o.brow_open and os.browOpen(self.io, url, o.brow_tool)) {
            self.say("   page opened: {s}\n", .{url});
        } else self.say("   open this page: {s}\n", .{url});
    }

    // a secret on the clipboard starts the clear timer ----
    pub fn clip(self: *Ctx, text: []const u8, hide: bool) bool {
        const o = self.conf.osiz;
        if (!o.clip_copy) return false;
        if (!os.clipCopy(self.io, text, o.clip_osc5, o.clip_tool)) return false;
        self.clip_when = if (hide) self.nowSecs() else 0;
        return true;
    }

    pub fn clipTick(self: *Ctx, force: bool) void {
        if (self.clip_when == 0) return;
        if (!force and self.nowSecs() - self.clip_when < self.conf.osiz.clip_clea_secs) return;
        const o = self.conf.osiz;
        _ = os.clipCopy(self.io, "", o.clip_osc5, o.clip_tool);
        self.clip_when = 0;
    }

    // watch until `test_fn` says done; when time is up, ask the human once per round ----
    pub fn poll(self: *Ctx, comptime test_fn: fn (*Ctx) anyerror!bool, hint: []const u8) anyerror!Poll {
        while (true) {
            const until = self.nowSecs() + self.conf.guid.tmos_secs;
            while (true) {
                if (try test_fn(self)) return .done;
                if (self.nowSecs() >= until) break;
                self.sleep(self.conf.guid.poll_secs);
                self.clipTick(false);
            }
            self.clipTick(true);
            while (true) {
                const key = self.ask("   not seen yet. g = I am done, check again · h = hint · b = back · x = stop: ") orelse return .wait;
                if (std.mem.eql(u8, key, "g")) break;
                if (std.mem.eql(u8, key, "b")) return .back;
                if (std.mem.eql(u8, key, "x")) return .stop;
                if (std.mem.eql(u8, key, "h")) self.say("   hint: {s}\n", .{hint});
            }
        }
    }
};

pub fn fail(what: []const u8, why: []const u8, fix: []const u8) Outc {
    return .{ .fail = .{ .what = what, .why = why, .fix = fix } };
}

pub fn failCode(code: u8, what: []const u8, why: []const u8, fix: []const u8) Outc {
    return .{ .fail = .{ .what = what, .why = why, .fix = fix, .code = code } };
}

test "repo name comes from the folder unless the config names one; paths join under the home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var st: state.State = .{ .a = a, .path = "" };
    var au: audit.Audit = .{ .a = a };
    var c: Ctx = .{ .io = std.testing.io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "h", .root = "/x/cloud-house/", .conf_dirz = "" };
    try std.testing.expectEqualStrings("cloud-house", c.repoName());
    c.conf.repo.name = "other";
    try std.testing.expectEqualStrings("other", c.repoName());
    try std.testing.expect(std.mem.endsWith(u8, try c.keysPath(true), "id_ed25519.pub"));
    try std.testing.expect(std.mem.endsWith(u8, try c.keysPath(false), "id_ed25519"));
}

test "vault opens from the named environment variable; a wrong one says why" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var env = std.process.Environ.Map.init(a);
    try env.put("T_PASS", "long-enough-pass");
    var st: state.State = .{ .a = a, .path = "" };
    var au: audit.Audit = .{ .a = a };
    var cf: conf.Conf = .{};
    cf.vaul = .{ .pass_envz = "T_PASS", .argo_time = 1, .argo_memo_kbyt = 8, .argo_para = 1 };
    var c: Ctx = .{ .io = io, .a = a, .env = &env, .conf = cf, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = buf[0..n], .root = "", .conf_dirz = "", .live = true };
    try std.testing.expect((try c.secret("auth.toke")) == null);
    try c.secretPut("auth.toke", "tok-value-123456");
    try std.testing.expectEqualStrings("x ***", au.redact("x tok-value-123456"));
    try env.put("T_PASS", "another-long-pass");
    var d: Ctx = .{ .io = io, .a = a, .env = &env, .conf = cf, .steps = c.steps, .stat = &st, .audi = &au, .home = buf[0..n], .root = "", .conf_dirz = "", .live = true };
    try std.testing.expectError(error.VaultFail, d.secret("auth.toke"));
    try std.testing.expect(std.mem.indexOf(u8, d.vaul_why, "wrong passphrase") != null);
}

test "a dry-run (live = false) never opens the vault, so it never blocks on a passphrase prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var st: state.State = .{ .a = a, .path = "" };
    var au: audit.Audit = .{ .a = a };
    var c: Ctx = .{ .io = std.testing.io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "/h", .root = "/r", .conf_dirz = "", .live = false };
    try std.testing.expectError(error.NoPass, c.secret("anything"));
    try std.testing.expect(c.vaul == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
