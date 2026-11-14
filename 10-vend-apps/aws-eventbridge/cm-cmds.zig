// =====================================================================
// Des: The commands of the app: plan, run, status, drift, fix, pause, @"resume", revoke, tickkey, vault. Loads config and steps, opens the vault and state, builds the step rows, checks they match 10-steps.json, runs them and prints the report. Dry-run is the default; only --live acts.
// Flo: load config + steps > (dry-run: print plan) > open audit + state + vault > build ctx + rows > engine runs rows > report > exit code
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Opts (command, flags, paths), typed lines
// Out: stdout lines, exit code 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const conf = @import("co-conf.zig");
const stat = @import("co-state.zig");
const vaul = @import("pv-vault.zig");
const audi = @import("co-audit.zig");
const line = @import("co-line.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const http = @import("ap-http.zig");
const awsz = @import("ap-aws.zig");
const ctxx = @import("co-ctx.zig");
const boot = @import("ve-boot.zig");
const iden = @import("ve-iden.zig");
const tick = @import("ve-tick.zig");
const fina = @import("ve-fina.zig");

pub const CF = .{ .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .exitDrif = 3, .exitHand = 4, .homeMark = "{home}", .passPrmp = "vault passphrase: ", .versText = "aws-eventbridge-setup 0.1.0", .fixList = [_][]const u8{ "dest-make", "rule-make", "sche-make", "tick-chec" } };

pub const Cmd = enum { plan, run, status, drift, fix, pause, @"resume", revoke, tickkey, vault, version, help };

pub const Opts = struct {
    cmd: Cmd,
    live: bool = false,
    paid: bool = false,
    confPath: []const u8 = "00-config.json",
    stepPath: []const u8 = "10-steps.json",
    arg: []const u8 = "", // tickkey output path
};

// replace a leading "{home}" with the real home folder
fn tmplHome(gpa: std.mem.Allocator, home: []const u8, path: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, path, CF.homeMark, home);
}

pub fn helpText(io: std.Io) void {
    osyz.outz(io, "{s}\nusage: aws-eventbridge-setup <command> [--live] [--paid] [--config FILE] [--steps FILE]\n  plan     show every step, what is done, what is next (read only)\n  run      dry-run by default; --live does it for real (the app never deletes anything)\n  status   show the saved ids\n  drift    re-read AWS and compare with the config (exit 3 when different)\n  fix      with --live: make AWS match the config again (replace, never delete)\n  pause    with --live: switch the tick off (the kill switch)\n  resume   with --live: switch the tick on\n  revoke   drop the app's keys from the vault and show how to deactivate the key in the console\n  tickkey P write the tick secret to file P (mode 600, refuses to overwrite)\n  vault    show the vault path and entry count\n  help     this text\n--paid allows a tick rate above the free quota, only with paid.okay set in the config.\n", .{CF.versText});
}

// print the plan table; true when every step is already done
fn planShow(io: std.Io, steps: conf.Steps, st: *const stat.Stat) bool {
    var todo: u32 = 0;
    var hands: u32 = 0;
    var hdon: u32 = 0;
    osyz.outz(io, "\n", .{});
    for (steps.step) |item| {
        const mark = st.markGetz(item.iden);
        const sign: []const u8 = switch (mark) {
            .done => "done",
            .skip => "skip",
            .todo => "todo",
        };
        const kind: []const u8 = if (item.hand > 0) "hand" else "auto";
        osyz.outz(io, "  {d:>2} [{s}] {s:<5} {s}\n", .{ item.numb, sign, kind, item.name });
        if (mark == .todo) todo += 1;
        if (item.hand > 0) {
            hands += 1;
            if (mark != .todo) hdon += 1;
        }
    }
    osyz.outz(io, "\nhand jobs: {d} total, {d} done · steps left: {d}\n", .{ hands, hdon, todo });
    return todo == 0;
}

// write a secret to a new file, mode 600, never over an existing one
fn secretFile(io: std.Io, path: []const u8, text: []const u8) !void {
    const fil = try std.Io.Dir.cwd().createFile(io, path, if (builtin.os.tag == .windows) .{ .exclusive = true } else .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer fil.close(io);
    try fil.writePositionalAll(io, text, 0);
}

// run one command; the allocator should be an arena (nothing is freed one by one)
pub fn execute(gpa: std.mem.Allocator, io: std.Io, envz: *const std.process.Environ.Map, opts: Opts, inpu: *line.Inpu) !u8 {
    if (opts.cmd == .help) {
        helpText(io);
        return CF.exitOkay;
    }
    if (opts.cmd == .version) {
        osyz.outz(io, "{s}\n", .{CF.versText});
        return CF.exitOkay;
    }
    const home = osyz.homeFind(envz) orelse {
        osyz.errz("no HOME or USERPROFILE in the environment\n", .{});
        return CF.exitUsag;
    };

    var diag = conf.Diag{};
    const cfg = conf.confLoad(gpa, io, opts.confPath, &diag) catch |erro| {
        osyz.errz("config error: {s} line {d} col {d}: {s}\nfix: correct {s} and run again\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess, opts.confPath });
        return CF.exitUsag;
    };
    const steps = conf.stepLoad(gpa, io, opts.stepPath, &diag) catch |erro| {
        osyz.errz("steps error: {s} line {d} col {d}: {s}\n", .{ @errorName(erro), diag.line, diag.colu, diag.mess });
        return CF.exitUsag;
    };

    const rootz = try tmplHome(gpa, home, cfg.data.root);
    const statPath = try std.fs.path.join(gpa, &.{ rootz, cfg.data.stat });
    var st = try stat.Stat.load(gpa, io, statPath);

    const mutate = opts.cmd == .run or opts.cmd == .fix or opts.cmd == .pause or opts.cmd == .@"resume";
    if (opts.cmd == .plan or (mutate and !opts.live)) {
        _ = planShow(io, steps, &st);
        if (mutate) osyz.outz(io, "dry-run: nothing was called and nothing was written. Add --live to run for real.\n", .{});
        return CF.exitOkay;
    }
    if (opts.cmd == .status) {
        const idsz = st.data.idsz;
        osyz.outz(io, "region: {s}\naccount: {s}\nscoped user: {s} (key {s})\nbudget: {s}\nscheduler role: {s}\nrule role: {s}\nconnection: {s}\ndestination: {s}\nrule: {s}\nschedule: {s}\n", .{ idsz.regi, idsz.acct, idsz.user, idsz.keyi, idsz.budg, idsz.rols, idsz.rolr, idsz.conn, idsz.dest, idsz.rule, idsz.sche });
        return CF.exitOkay;
    }

    // from here on the command may touch the vault, the disk or the cloud
    try std.Io.Dir.cwd().createDirPath(io, rootz);
    var logz = audi.Audi{ .io = io, .path = try std.fs.path.join(gpa, &.{ rootz, cfg.data.audi }) };

    const vaulPath = try std.fs.path.join(gpa, &.{ rootz, cfg.data.vaul });
    const pass = envz.get(cfg.vaul.envz) orelse (inpu.hidd(CF.passPrmp) orelse {
        osyz.errz("no vault passphrase: set {s} or type it when asked\n", .{cfg.vaul.envz});
        return CF.exitUsag;
    });
    var vaul1 = vaul.Vaul.open(gpa, io, vaulPath, pass, .{ .time = cfg.vaul.time, .memo = cfg.vaul.memo, .para = cfg.vaul.para }) catch |erro| {
        osyz.errz("vault error: {s}\nwhy: wrong passphrase, or the vault file is damaged\nfix: retype the passphrase (8+ characters)\n", .{@errorName(erro)});
        return CF.exitUsag;
    };

    if (opts.cmd == .vault) {
        osyz.outz(io, "vault: {s} ({d} entries)\n", .{ vaulPath, vaul1.list.items.len });
        return CF.exitOkay;
    }
    if (opts.cmd == .tickkey) {
        const tkey = vaul1.getz(ctxx.CF.vkTick) orelse {
            osyz.errz("no tick secret in the vault yet: run the setup first\n", .{});
            return CF.exitFail;
        };
        if (opts.arg.len == 0) {
            osyz.errz("usage: aws-eventbridge-setup tickkey <file>\n", .{});
            return CF.exitUsag;
        }
        secretFile(io, opts.arg, tkey) catch |erro| {
            osyz.errz("cannot write {s}: {s}\nfix: pick a new file path (an existing file is never overwritten)\n", .{ opts.arg, @errorName(erro) });
            return CF.exitFail;
        };
        osyz.outz(io, "wrote {s}\n", .{opts.arg});
        return CF.exitOkay;
    }
    if (opts.cmd == .revoke) {
        for ([_][]const u8{ ctxx.CF.vkAkid, ctxx.CF.vkSecr, ctxx.CF.vkTick, ctxx.CF.vkMail }) |keyz| try vaul1.drop(keyz);
        osyz.outz(io, "revoked: the scoped key, the tick secret and the budget email are gone from the vault.\nthe app never deletes in the cloud. To remove the keys too: console > IAM > Users > {s} > Security credentials > key {s} > Deactivate, then Delete.\n", .{ st.data.idsz.user, st.data.idsz.keyi });
        return CF.exitOkay;
    }

    var http1 = http.Http.init(gpa, io, &logz, .{ .trys = cfg.http.trys, .back = cfg.http.back, .maxw = cfg.http.maxw, .agen = cfg.http.agen, .maxb = cfg.http.maxb });
    defer http1.deinit();
    var aws1 = awsz.Aws{ .gpa = gpa, .http = &http1 };
    var ctx = ctxx.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .steps = steps, .stat = &st, .vaul = &vaul1, .logz = &logz, .http = &http1, .aws = &aws1, .inpu = inpu, .root = rootz, .paid = opts.paid, .confPath = opts.confPath };

    const all = try rowsAll(gpa, &ctx);
    var eng = engi.Engi{ .gpa = gpa, .io = io, .stat = &st, .inpu = inpu, .guid = .{ .open = cfg.guid.open, .clip = cfg.guid.clip, .poll = cfg.guid.poll, .wait = cfg.guid.wait } };

    if (opts.cmd == .drift) {
        if (!try ctx.useCreds() or st.data.idsz.acct.len == 0) {
            osyz.errz("not set up yet: run the setup first\n", .{});
            return CF.exitFail;
        }
        const diff = try tick.checkAll(&ctx);
        osyz.outz(io, "drift: {s}\n", .{if (diff > 0) "found" else "none"});
        return if (diff > 0) CF.exitDrif else CF.exitOkay;
    }
    if (opts.cmd == .pause or opts.cmd == .@"resume") {
        if (st.data.idsz.sche.len == 0) {
            osyz.errz("no schedule yet: run the setup first\n", .{});
            return CF.exitFail;
        }
        tick.pauseSet(&ctx, opts.cmd == .@"resume") catch |erro| {
            osyz.errz("failed: {s}\nwhy: {s}\nfix: rerun; see {s}\n", .{ @errorName(erro), aws1.last, logz.path });
            return CF.exitFail;
        };
        osyz.outz(io, "tick is now {s}\n", .{if (opts.cmd == .@"resume") "ON" else "OFF"});
        return CF.exitOkay;
    }

    // run --live and fix --live
    if (!stepsMatch(steps, all)) {
        osyz.errz("10-steps.json and the code disagree on the step list: fix the file or the code, never run half\n", .{});
        return CF.exitUsag;
    }
    var todo = all;
    if (opts.cmd == .fix) {
        var pick: std.ArrayList(engi.Row) = .empty;
        for (all) |rowz| for (CF.fixList) |want| if (std.mem.eql(u8, rowz.iden, want)) {
            try st.markSetz(rowz.iden, .todo, "", 0); // converge again
            try pick.append(gpa, rowz);
        };
        todo = pick.items;
    }
    eng.runAll(todo) catch |erro| {
        if (erro == engi.Stop.EngiStop) {
            eng.report(todo);
            return CF.exitHand;
        }
        osyz.errz("failed: {s}\nwhy: {s}\nfix: rerun, it resumes where it stopped; see {s}\n", .{ @errorName(erro), aws1.last, logz.path });
        return CF.exitFail;
    };
    eng.report(todo);
    return if (ctx.drift) CF.exitDrif else CF.exitOkay;
}

// the 14 rows in step order
pub fn rowsAll(gpa: std.mem.Allocator, ctx: *ctxx.Ctx) ![]const engi.Row {
    var list: std.ArrayList(engi.Row) = .empty;
    try list.appendSlice(gpa, &boot.rows(ctx));
    try list.appendSlice(gpa, &iden.rows(ctx));
    try list.appendSlice(gpa, &tick.rows(ctx));
    try list.append(gpa, tick.rowChec(ctx));
    try list.appendSlice(gpa, &fina.rows(ctx));
    return list.items;
}

// the code's rows must be the file's steps, same ids, same order
pub fn stepsMatch(steps: conf.Steps, all: []const engi.Row) bool {
    if (steps.step.len != all.len) return false;
    for (steps.step, all) |item, rowz| if (!std.mem.eql(u8, item.iden, rowz.iden)) return false;
    return true;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
