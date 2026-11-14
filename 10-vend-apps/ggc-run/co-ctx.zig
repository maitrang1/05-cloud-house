// =====================================================================
// Des: The shared bag every step action receives: settings, state, audit log, web client, tool runner, login, Google client, typed-key reader, and where the files live.
// Flo: built once in a command > passed by pointer to the engine > actions read what they need
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: everything the command made
// Out: one struct; small helpers (print, clock, project id, hand-job flag)
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("co-cfg.zig");
const stat = @import("co-state.zig");
const audi = @import("co-audit.zig");
const http = @import("co-http.zig");
const tool = @import("co-tool.zig");
const line = @import("co-line.zig");
const osyz = @import("co-os.zig");
const auth = @import("ap-auth.zig");
const gcp = @import("ap-gcp.zig");

const CF = .{ .msecSecs = 1000, .keyProj = "proj", .keyHand = "hand." };

pub const Ctx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    conf: *const conf.Conf,
    steps: conf.Steps,
    st: *stat.State,
    au: *audi.Audi,
    http: *http.Http,
    tool: *tool.Tool,
    auth: *auth.Auth,
    gcp: *gcp.Gcp,
    line: *line.Inpu,
    env: *const std.process.Environ.Map,
    root: []const u8,
    handled: u32 = 0,
    lastFail: []const u8 = "",

    // a user-facing line (silent in tests)
    pub fn say(self: *Ctx, comptime fmtz: []const u8, args: anytype) void {
        osyz.outz(self.io, fmtz, args);
    }

    pub fn nowSecs(self: *const Ctx) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), CF.msecSecs);
    }

    // the project id learned so far, "" before the project step
    pub fn projId(self: *const Ctx) []const u8 {
        return self.st.valu(CF.keyProj);
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

    // point the Google client at the project (quota header) once it is known
    pub fn projUse(self: *Ctx, iden: []const u8) void {
        self.gcp.proj = iden;
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
