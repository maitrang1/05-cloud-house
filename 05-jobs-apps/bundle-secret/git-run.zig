// =====================================================================
// Des: Runs git with a clean, non-interactive environment and a time limit, so an unattended fetch or ship fails fast instead of hanging on a prompt
// Flo: copy the environment > add no-prompt settings > run git -C <folder> with a deadline > exit code and output
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Git{ folder, tool name, time limit, output cap } + arguments
// Out: Res{ code, out, err } | GitzErro (Missing = git is not installed)
// Run: not run directly - imported by ship-flow.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

const CF = .{ .code_kill = 255, .args_maxz = 24, .line_maxz = 200 };

pub const GitzErro = error{ Missing, Timeout, RunFail, OutOfMemory };

pub const Res = struct {
    code: u8,
    out: []const u8,
    err: []const u8,

    pub fn okay(self: Res) bool {
        return self.code == 0;
    }

    pub fn text(self: Res) []const u8 {
        return std.mem.trim(u8, self.out, " \r\n\t");
    }

    // the first line git complained about, for one-line errors ----
    pub fn why(self: Res) []const u8 {
        const t = std.mem.trim(u8, self.err, " \r\n\t");
        const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
        return t[0..@min(end, CF.line_maxz)];
    }
};

pub const Git = struct {
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root: []const u8,
    bin: []const u8 = "git",
    tmos_secs: u32 = 120,
    outp_maxz: usize = 80 * 1024 * 1024,

    pub fn run(self: *const Git, args: []const []const u8) GitzErro!Res {
        var argv: [CF.args_maxz][]const u8 = undefined;
        if (args.len + 3 > argv.len) return error.RunFail;
        argv[0] = self.bin;
        argv[1] = "-C";
        argv[2] = self.root;
        @memcpy(argv[3..][0..args.len], args);
        var env = self.env.clone(self.a) catch return error.OutOfMemory;
        // never open a prompt or a credential window: an unattended run must fail fast ----
        env.put("GIT_TERMINAL_PROMPT", "0") catch return error.OutOfMemory;
        env.put("GCM_INTERACTIVE", "never") catch return error.OutOfMemory;
        const got = std.process.run(self.a, self.io, .{
            .argv = argv[0 .. args.len + 3],
            .environ_map = &env,
            .stdout_limit = .limited(self.outp_maxz),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, self.tmos_secs) * std.time.ns_per_s), .clock = .awake } },
        }) catch |e| return switch (e) {
            error.FileNotFound => error.Missing,
            error.Timeout => error.Timeout,
            error.OutOfMemory => error.OutOfMemory,
            else => error.RunFail,
        };
        const code: u8 = switch (got.term) {
            .exited => |c| c,
            else => CF.code_kill,
        };
        return .{ .code = code, .out = got.stdout, .err = got.stderr };
    }
};

test "git runs in the given folder; a failing command hands back its code and first line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var env = std.process.Environ.Map.init(a);
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    try env.put("HOME", buf[0..n]);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    const g: Git = .{ .io = io, .a = a, .env = &env, .root = buf[0..n] };
    const ver = g.run(&.{"--version"}) catch |e| if (e == error.Missing) return error.SkipZigTest else return e;
    try std.testing.expect(ver.okay());
    try std.testing.expect((try g.run(&.{ "init", "-q", "-b", "main" })).okay());
    try std.testing.expectEqualStrings("true", (try g.run(&.{ "rev-parse", "--is-inside-work-tree" })).text());
    const bad = try g.run(&.{ "rev-parse", "--verify", "no-such-ref" });
    try std.testing.expect(!bad.okay());
    try std.testing.expect(bad.why().len > 0);
    var nogit = g;
    nogit.bin = "zz-no-such-tool-9f3k";
    try std.testing.expectError(error.Missing, nogit.run(&.{"--version"}));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
