// =====================================================================
// Des: CLI entry point. Loads config, opens the vault, runs the setup steps (or status/drift/rotate/revoke/drill/vault/help), prints the final report.
// Flo: parse command > preflight (step 0) > load config > open vault+state > run the matching rows > report > exit code
// Cre: 2026-11-12                          - | Mod: 2026-11-12 (aaa audit: EngiStop -> exit 4 for proj/mirr too)
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv[1] = run|status|drift|rotate|revoke|drill|vault|help ; argv[2] = --go (consent for a live run)
// Out: stdout status lines, exit code 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build run -- help
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup
// =====================================================================
const std = @import("std");
const osyz = @import("os-thin.zig");
const conf = @import("config-load.zig");
const vaul = @import("vault-file.zig");
const stat = @import("state-file.zig");
const audi = @import("audit-log.zig");
const inpu = @import("line-input.zig");
const http = @import("http-call.zig");
const tool = @import("tool-exec.zig");
const engi = @import("step-engine.zig");
const gitl = @import("gitl-adapter.zig");
const gith = @import("gith-adapter.zig");
const acct = @import("acts-account.zig");
const proj = @import("acts-project.zig");
const mirr = @import("acts-mirror.zig");

const CF = .{ .confPath = "00-config.json", .passPrmp = "vault passphrase: ", .passEnvz = "CLOUD_HOUSE_VAULT_PASS", .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .exitDrif = 3, .exitHand = 4 };

// a set of named commands the CLI understands
const Cmd = enum { run, status, drift, rotate, revoke, drill, vault, help };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterateAllocator(gpa) catch std.process.exit(CF.exitUsag);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    while (args.next()) |a| list.append(gpa, a) catch std.process.exit(CF.exitUsag);

    const cmd: Cmd = if (list.items.len < 2) .help else std.meta.stringToEnum(Cmd, list.items[1]) orelse {
        osyz.errz("unknown command: {s}. Use: run status drift rotate revoke drill vault help\n", .{list.items[1]});
        std.process.exit(CF.exitUsag);
    };
    if (cmd == .help) {
        printHelp(io);
        std.process.exit(CF.exitOkay);
    }

    const code = runCmd(gpa, io, cmd, list.items) catch |erro| {
        osyz.errz("failed: {s}\nwhy: see the audit log · fix: re-run, it resumes where it left off\n", .{@errorName(erro)});
        std.process.exit(CF.exitFail);
    };
    std.process.exit(code);
}

fn runCmd(gpa: std.mem.Allocator, io: std.Io, cmd: Cmd, argv: []const []const u8) !u8 {
    var envz = try init_environ(gpa);
    const home = osyz.homeFind(&envz) orelse return error.NoHome;

    var diag = conf.Diag{};
    var cfg = conf.confLoad(gpa, io, CF.confPath, &diag) catch |erro| {
        osyz.errz("config error: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return error.ConfigBad;
    };

    // step 0: preflight — the tools the app needs, printed before anything live happens
    var logz = audi.Audi{ .io = io, .path = try tmplHome(gpa, home, cfg.data.audi) };
    var tool1 = try tool.Tool.init(gpa, io, &logz, &envz, cfg.tool.time);
    const haveGitz = tool1.have(cfg.tool.gitz);
    const haveSshz = tool1.have(cfg.tool.sshk);
    osyz.outz(io, "preflight: git={} ssh-keygen={} os={s}\n", .{ haveGitz, haveSshz, osyz.nameOsys() });
    if (!haveGitz or !haveSshz) return error.MissingTool;

    const rootz = try tmplHome(gpa, home, cfg.data.root);
    conf.acctOverride(gpa, io, try std.fs.path.join(gpa, &.{ rootz, cfg.data.acct }), &cfg, &diag) catch |erro| {
        osyz.errz("account file error: {s}: {s} (fix {s} in {s})\n", .{ @errorName(erro), diag.mess, cfg.data.acct, rootz });
        return error.ConfigBad;
    };
    try std.Io.Dir.cwd().createDirPath(io, rootz);
    const vaulPath = try std.fs.path.join(gpa, &.{ rootz, cfg.data.vaul });
    const statPath = try std.fs.path.join(gpa, &.{ rootz, cfg.data.stat });

    const live = argv.len > 2 and std.mem.eql(u8, argv[2], "--go");
    if (cmd == .run and !live) {
        osyz.outz(io, "dry-run: would open the vault at {s} and run the setup. Pass --go to run for real.\n", .{vaulPath});
        return CF.exitOkay;
    }

    var queu = inpu.Inpu{ .io = io };
    const pass = envz.get(CF.passEnvz) orelse (queu.hidd(CF.passPrmp) orelse return error.NoPassphrase);
    var vaul1 = try vaul.Vaul.open(gpa, io, vaulPath, pass, .{ .time = cfg.vaul.time, .memo = cfg.vaul.memo, .para = cfg.vaul.para });
    var stat1 = try stat.Stat.load(gpa, io, statPath);

    var http1 = http.Http.init(gpa, io, &logz, .{ .trys = cfg.http.trys, .back = cfg.http.back, .maxw = cfg.http.maxw, .agen = cfg.http.agen, .maxb = cfg.http.maxb });
    defer http1.deinit();
    var gitl1 = gitl.Gitl{ .gpa = gpa, .http = &http1, .apiz = cfg.gitl.apiz, .oaut = cfg.gitl.oaut, .toke = vaul1.getz("gitl.token") orelse "" };
    var gith1 = gith.Gith{ .gpa = gpa, .io = io, .http = &http1, .apiz = cfg.gith.apiz, .vers = cfg.gith.vers, .toke = vaul1.getz("gith.token") orelse "", .owne = vaul1.getz("gith.owner") orelse "", .repo = cfg.gitl.proj };

    var eng1 = engi.Engi{ .gpa = gpa, .io = io, .stat = &stat1, .inpu = &queu, .guid = .{ .open = cfg.guid.open, .clip = cfg.guid.clip, .poll = cfg.guid.poll, .wait = cfg.guid.wait } };

    return switch (cmd) {
        .run => blk: {
            var acctCtx = acct.Ctx{ .gpa = gpa, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1 };
            eng1.runAll(&acct.rows(&acctCtx)) catch |erro| break :blk if (erro == engi.Stop.EngiStop) CF.exitHand else erro;
            var projCtx = proj.Ctx{ .gpa = gpa, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .tool = &tool1, .gitl = &gitl1 };
            eng1.runAll(&proj.rows(&projCtx)) catch |erro| break :blk if (erro == engi.Stop.EngiStop) CF.exitHand else erro;
            var mirrCtx = mirr.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1, .gith = &gith1 };
            eng1.runAll(&mirr.rows(&mirrCtx)) catch |erro| break :blk if (erro == engi.Stop.EngiStop) CF.exitHand else erro;
            eng1.report(&(acct.rows(&acctCtx) ++ proj.rows(&projCtx) ++ mirr.rows(&mirrCtx)));
            if (projCtx.usagLine(gpa)) |line| osyz.outz(io, "{s}\n", .{line}) else |_| osyz.outz(io, "usage: unreadable now (run again)\n", .{});
            break :blk CF.exitOkay;
        },
        .status => blk: {
            osyz.outz(io, "project id: {d}  mirror token id: {d}  expires: {s}\n", .{ stat1.data.idsz.glProj, stat1.data.idsz.tokeIden, stat1.data.idsz.tokeExpi });
            var projCtx = proj.Ctx{ .gpa = gpa, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .tool = &tool1, .gitl = &gitl1 };
            if (projCtx.usagLine(gpa)) |line| osyz.outz(io, "{s}\n", .{line}) else |_| osyz.outz(io, "usage: unreadable now\n", .{});
            break :blk CF.exitOkay;
        },
        .drift => blk: {
            var mirrCtx = mirr.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1, .gith = &gith1 };
            const done = mirr.Ctx.driftChec(&mirrCtx, gpa) catch break :blk CF.exitDrif;
            osyz.outz(io, "drift: {s}\n", .{switch (done) {
                .okay => |n| n,
                .skip => |n| n,
                .wait => "needs a human",
            }});
            break :blk CF.exitOkay;
        },
        .rotate => blk: {
            var mirrCtx = mirr.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .gitl = &gitl1, .gith = &gith1 };
            _ = try mirr.Ctx.rotaToke(&mirrCtx, gpa);
            break :blk CF.exitOkay;
        },
        .revoke => blk: {
            const iden = stat1.data.idsz.glProj;
            const tide = stat1.data.idsz.tokeIden;
            if (iden != 0 and tide != 0) try gitl1.atokDele(iden, tide);
            try vaul1.drop("gitl.mirror_token");
            osyz.outz(io, "revoked: the app-made mirror token is gone\n", .{});
            break :blk CF.exitOkay;
        },
        .drill => blk: {
            osyz.outz(io, "failover drill: not wired yet (needs Monitor layer); see .10-docs/60-plan.md\n", .{});
            break :blk CF.exitOkay;
        },
        .vault => blk: {
            osyz.outz(io, "vault: {s} ({d} entries)\n", .{ vaulPath, vaul1.list.items.len });
            break :blk CF.exitOkay;
        },
        .help => unreachable,
    };
}

fn init_environ(gpa: std.mem.Allocator) !std.process.Environ.Map {
    const builtin = @import("builtin");
    const environ: std.process.Environ = if (builtin.os.tag == .windows) .{ .block = .global } else .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    return environ.createMap(gpa);
}

// replace a leading "{home}" with the real home folder
fn tmplHome(gpa: std.mem.Allocator, home: []const u8, path: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, path, "{home}", home);
}

fn printHelp(io: std.Io) void {
    osyz.outz(io, "gitlab-setup <command> [--go]\n  run     dry-run by default; --go runs for real\n  status  show project id, mirror token id and expiry\n  drift   check the mirror workflow's last run\n  rotate  rotate the mirror token now if due\n  revoke  kill the app-made mirror token\n  drill   failover drill (not wired yet)\n  vault   show the vault path and entry count\n  help    this text\n", .{});
}

test {
    _ = @import("os-thin.zig");
    _ = @import("config-load.zig");
    _ = @import("date-math.zig");
    _ = @import("audit-log.zig");
    _ = @import("state-file.zig");
    _ = @import("vault-file.zig");
    _ = @import("http-call.zig");
    _ = @import("tool-exec.zig");
    _ = @import("line-input.zig");
    _ = @import("gitl-adapter.zig");
    _ = @import("gith-adapter.zig");
    _ = @import("gitl-contract.zig");
    _ = @import("gith-contract.zig");
    _ = @import("step-engine.zig");
    _ = @import("acts-account.zig");
    _ = @import("acts-project.zig");
    _ = @import("acts-mirror.zig");
    _ = @import("acts-flow-contract.zig");
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
