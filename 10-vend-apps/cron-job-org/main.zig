// =====================================================================
// Des: CLI entry point. Reads the settings, builds the context, and runs one command: run, plan, status, usage, revoke or help.
// Flo: parse args > load config + steps > boot > dispatch the command > exit code
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv[1] = run|plan|status|usage|revoke|help ; --go (really do it) ; --conf <path>
// Out: stdout lines, exit code 0 ok · 1 failed · 2 usage/config · 3 drift or quota warning · 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build run -- help
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org/zig-out/bin/cronjoborg
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const conf = @import("co-cfg.zig");
const boot = @import("cm-boot.zig");
const crun = @import("cm-run.zig");
const cinf = @import("cm-info.zig");
const crev = @import("cm-revo.zig");

const CF = .{ .confPath = "00-config.json", .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .flagGo = "--go", .flagConf = "--conf" };

// a set of named commands the CLI understands
const Cmd = enum { run, plan, status, usage, revoke, help };

const help_text =
    \\cronjoborg <command> [--go] [--conf PATH]
    \\  run      dry-run by default; --go sets up the cron-job.org tick job for real
    \\  plan     show the steps and which are done
    \\  status   show the job as cron-job.org sees it (exit 3 if off or failing)
    \\  usage    show today's API request count (exit 3 at the warn level)
    \\  revoke   turn the job off and forget the key here (--go to do it)
    \\  help     this text
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    var cmd: Cmd = .help;
    var live = false;
    var cpath: []const u8 = CF.confPath;
    var indx: usize = 1;
    while (indx < argv.len) : (indx += 1) {
        const item = argv[indx];
        if (std.mem.eql(u8, item, CF.flagGo)) {
            live = true;
        } else if (std.mem.eql(u8, item, CF.flagConf)) {
            indx += 1;
            if (indx >= argv.len) usage("--conf needs a path\n");
            cpath = argv[indx];
        } else if (std.meta.stringToEnum(Cmd, item)) |name| {
            cmd = name;
        } else usage("unknown argument\n");
    }
    if (argv.len < 2 or cmd == .help) {
        osyz.outz(io, "{s}", .{help_text});
        std.process.exit(CF.exitOkay);
    }
    const code = exec(arena, io, cmd, live, cpath) catch |erro| {
        osyz.errz("failed: {s}\nwhy: see the audit log\nfix: re-run, it resumes where it left off\n", .{@errorName(erro)});
        std.process.exit(CF.exitFail);
    };
    std.process.exit(code);
}

fn usage(mess: []const u8) noreturn {
    osyz.errz("{s}run: cronjoborg help\n", .{mess});
    std.process.exit(CF.exitUsag);
}

// one command, start to end
fn exec(a: std.mem.Allocator, io: std.Io, cmd: Cmd, live: bool, cpath: []const u8) !u8 {
    var diag = conf.Diag{};
    const cfg = conf.confLoad(a, io, cpath, &diag) catch |erro| {
        osyz.errz("config error: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return CF.exitUsag;
    };
    const cdir = std.fs.path.dirname(cpath) orelse ".";
    const spath = try std.fs.path.join(a, &.{ cdir, cfg.data.step });
    const steps = conf.stepLoad(a, io, spath, &diag) catch |erro| {
        osyz.errz("steps error: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return CF.exitUsag;
    };
    const env = try osyz.environ(a);
    const home = osyz.homeFind(&env) orelse return error.NoHome;
    const root = try std.mem.replaceOwned(u8, a, cfg.data.root, "{home}", home);
    const bt = try a.create(boot.Boot);
    try bt.init(a, io, &env, &cfg, steps, root);
    const ctx = &bt.ctx;
    return switch (cmd) {
        .run => try crun.run(ctx, live),
        .plan => cinf.plan(ctx),
        .status => try cinf.status(ctx),
        .usage => cinf.usage(ctx),
        .revoke => try crev.revoke(ctx, live),
        .help => CF.exitOkay,
    };
}

test {
    _ = @import("co-cfg.zig");
    _ = @import("co-os.zig");
    _ = @import("co-date.zig");
    _ = @import("co-audit.zig");
    _ = @import("co-state.zig");
    _ = @import("co-http.zig");
    _ = @import("co-line.zig");
    _ = @import("co-engine.zig");
    _ = @import("pv-vault.zig");
    _ = @import("ap-cron.zig");
    _ = @import("rw-hand.zig");
    _ = @import("ve-job.zig");
    _ = @import("ve-guid.zig");
    _ = @import("te-flow.zig");
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
