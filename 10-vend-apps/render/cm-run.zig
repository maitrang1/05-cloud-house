// =====================================================================
// Des: The commands: run, status, cold, revoke, vault. Loads config, opens the vault, runs the steps, prints the report, returns the exit code.
// Flo: load config > preflight > dry-run unless --go > open vault + state > run the matching command > report
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: command, --go, --conf <path>
// Out: stdout lines; exit 0 ok, 1 failed, 2 usage/config, 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const osyz = @import("co-os.zig");
const cfg = @import("co-cfg.zig");
const vaul = @import("pv-vault.zig");
const stat = @import("co-state.zig");
const audi = @import("co-audit.zig");
const inpu = @import("co-input.zig");
const http = @import("co-http.zig");
const engi = @import("co-engine.zig");
const steps = @import("co-steps.zig");
const rend = @import("ap-render.zig");
const ctxz = @import("co-ctx.zig");
const acct = @import("ve-account.zig");
const serv = @import("ve-service.zig");
const wire = @import("ve-wire.zig");

pub const CF = .{ .passPrmp = "vault passphrase: ", .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .exitHand = 4, .confDefa = "00-config.json" };

pub const Cmd = enum { run, status, cold, revoke, vault, help };
pub const Flag = struct { go: bool = false, conf: []const u8 = CF.confDefa };

// plain what / why / fix for the errors people can hit
pub fn errHint(erro: anyerror) []const u8 {
    return switch (erro) {
        error.NoImage => "why: rend.imag is empty · fix: put your public GHCR image path in 00-config.json",
        error.KeyForm => "why: that is not a Render key · fix: copy the whole key from Account Settings > API Keys",
        error.KeyBad => "why: Render refused the key · fix: make a new key and run again",
        error.NoKey => "why: no key was typed · fix: run again and paste the key",
        error.RendAuth => "why: Render refused the key · fix: make a new key and run again",
        error.RendLimi => "why: too many calls · fix: wait a minute, run again, it resumes",
        error.RendDown => "why: Render or the network is down · fix: run again later, it resumes",
        error.PlanDrift => "why: the live plan differs from config · fix: change it in the dashboard or the config",
        error.Suspended => "why: the service is paused · fix: resume it in the dashboard",
        error.EnvMissing => "why: a needed env var has no vault value · fix: put it in the vault, run again",
        error.VaulPass => "why: wrong vault passphrase · fix: use the passphrase you first set",
        error.VaulWeak => "why: passphrase too short · fix: use a longer one",
        else => "why: see the audit log · fix: run again, it resumes where it left off",
    };
}

fn printHelp(io: std.Io) void {
    osyz.outz(io, "render-setup <command> [--go] [--conf <file>]\n  run     dry-run by default; --go runs for real\n  status  show the service id, url and step marks\n  cold    time one cold start now\n  revoke  pause the service the app made and forget the key (needs --go)\n  vault   show the vault path and entry count\n  help    this text\n", .{});
}

// replace a leading "{home}" with the real home folder
fn dirsMake(gpa: std.mem.Allocator, io: std.Io, conf: cfg.Conf, home: []const u8) !struct { root: []const u8, vaul: []const u8, stat: []const u8, audi: []const u8 } {
    const root = try cfg.homeFill(gpa, home, conf.data.root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    return .{ .root = root, .vaul = try std.fs.path.join(gpa, &.{ root, conf.data.vaul }), .stat = try std.fs.path.join(gpa, &.{ root, conf.data.stat }), .audi = try std.fs.path.join(gpa, &.{ root, conf.data.audi }) };
}

// print the dry-run: what a real run would do, and what is still missing
fn dryRun(gpa: std.mem.Allocator, io: std.Io, conf: cfg.Conf, vaulPath: []const u8) !u8 {
    const file = try steps.load(gpa);
    osyz.outz(io, "dry-run: nothing is changed. Pass --go to run for real.\nvault: {s}\nservice: {s} from {s} on plan {s} in {s}\nhand jobs: {d}\n", .{ vaulPath, conf.rend.name, if (conf.rend.imag.len == 0) "(rend.imag is EMPTY: set it)" else conf.rend.imag, conf.rend.plan, conf.rend.regi, steps.handCoun(file) });
    for (file.step) |item| osyz.outz(io, "  {d}. {s} [{s}]{s} {s}\n", .{ item.numb, item.iden, item.kind, if (item.hand > 0) " (hand)" else "", item.name });
    return if (conf.rend.imag.len == 0) CF.exitUsag else CF.exitOkay;
}

pub fn exec(gpa: std.mem.Allocator, io: std.Io, envz: *std.process.Environ.Map, cmd: Cmd, flag: Flag, queu: *inpu.Inpu) !u8 {
    const home = osyz.homeFind(envz) orelse return error.NoHome;
    var diag = cfg.Diag{};
    const conf = cfg.confLoad(gpa, io, flag.conf, &diag) catch |erro| {
        osyz.errz("config error: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return CF.exitUsag;
    };
    const dirs = try dirsMake(gpa, io, conf, home);
    osyz.outz(io, "preflight: os={s} config=ok plan={s}\n", .{ osyz.nameOsys(), conf.rend.plan });
    if (cmd == .run and !flag.go) return dryRun(gpa, io, conf, dirs.vaul);
    if (cmd == .revoke and !flag.go) {
        osyz.outz(io, "dry-run: revoke would pause the service the app made and drop the key from the vault. Pass --go.\n", .{});
        return CF.exitOkay;
    }

    var logz = audi.Audi{ .io = io, .path = dirs.audi };
    const pass = envz.get(conf.vaul.envz) orelse (queu.hidd(CF.passPrmp) orelse return error.NoPassphrase);
    var vaul1 = try vaul.Vaul.open(gpa, io, dirs.vaul, pass, .{ .time = conf.vaul.time, .memo = conf.vaul.memo, .para = conf.vaul.para });
    if (cmd == .vault) {
        osyz.outz(io, "vault: {s} ({d} entries)\n", .{ dirs.vaul, vaul1.list.items.len });
        return CF.exitOkay;
    }
    var stat1 = try stat.Stat.load(gpa, io, dirs.stat);
    var http1 = http.Http.init(gpa, io, &logz, .{ .trys = conf.http.trys, .back = conf.http.back, .maxw = conf.http.maxw, .agen = conf.http.agen, .maxb = conf.http.maxb });
    defer http1.deinit();
    var rend1 = rend.Rend{ .gpa = gpa, .http = &http1, .apiz = conf.rend.apiz, .toke = vaul1.getz(conf.vaul.keyz) orelse "" };
    var ctx = ctxz.Ctx{ .gpa = gpa, .io = io, .conf = &conf, .vaul = &vaul1, .stat = &stat1, .rend = &rend1, .inpu = queu, .root = dirs.root };

    switch (cmd) {
        .status => {
            const ids = stat1.data.idsz;
            osyz.outz(io, "service: {s}  url: {s}\ndashboard: {s}\nlast wake: {d}s  env hash: {s}\n", .{ ids.servId, ids.servUrl, ids.servDash, ids.coldSecs, ids.envHash });
            const file = try steps.load(gpa);
            for (file.step) |item| osyz.outz(io, "  {s}: {s}\n", .{ item.iden, @tagName(stat1.markGetz(item.iden)) });
            return CF.exitOkay;
        },
        .cold => {
            if (ids_empty(stat1)) return CF.exitUsag;
            const secs = try wire.wakeTime(&ctx, gpa);
            if (secs) |sec| osyz.outz(io, "cold start: answered in {d}s (202 window {d}s)\n", .{ sec, conf.cold.wind }) else osyz.outz(io, "cold start: no 200 within {d}s\n", .{conf.cold.wait});
            return if (secs != null) CF.exitOkay else CF.exitFail;
        },
        .revoke => {
            const iden = stat1.data.idsz.servId;
            if (iden.len > 0 and rend1.toke.len > 0) {
                rend1.suspend_(iden) catch |erro| {
                    osyz.errz("could not pause the service ({s}): {s}\n", .{ @errorName(erro), rend1.mess });
                    return CF.exitFail;
                };
                osyz.outz(io, "paused: service {s} (resume it in the dashboard any time)\n", .{iden});
            }
            try vaul1.drop(conf.vaul.keyz);
            // a later run must ask for a key again and notice the paused service
            inline for (.{ "keyz-ask", "serv-sett", "cold-test" }) |step| try stat1.markSetz(step, .todo, "revoked", 0);
            try stat1.save();
            osyz.outz(io, "forgot: the API key is gone from the vault\nhand step: delete the key in Account Settings > API Keys (Render has no API for that)\n", .{});
            return CF.exitOkay;
        },
        .run => {
            try stat1.markSetz("tool-chec", .done, "config ok, vault opened", std.Io.Clock.real.now(io).toMilliseconds());
            var list: std.ArrayList(engi.Row) = .empty;
            try list.appendSlice(gpa, &acct.rows(&ctx));
            try list.appendSlice(gpa, &serv.rows(&ctx));
            try list.appendSlice(gpa, &wire.rows(&ctx));
            var eng1 = engi.Engi{ .gpa = gpa, .io = io, .stat = &stat1, .inpu = queu, .guid = .{ .open = conf.guid.open, .clip = conf.guid.clip, .poll = conf.guid.poll, .wait = conf.guid.wait } };
            eng1.runAll(list.items) catch |erro| {
                if (erro == engi.Stop.EngiStop) return CF.exitHand;
                osyz.errz("failed: {s}\n{s}\n", .{ @errorName(erro), errHint(erro) });
                return CF.exitFail;
            };
            try stat1.save();
            eng1.report(list.items);
            return CF.exitOkay;
        },
        .vault, .help => unreachable,
    }
}

fn ids_empty(st: stat.Stat) bool {
    return st.data.idsz.servUrl.len == 0;
}

pub fn help(io: std.Io) void {
    printHelp(io);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
