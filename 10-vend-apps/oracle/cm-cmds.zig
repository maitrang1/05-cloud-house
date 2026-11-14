// =====================================================================
// Des: The commands of the app: plan, run, status, drift, revoke, sshkey, vault. Loads config and steps, opens the vault and state, builds the step rows, checks they match 10-steps.json, runs them and prints the report. Dry-run is the default; only --live acts.
// Flo: load config + steps > (dry-run: print plan) > open audit + state + vault > build ctx + rows > engine runs rows > report > exit code
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Opts (command, flags, paths), typed lines
// Out: stdout lines, exit code 0 ok · 1 failed · 2 usage/config · 3 drift · 4 needs a human
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const conf = @import("co-conf.zig");
const stat = @import("co-state.zig");
const vaul = @import("pv-vault.zig");
const audi = @import("co-audit.zig");
const line = @import("co-line.zig");
const tool = @import("co-tool.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const http = @import("ap-http.zig");
const oci = @import("ap-oci.zig");
const ctxx = @import("co-ctx.zig");
const keyz = @import("ve-keyz.zig");
const netw = @import("ve-netw.zig");
const inst = @import("ve-inst.zig");
const fina = @import("ve-fina.zig");

pub const CF = .{ .exitOkay = 0, .exitFail = 1, .exitUsag = 2, .exitDrif = 3, .exitHand = 4, .homeMark = "{home}", .passPrmp = "vault passphrase: ", .versText = "oracle-setup 0.1.0", .runnState = "RUNNING" };

pub const Cmd = enum { plan, run, status, drift, revoke, sshkey, vault, version, help };

pub const Opts = struct {
    cmd: Cmd,
    live: bool = false,
    paid: bool = false,
    confPath: []const u8 = "00-config.json",
    stepPath: []const u8 = "10-steps.json",
    arg: []const u8 = "", // sshkey output path
};

// replace a leading "{home}" with the real home folder
fn tmplHome(gpa: std.mem.Allocator, home: []const u8, path: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, gpa, path, CF.homeMark, home);
}

pub fn helpText(io: std.Io) void {
    osyz.outz(io, "{s}\nusage: oracle-setup <command> [--live] [--paid] [--config FILE] [--steps FILE]\n  plan     show every step, what is done, what is next (read only)\n  run      dry-run by default; --live does it for real (the app never deletes anything)\n  status   show the saved ids (compartment, VM, public ip)\n  drift    re-read the firewall and the VM, report anything that changed\n  revoke   drop the app's keys from the vault and show how to remove the API key in the console\n  sshkey P write the VM login key to file P (mode 600, refuses to overwrite)\n  vault    show the vault path and entry count\n  help     this text\n--paid allows a non-free shape, only with paid.okay set in the config.\n", .{CF.versText});
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
        const kind: []const u8 = if (item.hand > 0) "hand" else if (std.mem.eql(u8, item.kind, "guide")) "guide" else "auto";
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

    if (opts.cmd == .plan or (opts.cmd == .run and !opts.live)) {
        _ = planShow(io, steps, &st);
        if (opts.cmd == .run) osyz.outz(io, "dry-run: nothing was called and nothing was written. Add --live to run for real.\n", .{});
        return CF.exitOkay;
    }
    if (opts.cmd == .status) {
        const idsz = st.data.idsz;
        osyz.outz(io, "region: {s}\ntenancy: {s}\nuser: {s}\ncompartment: {s}\nvcn: {s}\nsubnet: {s}\nvm: {s}\npublic ip: {s}\n", .{ idsz.regi, idsz.tena, idsz.user, idsz.comp, idsz.vcnn, idsz.subn, idsz.inst, idsz.pubi });
        return CF.exitOkay;
    }

    // from here on the command may touch the vault, the disk or the cloud
    try std.Io.Dir.cwd().createDirPath(io, rootz);
    var logz = audi.Audi{ .io = io, .path = try std.fs.path.join(gpa, &.{ rootz, cfg.data.audi }) };
    var tool1 = try tool.Tool.init(gpa, io, &logz, envz, cfg.tool.time);

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
    if (opts.cmd == .sshkey) {
        const priv = vaul1.getz(ctxx.CF.vaulSshk) orelse {
            osyz.errz("no VM login key in the vault yet: run the setup first\n", .{});
            return CF.exitFail;
        };
        if (opts.arg.len == 0) {
            osyz.errz("usage: oracle-setup sshkey <file>\n", .{});
            return CF.exitUsag;
        }
        const fil = std.Io.Dir.cwd().createFile(io, opts.arg, if (builtin.os.tag == .windows) .{ .exclusive = true } else .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |erro| {
            osyz.errz("cannot write {s}: {s}\nfix: pick a new file path (an existing file is never overwritten)\n", .{ opts.arg, @errorName(erro) });
            return CF.exitFail;
        };
        defer fil.close(io);
        try fil.writePositionalAll(io, priv, 0);
        osyz.outz(io, "wrote {s}\n", .{opts.arg});
        return CF.exitOkay;
    }
    if (opts.cmd == .revoke) {
        try vaul1.drop(ctxx.CF.vaulKeyz);
        try vaul1.drop(ctxx.CF.vaulSshk);
        osyz.outz(io, "revoked: the signing key and the VM login key are gone from the vault.\nthe app never deletes in the cloud. To remove the API key too: console > Profile > API keys > the key with fingerprint {s} > Delete.\n", .{st.data.idsz.fing});
        return CF.exitOkay;
    }

    var http1 = http.Http.init(gpa, io, &logz, .{ .trys = cfg.http.trys, .back = cfg.http.back, .maxw = cfg.http.maxw, .agen = cfg.http.agen, .maxb = cfg.http.maxb });
    defer http1.deinit();
    var oci1 = oci.Oci{ .gpa = gpa, .http = &http1, .iden = "", .iaas = "", .vers = cfg.apis.vers };
    var ctx = ctxx.Ctx{ .gpa = gpa, .io = io, .conf = &cfg, .steps = steps, .stat = &st, .vaul = &vaul1, .logz = &logz, .http = &http1, .oci = &oci1, .tool = &tool1, .inpu = inpu, .root = rootz, .paid = opts.paid, .confPath = opts.confPath };

    const all = try rowsAll(gpa, &ctx);
    var eng = engi.Engi{ .gpa = gpa, .io = io, .stat = &st, .inpu = inpu, .guid = .{ .open = cfg.guid.open, .clip = cfg.guid.clip, .poll = cfg.guid.poll, .wait = cfg.guid.wait } };

    if (opts.cmd == .drift) {
        if (!try ctx.ociUp()) {
            osyz.errz("not set up yet: run the setup first\n", .{});
            return CF.exitFail;
        }
        _ = try netw.ingrLock(&ctx);
        if (st.data.idsz.inst.len > 0) {
            const stz = try oci1.instState(st.data.idsz.inst);
            osyz.outz(io, "vm state: {s}\n", .{stz});
            if (!std.mem.eql(u8, stz, CF.runnState)) ctx.drift = true;
        }
        osyz.outz(io, "drift: {s}\n", .{if (ctx.drift) "found" else "none"});
        return if (ctx.drift) CF.exitDrif else CF.exitOkay;
    }

    // run --live
    if (!stepsMatch(steps, all)) {
        osyz.errz("10-steps.json and the code disagree on the step list: fix the file or the code, never run half\n", .{});
        return CF.exitUsag;
    }
    eng.runAll(all) catch |erro| {
        if (erro == engi.Stop.EngiStop) {
            eng.report(all);
            return CF.exitHand;
        }
        osyz.errz("failed: {s}\nwhy: see {s}\nfix: rerun, it resumes where it stopped\n", .{ @errorName(erro), logz.path });
        return CF.exitFail;
    };
    eng.report(all);
    return if (ctx.drift) CF.exitDrif else CF.exitOkay;
}

// the 12 rows in step order
fn rowsAll(gpa: std.mem.Allocator, ctx: *ctxx.Ctx) ![]const engi.Row {
    var list: std.ArrayList(engi.Row) = .empty;
    try list.appendSlice(gpa, &keyz.rows(ctx));
    try list.appendSlice(gpa, &netw.rows(ctx));
    try list.appendSlice(gpa, &inst.rows(ctx));
    try list.append(gpa, netw.rowLock(ctx));
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
