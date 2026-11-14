// =====================================================================
// Des: CLI entry point for the Cloudflare setup. Reads the command and flags, then hands over to the commands file.
// Flo: parse argv > build the input queue > exec > exit code
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv: run|status|cold|revoke|vault|help  [--go]  [--conf <file>]
// Out: stdout lines, exit code 0 ok · 1 failed · 2 usage/config · 4 needs a human
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const osyz = @import("co-os.zig");
const inpu = @import("co-input.zig");
const cmdz = @import("cm-run.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var aren = std.heap.ArenaAllocator.init(gpa);
    const arez = aren.allocator();
    var args = init.minimal.args.iterateAllocator(arez) catch std.process.exit(cmdz.CF.exitUsag);
    var list: std.ArrayList([]const u8) = .empty;
    while (args.next()) |item| list.append(arez, item) catch std.process.exit(cmdz.CF.exitUsag);

    const cmd: cmdz.Cmd = if (list.items.len < 2) .help else std.meta.stringToEnum(cmdz.Cmd, list.items[1]) orelse {
        osyz.errz("unknown command: {s}. Use: run sync status check secret revoke vault help\n", .{list.items[1]});
        std.process.exit(cmdz.CF.exitUsag);
    };
    if (cmd == .help) {
        cmdz.help(io);
        std.process.exit(cmdz.CF.exitOkay);
    }
    var flag = cmdz.Flag{};
    var indx: usize = 2;
    while (indx < list.items.len) : (indx += 1) {
        const item = list.items[indx];
        if (std.mem.eql(u8, item, "--go")) {
            flag.go = true;
        } else if (std.mem.eql(u8, item, "--conf") and indx + 1 < list.items.len) {
            indx += 1;
            flag.conf = list.items[indx];
        } else if (cmd == .secret and flag.arg.len == 0 and !std.mem.startsWith(u8, item, "--")) {
            flag.arg = item;
        } else {
            osyz.errz("unknown option: {s}\n", .{item});
            std.process.exit(cmdz.CF.exitUsag);
        }
    }

    const environ: std.process.Environ = if (builtin.os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var envz = environ.createMap(arez) catch std.process.exit(cmdz.CF.exitFail);
    var queu = inpu.Inpu{ .io = io };
    const code = cmdz.exec(arez, io, &envz, cmd, flag, &queu) catch |erro| {
        osyz.errz("failed: {s}\n{s}\n", .{ @errorName(erro), cmdz.errHint(erro) });
        std.process.exit(cmdz.CF.exitFail);
    };
    std.process.exit(code);
}

test {
    _ = @import("co-os.zig");
    _ = @import("co-cfg.zig");
    _ = @import("co-audit.zig");
    _ = @import("co-state.zig");
    _ = @import("pv-vault.zig");
    _ = @import("co-http.zig");
    _ = @import("co-input.zig");
    _ = @import("co-engine.zig");
    _ = @import("co-steps.zig");
    _ = @import("ap-cflare.zig");
    _ = @import("ve-wire.zig");
    _ = @import("ve-worker.zig");
    _ = @import("te-flow.zig");
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
