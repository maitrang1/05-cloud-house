// =====================================================================
// Des: Builds everything a command needs in place (audit log, web client, tool runner, login, Google client, state, input) and wires the shared context to it.
// Flo: make folder > open audit + state > build http, tool, auth, gcp > point the context at them
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: arena allocator, io, environment, Conf, Steps, data folder
// Out: a ready Boot with .ctx
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
const ctxm = @import("co-ctx.zig");
const auth = @import("ap-auth.zig");
const gcp = @import("ap-gcp.zig");

pub const Boot = struct {
    au: audi.Audi = undefined,
    st: stat.State = undefined,
    http: http.Http = undefined,
    tool: tool.Tool = undefined,
    auth: auth.Auth = undefined,
    gcp: gcp.Gcp = undefined,
    line: line.Inpu = undefined,
    ctx: ctxm.Ctx = undefined,

    // fill every field in place (nothing here may be copied after, the context holds pointers)
    pub fn init(self: *Boot, a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cfg: *const conf.Conf, steps: conf.Steps, root: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, root);
        self.au = .{ .io = io, .path = try std.fs.path.join(a, &.{ root, cfg.data.audi }) };
        self.st = try stat.load(io, a, try std.fs.path.join(a, &.{ root, cfg.data.stat }));
        self.http = http.Http.init(a, io, &self.au, .{ .trys = cfg.http.trys, .back = cfg.http.back, .maxw = cfg.http.maxw, .agen = cfg.http.agen, .maxb = cfg.http.maxb });
        self.tool = try tool.Tool.init(a, io, &self.au, env, cfg.tool.time);
        self.auth = .{ .a = a, .io = io, .conf = cfg, .tool = &self.tool, .env = env };
        self.gcp = .{ .a = a, .io = io, .http = &self.http, .auth = &self.auth, .quot = cfg.auth.quot_head, .lro_msec = cfg.http.lro_msec, .lro_secs = cfg.http.lro_secs };
        self.line = .{ .io = io };
        self.ctx = .{ .a = a, .io = io, .conf = cfg, .steps = steps, .st = &self.st, .au = &self.au, .http = &self.http, .tool = &self.tool, .auth = &self.auth, .gcp = &self.gcp, .line = &self.line, .env = env, .root = root };
        // the quota header only once the APIs step is done (before that the project has none of them on)
        if (self.st.getz("apis-enab").stat == .done) self.gcp.proj = self.st.valu("proj");
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
