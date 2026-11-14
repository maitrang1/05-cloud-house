// =====================================================================
// Des: Runs the helper programs the app relies on (git, ssh-keygen, ssh, glab, gh), with a time limit, and logs each run. git never stops to ask for a password.
// Flo: take argv > spawn with a timeout > collect output > audit line > return exit code + text
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv list, optional working folder
// Out: exit code, stdout, stderr
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const audi = @import("audit-log.zig");

const CF = .{ .outpMaxz = 4 << 20, .codeOdds = 255, .nsecSecs = std.time.ns_per_s, .envzList = [_][2][]const u8{ .{ "GIT_TERMINAL_PROMPT", "0" }, .{ "GCM_INTERACTIVE", "never" } } };

// result of one run
pub const Outp = struct {
    code: u8,
    outz: []const u8,
    errz: []const u8,

    pub fn okay(self: Outp) bool {
        return self.code == 0;
    }

    // stdout without the trailing newline
    pub fn text(self: Outp) []const u8 {
        return std.mem.trim(u8, self.outz, " \r\n\t");
    }
};

pub const Tool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    logz: *audi.Audi,
    envz: std.process.Environ.Map,
    time: u32,

    // copy the parent environment and stop git from prompting
    pub fn init(gpa: std.mem.Allocator, io: std.Io, logz: *audi.Audi, pare: *const std.process.Environ.Map, time: u32) !Tool {
        var envz = try pare.clone(gpa);
        for (CF.envzList) |pair| try envz.put(pair[0], pair[1]);
        return .{ .gpa = gpa, .io = io, .logz = logz, .envz = envz, .time = time };
    }

    // run to the end and collect output; error.ToolMiss when the program is not installed
    pub fn runz(self: *Tool, argv: []const []const u8, cwdz: ?[]const u8) !Outp {
        const star = std.Io.Clock.awake.now(self.io).toMilliseconds();
        const resu = std.process.run(self.gpa, self.io, .{ .argv = argv, .cwd = if (cwdz) |path| .{ .path = path } else .inherit, .environ_map = &self.envz, .stdout_limit = .limited(CF.outpMaxz), .stderr_limit = .limited(CF.outpMaxz), .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, self.time) * CF.nsecSecs), .clock = .awake } } }) catch |erro| {
            self.logLine(argv, -1, star);
            return if (erro == error.FileNotFound) error.ToolMiss else erro;
        };
        const code: u8 = if (resu.term == .exited) resu.term.exited else CF.codeOdds;
        self.logLine(argv, code, star);
        return .{ .code = code, .outz = resu.stdout, .errz = resu.stderr };
    }

    // run attached to the terminal (a tool that talks to the human)
    pub fn inte(self: *Tool, argv: []const []const u8) !u8 {
        const star = std.Io.Clock.awake.now(self.io).toMilliseconds();
        var chil = std.process.spawn(self.io, .{ .argv = argv, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit }) catch |erro| {
            self.logLine(argv, -1, star);
            return if (erro == error.FileNotFound) error.ToolMiss else erro;
        };
        const term = try chil.wait(self.io);
        const code: u8 = if (term == .exited) term.exited else CF.codeOdds;
        self.logLine(argv, code, star);
        return code;
    }

    // true when the program exists and can be executed; its exit code is never
    // checked here — some tools (e.g. ssh-keygen with no args) exit non-zero on
    // purpose, so only a failed exec itself (ToolMiss) means "not installed"
    pub fn have(self: *Tool, name: []const u8) bool {
        _ = self.runz(&.{name}, null) catch |erro| return erro != error.ToolMiss;
        return true;
    }

    // audit one run (argv never carries a secret; the log masks anyway)
    fn logLine(self: *Tool, argv: []const []const u8, code: i64, star: i64) void {
        const what = std.mem.join(self.gpa, " ", argv) catch return;
        defer self.gpa.free(what);
        self.logz.line(self.gpa, "tool", what, code, std.Io.Clock.awake.now(self.io).toMilliseconds() - star);
    }
};

test "tool runs git, reports a missing program" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var logz = audi.Audi{ .io = std.testing.io, .path = "/dev/null/none", .fail = true };
    var pare = std.process.Environ.Map.init(gpa);
    try pare.put("PATH", "/usr/bin:/bin:/usr/local/bin");
    var tool = try Tool.init(gpa, std.testing.io, &logz, &pare, 20);
    const outp = tool.runz(&.{ "git", "--version" }, null) catch |erro| if (erro == error.ToolMiss) return error.SkipZigTest else return erro;
    try std.testing.expect(outp.okay());
    try std.testing.expect(std.mem.startsWith(u8, outp.text(), "git version"));
    try std.testing.expectError(error.ToolMiss, tool.runz(&.{"zz-no-such-program-zz"}, null));
    try std.testing.expect(!tool.have("zz-no-such-program-zz"));
    try std.testing.expectEqualStrings("0", tool.envz.get("GIT_TERMINAL_PROMPT").?);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
