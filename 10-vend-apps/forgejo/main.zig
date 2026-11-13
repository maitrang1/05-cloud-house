// =====================================================================
// Des: CLI entry point. Loads config, opens the vault, runs the setup steps (or status/drift/revoke/vault/help), prints the final report.
// Flo: parse command > preflight (step 0) > load config > open vault+state > run the matching rows > report > exit code
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: argv[1] = run|status|drift|revoke|vault|help ; argv[2] = --go (consent for a live run)
// Out: stdout status lines, exit code 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo && zig build run -- help
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo/zig-out/bin/forgejo-setup
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
const forg = @import("forg-adapter.zig");
const host = @import("acts-host.zig");
const admi = @import("acts-admin.zig");
const repo = @import("acts-repo.zig");

const CF = .{ .confPath = "00-config.json", .passPrmp = "vault passphrase: ", .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .exitDrif = 3, .exitHand = 4, .apiPath = "/api/v1", .homeMark = "{home}", .vaulToke = "forg.token" };

// a set of named commands the CLI understands
const Cmd = enum { run, status, drift, revoke, vault, help };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = init.minimal.args.iterateAllocator(gpa) catch std.process.exit(CF.exitUsag);
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    while (args.next()) |a| list.append(gpa, a) catch std.process.exit(CF.exitUsag);

    const cmd: Cmd = if (list.items.len < 2) .help else std.meta.stringToEnum(Cmd, list.items[1]) orelse {
        osyz.errz("unknown command: {s}. Use: run status drift revoke vault help\n", .{list.items[1]});
        std.process.exit(CF.exitUsag);
    };
    if (cmd == .help) {
        printHelp(io);
        std.process.exit(CF.exitOkay);
    }

    const code = runCmd(gpa, io, cmd, list.items) catch |erro| {
        osyz.errz("failed: {s}\nwhy: see the audit log · fix: re-run, it resumes where it left off\n", .{@errorName(erro)});
        std.process.exit(if (erro == error.Drift) CF.exitDrif else CF.exitFail);
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
    cfg.sshz.file = try tmplHome(gpa, home, cfg.sshz.file);

    // step 0: preflight — the tools the app needs, printed before anything live happens
    const live = argv.len > 2 and std.mem.eql(u8, argv[2], "--go");
    const dryz = cmd == .run and !live; // a dry-run leaves no trace on disk
    const rootz = try tmplHome(gpa, home, cfg.data.root);
    conf.acctOverride(gpa, io, try std.fs.path.join(gpa, &.{ rootz, cfg.data.acct }), &cfg, &diag) catch |erro| {
        osyz.errz("account file error: {s}: {s} (fix {s} in {s})\n", .{ @errorName(erro), diag.mess, cfg.data.acct, rootz });
        return error.ConfigBad;
    };
    var logz = audi.Audi{ .io = io, .path = try std.fs.path.join(gpa, &.{ rootz, cfg.data.audi }), .fail = dryz };
    if (!dryz) try std.Io.Dir.cwd().createDirPath(io, rootz);
    var tool1 = try tool.Tool.init(gpa, io, &logz, &envz, cfg.tool.time);
    const haveGitz = tool1.have(cfg.tool.gitz);
    const haveSshz = tool1.have(cfg.tool.sshk);
    osyz.outz(io, "preflight: git={} ssh-keygen={} os={s}\n", .{ haveGitz, haveSshz, osyz.nameOsys() });
    if (!haveGitz or !haveSshz) return error.MissingTool;

    const vaulPath = try std.fs.path.join(gpa, &.{ rootz, cfg.data.vaul });
    const statPath = try std.fs.path.join(gpa, &.{ rootz, cfg.data.stat });

    if (dryz) {
        osyz.outz(io, "dry-run: would install Forgejo {s} on this host, then make admin '{s}', a repo and a push url. Vault: {s}. Pass --go to run for real.\n", .{ cfg.rele.vers, cfg.admi.user, vaulPath });
        if (cfg.admi.user.len == 0 or cfg.admi.mail.len == 0) osyz.outz(io, "to do first: set admi.user and admi.mail in the private account file (data.acct in the data folder)\n", .{});
        return CF.exitOkay;
    }
    if (cmd == .run and (cfg.admi.user.len == 0 or cfg.admi.mail.len == 0)) {
        osyz.errz("config error: set admi.user and admi.mail in the private account file (data.acct in the data folder) before --go\n", .{});
        return error.NoAdminName;
    }

    var queu = inpu.Inpu{ .io = io };
    const pass = envz.get(cfg.vaul.envz) orelse (queu.hidd(CF.passPrmp) orelse return error.NoPassphrase);
    var vaul1 = try vaul.Vaul.open(gpa, io, vaulPath, pass, .{ .time = cfg.vaul.time, .memo = cfg.vaul.memo, .para = cfg.vaul.para });
    var stat1 = try stat.Stat.load(gpa, io, statPath);

    var http1 = http.Http.init(gpa, io, &logz, .{ .trys = cfg.http.trys, .back = cfg.http.back, .maxw = cfg.http.maxw, .agen = cfg.http.agen, .maxb = cfg.http.maxb });
    defer http1.deinit();
    var down1 = http.Http.init(gpa, io, &logz, .{ .trys = cfg.http.trys, .back = cfg.http.back, .maxw = cfg.http.maxw, .agen = cfg.http.agen, .maxb = cfg.rele.maxb });
    defer down1.deinit();
    const apiz = try std.fmt.allocPrint(gpa, "http://{s}:{d}{s}", .{ cfg.host.pubh, cfg.host.port, CF.apiPath });
    var forg1 = forg.Forg{ .gpa = gpa, .http = &http1, .apiz = apiz, .toke = vaul1.getz(CF.vaulToke) orelse "" };

    var eng1 = engi.Engi{ .gpa = gpa, .io = io, .stat = &stat1, .inpu = &queu, .guid = .{ .open = cfg.guid.open, .clip = cfg.guid.clip, .poll = cfg.guid.poll, .wait = cfg.guid.wait } };

    return switch (cmd) {
        .run => blk: {
            var hostCtx = host.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .stat = &stat1, .tool = &tool1, .down = &down1, .forg = &forg1 };
            var admiCtx = admi.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .tool = &tool1, .forg = &forg1 };
            var repoCtx = repo.Ctx{ .gpa = gpa, .conf = &cfg, .stat = &stat1, .tool = &tool1, .forg = &forg1 };
            const all = host.rows(&hostCtx) ++ admi.rows(&admiCtx) ++ repo.rows(&repoCtx);
            eng1.runAll(&all) catch |erro| break :blk if (erro == engi.Stop.EngiStop) CF.exitHand else erro;
            eng1.report(&all);
            osyz.outz(io, "no vendor quota: the VM's disk and RAM are the limit\n", .{});
            break :blk CF.exitOkay;
        },
        .status => blk: {
            const idsz = stat1.data.idsz;
            osyz.outz(io, "admin: {s}  repo: {s}  token: {s}  push url: {s}\n", .{ idsz.adminUser, idsz.repoPath, idsz.tokeName, idsz.pushUrlz });
            break :blk CF.exitOkay;
        },
        .drift => blk: {
            var repoCtx = repo.Ctx{ .gpa = gpa, .conf = &cfg, .stat = &stat1, .tool = &tool1, .forg = &forg1 };
            const done = try repoCtx.driftChec();
            osyz.outz(io, "drift: {s}\n", .{switch (done) {
                .okay => |n| n,
                .skip => |n| n,
                .wait => "needs a human",
            }});
            break :blk CF.exitOkay;
        },
        .revoke => blk: {
            var admiCtx = admi.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .vaul = &vaul1, .stat = &stat1, .tool = &tool1, .forg = &forg1 };
            try admiCtx.revoToke();
            osyz.outz(io, "revoked: the app-made token is gone\n", .{});
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
    return std.mem.replaceOwned(u8, gpa, path, CF.homeMark, home);
}

fn printHelp(io: std.Io) void {
    osyz.outz(io, "forgejo-setup <command> [--go]\n  run     dry-run by default; --go installs + sets up for real (run on the Linux host, as root)\n  status  show admin, repo, token name and push url\n  drift   compare the Forgejo main head with the origin main head\n  revoke  kill the app-made token\n  vault   show the vault path and entry count\n  help    this text\n", .{});
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
    _ = @import("forg-adapter.zig");
    _ = @import("step-engine.zig");
    _ = @import("acts-host.zig");
    _ = @import("acts-admin.zig");
    _ = @import("acts-repo.zig");
    _ = @import("forg-contract.zig");
    _ = @import("acts-flow-contract.zig");
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
