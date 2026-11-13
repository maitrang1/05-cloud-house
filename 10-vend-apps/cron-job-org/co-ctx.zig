// =====================================================================
// Des: The shared bag every step action receives: settings, state, audit log, web client, vendor client, typed-input reader, the vault (opened on first need), and where the files live.
// Flo: built once in a command > passed by pointer to the engine > actions read what they need > vault opens only when a secret is needed
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: everything the command made
// Out: one struct; small helpers (print, clock, hand-job flag, vault, key load, quota line)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("co-cfg.zig");
const stat = @import("co-state.zig");
const audi = @import("co-audit.zig");
const http = @import("co-http.zig");
const line = @import("co-line.zig");
const osyz = @import("co-os.zig");
const cron = @import("ap-cron.zig");
const vaul = @import("pv-vault.zig");

const CF = .{ .msecSecs = 1000, .keyHand = "hand.", .pctMaxz = 100 };

pub const Ctx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    conf: *const conf.Conf,
    steps: conf.Steps,
    st: *stat.State,
    au: *audi.Audi,
    http: *http.Http,
    cron: *cron.Cron,
    line: *line.Inpu,
    env: *const std.process.Environ.Map,
    root: []const u8,
    handled: u32 = 0,
    lastFail: []const u8 = "",
    vlt: ?vaul.Vaul = null,
    tickUrl: []const u8 = "",
    tickSec: []const u8 = "",

    // a user-facing line (silent in tests)
    pub fn say(self: *Ctx, comptime fmtz: []const u8, args: anytype) void {
        osyz.outz(self.io, fmtz, args);
    }

    pub fn nowSecs(self: *const Ctx) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), CF.msecSecs);
    }

    // true when the human already confirmed this guided step
    pub fn handSeen(self: *const Ctx, iden: []const u8) bool {
        var buf: [64]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}{s}", .{ CF.keyHand, iden }) catch return false;
        return std.mem.eql(u8, self.st.valu(key), "1");
    }

    // remember the human confirmed this guided step
    pub fn handMark(self: *Ctx, iden: []const u8) !void {
        const key = try std.fmt.allocPrint(self.a, "{s}{s}", .{ CF.keyHand, iden });
        try self.st.putz(key, "1");
        try self.st.save(self.io);
    }

    // forget a hand-job confirmation (after a refused key, after revoke)
    pub fn handDrop(self: *Ctx, iden: []const u8) !void {
        const key = try std.fmt.allocPrint(self.a, "{s}{s}", .{ CF.keyHand, iden });
        try self.st.putz(key, "");
        try self.st.save(self.io);
    }

    // the vault, opened on first use: passphrase from the env var, else a hidden prompt
    pub fn vault(self: *Ctx) !*vaul.Vaul {
        if (self.vlt) |*vlt| return vlt;
        const cfg = self.conf;
        const pass = self.env.get(cfg.vaul.envz) orelse (self.line.hidd(cfg.vaul.prom) orelse return error.NoPassphrase);
        const path = try std.fs.path.join(self.a, &.{ self.root, cfg.data.vaul });
        self.vlt = try vaul.Vaul.open(self.a, self.io, path, pass, .{ .time = cfg.vaul.time, .memo = cfg.vaul.memo, .para = cfg.vaul.para });
        return &self.vlt.?;
    }

    // put the vaulted API key on the vendor client (and into the log mask); false when none is vaulted
    pub fn keyLoad(self: *Ctx) !bool {
        const vlt = try self.vault();
        const key = vlt.getz(self.conf.vaul.keya) orelse return false;
        self.cron.key = key;
        self.au.hideAdd(self.a, key);
        return true;
    }

    // "quota: N of M API requests today (P%)"
    pub fn quotaShow(self: *Ctx) void {
        const used = self.cron.used();
        const limi = self.conf.limi.dayl;
        self.say("quota: {d} of {d} API requests today ({d}%)\n", .{ used, limi, self.quotaPct() });
    }

    pub fn quotaPct(self: *const Ctx) u32 {
        return @intCast(@min(@as(u64, self.cron.used()) * CF.pctMaxz / self.conf.limi.dayl, CF.pctMaxz));
    }

    // true when today's use is at or over limi.warn percent
    pub fn quotaWarn(self: *const Ctx) bool {
        return self.quotaPct() >= self.conf.limi.warn;
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
