// =====================================================================
// Des: Entry point of the AWS EventBridge Scheduler tick setup app. Reads the command line and hands it to the command runner.
// Flo: parse argv > build the options > cm-cmds.execute > exit with its code
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv[1] = plan|run|status|drift|fix|pause|resume|revoke|tickkey|vault|version|help ; flags --live --paid --config F --steps F
// Out: stdout status lines, exit code 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build run -- help
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge/zig-out/bin/aws-eventbridge-setup
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const cmds = @import("cm-cmds.zig");
const line = @import("co-line.zig");
const osyz = @import("co-os.zig");

pub fn main(init: std.process.Init) !void {
    var aren = std.heap.ArenaAllocator.init(init.gpa);
    const gpa = aren.allocator();
    const io = init.io;
    var args = init.minimal.args.iterateAllocator(gpa) catch std.process.exit(cmds.CF.exitUsag);
    var list: std.ArrayList([]const u8) = .empty;
    while (args.next()) |item| list.append(gpa, item) catch std.process.exit(cmds.CF.exitUsag);

    const opts = parse(list.items) orelse {
        osyz.errz("unknown or missing command\n", .{});
        cmds.helpText(io);
        std.process.exit(cmds.CF.exitUsag);
    };
    const environ: std.process.Environ = if (builtin.os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const envz = environ.createMap(gpa) catch std.process.exit(cmds.CF.exitFail);
    var inpu = line.Inpu{ .io = io };
    const code = cmds.execute(gpa, io, &envz, opts, &inpu) catch |erro| {
        osyz.errz("failed: {s}\nwhy: see the audit log\nfix: rerun, it resumes where it stopped\n", .{@errorName(erro)});
        std.process.exit(cmds.CF.exitFail);
    };
    std.process.exit(code);
}

// argv to options; null when the command is missing or unknown
pub fn parse(argv: []const []const u8) ?cmds.Opts {
    if (argv.len < 2) return .{ .cmd = .help };
    const cmd = std.meta.stringToEnum(cmds.Cmd, argv[1]) orelse return null;
    var opts = cmds.Opts{ .cmd = cmd };
    var indx: usize = 2;
    while (indx < argv.len) : (indx += 1) {
        const item = argv[indx];
        if (std.mem.eql(u8, item, "--live")) {
            opts.live = true;
        } else if (std.mem.eql(u8, item, "--paid")) {
            opts.paid = true;
        } else if (std.mem.eql(u8, item, "--config") and indx + 1 < argv.len) {
            indx += 1;
            opts.confPath = argv[indx];
        } else if (std.mem.eql(u8, item, "--steps") and indx + 1 < argv.len) {
            indx += 1;
            opts.stepPath = argv[indx];
        } else if (!std.mem.startsWith(u8, item, "--") and opts.arg.len == 0) {
            opts.arg = item;
        } else return null;
    }
    return opts;
}

test "argv parsing" {
    const one = parse(&.{ "x", "run", "--live", "--config", "/c.json" }).?;
    try std.testing.expect(one.live and !one.paid and one.cmd == .run);
    try std.testing.expectEqualStrings("/c.json", one.confPath);
    try std.testing.expect(parse(&.{ "x", "bogus" }) == null);
    try std.testing.expect(parse(&.{ "x", "run", "--nope" }) == null);
    try std.testing.expect(parse(&.{"x"}).?.cmd == .help);
    try std.testing.expectEqualStrings("/k", parse(&.{ "x", "tickkey", "/k" }).?.arg);
}

test {
    _ = @import("co-os.zig");
    _ = @import("co-conf.zig");
    _ = @import("co-time.zig");
    _ = @import("co-audit.zig");
    _ = @import("co-state.zig");
    _ = @import("pv-vault.zig");
    _ = @import("co-line.zig");
    _ = @import("co-engine.zig");
    _ = @import("ap-sign.zig");
    _ = @import("ap-xml.zig");
    _ = @import("ap-http.zig");
    _ = @import("ap-aws.zig");
    _ = @import("ap-iam.zig");
    _ = @import("ap-evnt.zig");
    _ = @import("ap-sche.zig");
    _ = @import("ve-boot.zig");
    _ = @import("ve-iden.zig");
    _ = @import("ve-tick.zig");
    _ = @import("ve-fina.zig");
    _ = @import("cm-cmds.zig");
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
