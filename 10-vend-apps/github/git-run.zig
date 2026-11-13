// =====================================================================
// Des: Runs git and other helper tools with a clean, non-interactive environment and a time limit, and logs each command with secrets blacked out
// Flo: copy the environment > add no-prompt settings and the SSH key > run the tool with a deadline > audit line > exit code and output
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Git{ repo folder, env, time limit, ssh command, audit } + arguments
// Out: Res{ code, out, err } | GitzErro (Missing = tool not installed)
// Run: not run directly - imported by github-repo.zig, github-ci.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const audit = @import("audit-log.zig");

const CF = .{ .outp_maxz = 4 * 1024 * 1024, .code_kill = 255, .note_maxz = 200, .args_maxz = 32 };

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
};

pub const Git = struct {
    io: std.Io,
    a: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    root: []const u8,
    bin: []const u8 = "git",
    tmos_secs: u32 = 300,
    // "ssh -i <key> ..." for pushes with the app's own key, empty = git's default ----
    sshz: []const u8 = "",
    audi: ?*audit.Audit = null,

    // any tool, run from the caller's folder; `git` goes through run() ----
    pub fn tool(self: *const Git, argv: []const []const u8) GitzErro!Res {
        var env = self.env.clone(self.a) catch return error.OutOfMemory;
        // never open a prompt or a credential window: an unattended run must fail fast ----
        env.put("GIT_TERMINAL_PROMPT", "0") catch return error.OutOfMemory;
        env.put("GCM_INTERACTIVE", "never") catch return error.OutOfMemory;
        if (self.sshz.len > 0) env.put("GIT_SSH_COMMAND", self.sshz) catch return error.OutOfMemory;
        const t0 = std.Io.Clock.awake.now(self.io).toMilliseconds();
        const got = std.process.run(self.a, self.io, .{
            .argv = argv,
            .environ_map = &env,
            .stdout_limit = .limited(CF.outp_maxz),
            .stderr_limit = .limited(CF.outp_maxz),
            .timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, self.tmos_secs) * std.time.ns_per_s), .clock = .awake } },
        }) catch |e| {
            self.log(argv, -1, t0, @errorName(e));
            return switch (e) {
                error.FileNotFound => error.Missing,
                error.Timeout => error.Timeout,
                error.OutOfMemory => error.OutOfMemory,
                else => error.RunFail,
            };
        };
        const code: u8 = switch (got.term) {
            .exited => |c| c,
            else => CF.code_kill,
        };
        const res: Res = .{ .code = code, .out = got.stdout, .err = got.stderr };
        self.log(argv, code, t0, if (code == 0) "" else std.mem.trim(u8, got.stderr[0..@min(got.stderr.len, CF.note_maxz)], " \r\n"));
        return res;
    }

    pub fn run(self: *const Git, args: []const []const u8) GitzErro!Res {
        var argv: [CF.args_maxz][]const u8 = undefined;
        if (args.len + 3 > argv.len) return error.RunFail;
        argv[0] = self.bin;
        argv[1] = "-C";
        argv[2] = self.root;
        @memcpy(argv[3..][0..args.len], args);
        return self.tool(argv[0 .. args.len + 3]);
    }

    fn log(self: *const Git, argv: []const []const u8, code: i64, t0: i64, note: []const u8) void {
        const au = self.audi orelse return;
        const line = std.mem.join(self.a, " ", argv[1..]) catch return;
        au.add(self.io, .{ .when = std.Io.Clock.real.now(self.io).toMilliseconds(), .kind = "tool", .verb = argv[0], .targ = line, .code = code, .msec = std.Io.Clock.awake.now(self.io).toMilliseconds() - t0, .note = note });
    }
};

test "git runs in the given folder; a failing command hands back its code; a missing tool is Missing" {
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
    var au: audit.Audit = .{ .a = a, .path = try std.fs.path.join(a, &.{ buf[0..n], "audit.jsonl" }) };
    const g: Git = .{ .io = io, .a = a, .env = &env, .root = buf[0..n], .audi = &au };
    const ver = g.run(&.{"--version"}) catch |e| if (e == error.Missing) return error.SkipZigTest else return e;
    try std.testing.expect(ver.okay());
    try std.testing.expect(std.mem.startsWith(u8, ver.text(), "git version"));
    try std.testing.expect((try g.run(&.{ "init", "-q", "-b", "main" })).okay());
    try std.testing.expectEqualStrings("true", (try g.run(&.{ "rev-parse", "--is-inside-work-tree" })).text());
    const bad = try g.run(&.{ "rev-parse", "--verify", "no-such-ref" });
    try std.testing.expect(!bad.okay());
    try std.testing.expectError(error.Missing, g.tool(&.{"zz-no-such-tool-9f3k"}));
    try std.testing.expect(au.lines >= 4);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
