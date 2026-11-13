// =====================================================================
// Des: The commands: run, status, cold, revoke, vault. Loads config, opens the vault, runs the steps, prints the report, returns the exit code.
// Flo: load config > preflight > dry-run unless --go > open vault + state > run the matching command > report
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: command, --go, --conf <path>
// Out: stdout lines; exit 0 ok, 1 failed, 2 usage/config, 4 needs a human
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron && zig build test
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
const cfla = @import("ap-cflare.zig");
const ctxz = @import("co-ctx.zig");
const acct = @import("ve-account.zig");
const work = @import("ve-worker.zig");
const wire = @import("ve-wire.zig");

pub const CF = .{ .passPrmp = "vault passphrase: ", .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .exitHand = 4, .confDefa = "00-config.json" };

pub const Cmd = enum { run, sync, status, check, revoke, secret, vault, help };
pub const Flag = struct { go: bool = false, conf: []const u8 = CF.confDefa, arg: []const u8 = "" };

// plain what / why / fix for the errors people can hit
pub fn errHint(erro: anyerror) []const u8 {
    return switch (erro) {
        error.NoTrigger => "why: trig.url is empty · fix: put your Trigger url in 00-config.json",
        error.KeyForm => "why: that is not a full Cloudflare token · fix: copy the whole token from My Profile > API Tokens",
        error.KeyBad => "why: Cloudflare refused the token · fix: make a new token and run again",
        error.NoKey => "why: no token was typed · fix: run again and paste the token",
        error.CflaAuth => "why: Cloudflare refused the token or it lacks a permission · fix: token needs Workers Scripts Edit + Account Settings Read",
        error.CflaAcco => "why: no account matches cfla.acco · fix: clear it or copy the id from the dashboard",
        error.CflaLimi => "why: too many calls · fix: wait a minute, run again, it resumes",
        error.CflaDown => "why: Cloudflare or the network is down · fix: run again later, it resumes",
        error.RouteOff => "why: Cloudflare did not enable the workers.dev route · fix: Workers > your Worker > Settings > Domains, turn on workers.dev",
        error.CronDrift => "why: the live cron differs from config after the save · fix: run again; check the dashboard Triggers tab",
        error.VaulPass => "why: wrong vault passphrase · fix: use the passphrase you first set",
        error.VaulWeak => "why: passphrase too short · fix: use a longer one",
        else => "why: see the audit log · fix: run again, it resumes where it left off",
    };
}

fn printHelp(io: std.Io) void {
    osyz.outz(io, "cf-cron-setup <command> [--go] [--conf <file>]\n  run     dry-run by default; --go runs for real\n  sync    after a config change: redo upload, route, cron (needs --go)\n  status  show account, worker url, cron and step marks\n  check   ask the Worker route and the live cron now\n  secret <vault-key>  store one hidden value in the vault (e.g. trigger.tick_secret)\n  revoke  turn the cron off and forget the token (needs --go)\n  vault   show the vault path and entry count\n  help    this text\n", .{});
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
    const cron = try work.cronText(gpa, conf.cron.peri);
    osyz.outz(io, "dry-run: nothing is changed. Pass --go to run for real.\nvault: {s}\nworker: {s} cron {s} calls {s}{s}\nhand jobs: {d}\n", .{ vaulPath, conf.cfla.scri, cron, if (conf.trig.url.len == 0) "(trig.url is EMPTY: set it)" else conf.trig.url, conf.trig.path, steps.handCoun(file) });
    for (file.step) |item| osyz.outz(io, "  {d}. {s} [{s}]{s} {s}\n", .{ item.numb, item.iden, item.kind, if (item.hand > 0) " (hand)" else "", item.name });
    return if (conf.trig.url.len == 0) CF.exitUsag else CF.exitOkay;
}

pub fn exec(gpa: std.mem.Allocator, io: std.Io, envz: *std.process.Environ.Map, cmd: Cmd, flag: Flag, queu: *inpu.Inpu) !u8 {
    const home = osyz.homeFind(envz) orelse return error.NoHome;
    var diag = cfg.Diag{};
    const conf = cfg.confLoad(gpa, io, flag.conf, &diag) catch |erro| {
        osyz.errz("config error: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return CF.exitUsag;
    };
    const dirs = try dirsMake(gpa, io, conf, home);
    osyz.outz(io, "preflight: os={s} config=ok worker={s}\n", .{ osyz.nameOsys(), conf.cfla.scri });
    if ((cmd == .run or cmd == .sync) and !flag.go) return dryRun(gpa, io, conf, dirs.vaul);
    if (cmd == .revoke and !flag.go) {
        osyz.outz(io, "dry-run: revoke would turn the cron off and drop the token from the vault. Pass --go.\n", .{});
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
    var cfla1 = cfla.Cfla{ .gpa = gpa, .http = &http1, .apiz = conf.cfla.apiz, .toke = vaul1.getz(conf.vaul.keyz) orelse "" };
    var ctx = ctxz.Ctx{ .gpa = gpa, .io = io, .conf = &conf, .vaul = &vaul1, .stat = &stat1, .cfla = &cfla1, .inpu = queu, .root = dirs.root };

    switch (cmd) {
        .secret => {
            if (flag.arg.len == 0) {
                osyz.errz("secret needs a vault key name, e.g. secret {s}\n", .{conf.trig.secr});
                return CF.exitUsag;
            }
            const valu = queu.hidd("  value (hidden): ") orelse return error.NoKey;
            try vaul1.putz(flag.arg, valu);
            osyz.outz(io, "vaulted: {s}\n", .{flag.arg});
            return CF.exitOkay;
        },
        .status => {
            const ids = stat1.data.idsz;
            osyz.outz(io, "account: {s}  workers.dev: {s}\nworker url: {s}\ncron: {s}  last route answer: {d}s  hash: {s}\n", .{ ids.acctId, ids.subdomain, ids.workUrl, ids.cronNow, ids.routeSecs, ids.workHash });
            const file = try steps.load(gpa);
            for (file.step) |item| osyz.outz(io, "  {s}: {s}\n", .{ item.iden, @tagName(stat1.markGetz(item.iden)) });
            return CF.exitOkay;
        },
        .check => {
            if (noWorker(stat1)) return CF.exitUsag;
            const secs = try wire.routeTime(&ctx, gpa);
            if (secs) |sec| osyz.outz(io, "route: answered in {d}s\n", .{sec}) else osyz.outz(io, "route: no 200 within {d}s\n", .{conf.rout.wait});
            const live = cfla1.schedGet(stat1.data.idsz.acctId, conf.cfla.scri) catch |erro| {
                osyz.errz("could not read the cron ({s}): {s}\n", .{ @errorName(erro), cfla1.mess });
                return CF.exitFail;
            };
            osyz.outz(io, "cron live: {d} entry, first {s}\n", .{ live.len, if (live.len > 0) live[0] else "-" });
            return if (secs != null and live.len == 1) CF.exitOkay else CF.exitFail;
        },
        .revoke => {
            const acco = stat1.data.idsz.acctId;
            if (acco.len > 0 and cfla1.toke.len > 0) {
                cfla1.sched(acco, conf.cfla.scri, &.{}) catch |erro| {
                    osyz.errz("could not turn the cron off ({s}): {s}\n", .{ @errorName(erro), cfla1.mess });
                    return CF.exitFail;
                };
                osyz.outz(io, "cron off: worker {s} stays (set the cron again with sync)\n", .{conf.cfla.scri});
            }
            try vaul1.drop(conf.vaul.keyz);
            // a later run must ask for a token again and set the cron again
            inline for (.{ "toke-ask", "cron-set", "tick-test" }) |step| try stat1.markSetz(step, .todo, "revoked", 0);
            try stat1.save();
            osyz.outz(io, "forgot: the API token is gone from the vault\nhand step: delete the token in My Profile > API Tokens (Cloudflare has no safe API for that here)\n", .{});
            return CF.exitOkay;
        },
        .run, .sync => {
            try stat1.markSetz("tool-chec", .done, "config ok, vault opened", std.Io.Clock.real.now(io).toMilliseconds());
            // sync = config changed: redo the steps that depend on it
            if (cmd == .sync) inline for (.{ "work-push", "work-rout", "cron-set", "wire-sche", "tick-test", "cfcr-fina" }) |step| try stat1.markSetz(step, .todo, "sync", 0);
            var list: std.ArrayList(engi.Row) = .empty;
            try list.appendSlice(gpa, &acct.rows(&ctx));
            try list.appendSlice(gpa, &work.rows(&ctx));
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

fn noWorker(st: stat.Stat) bool {
    return st.data.idsz.workUrl.len == 0;
}

pub fn help(io: std.Io) void {
    printHelp(io);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
