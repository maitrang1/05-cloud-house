// =====================================================================
// Des: The CLI entry point - reads flags, loads config/steps/state, builds the 20-row GitHub step table, and dispatches plan/run/status/revoke
// Flo: parse args > load 00-config.json + 10-steps.json > open state + audit > build vendor table > dispatch command > exit code
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none - `github plan|run|status|revoke|push|publish|test|build|version|help` -- --config --steps --home --root --from --live --app --app-all --target
// Out: exit 0 ok · 1 failed · 2 usage/config · 3 secret found · 4 waiting on a human
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/github && zig build run -- plan
// Exe: /home/mai_trang/05-cloud-house/10-vend-apps/github/zig-out/bin/github
// =====================================================================
const std = @import("std");
const build_options = @import("build_options");
const conf = @import("config-load.zig");
const state = @import("state-file.zig");
const audit = @import("audit-log.zig");
const ctxm = @import("app-ctx.zig");
const eng = @import("step-engine.zig");
const out = @import("out-text.zig");
const os = @import("os-layer.zig");
const acct = @import("github-account.zig");
const repo = @import("github-repo.zig");
const ci = @import("github-ci.zig");
const rpush = @import("repo-push.zig");
const task = @import("app-task.zig");
const seen = @import("edit-seen.zig");
const sshc = @import("ssh-conf.zig");

const CF = .{ .conf_file = "00-config.json", .step_file = "10-steps.json", .args_maxz = 64, .apps_maxz = 16 };

const Args = struct {
    cmd: []const u8 = "",
    conf_path: []const u8 = CF.conf_file,
    step_path: []const u8 = CF.step_file,
    home: ?[]const u8 = null,
    root: ?[]const u8 = null,
    from: ?[]const u8 = null,
    live: bool = false,
    app_all: bool = false,
    app_edit: bool = false,
    target: ?[]const u8 = null,
    app_buf: [CF.apps_maxz][]const u8 = undefined,
    app_cnt: usize = 0,
};

const USAGE =
    \\github - set up a GitHub repo with CI, secrets and keys for 05-cloud-house.
    \\
    \\Usage: github <command> [flags]
    \\
    \\Commands:
    \\  plan      show every step's state (read-only, no calls that write)
    \\  run       do the steps; dry-run by default, needs --live for the first live run
    \\  status    print the saved state file
    \\  push      one-way mirror: --from always overwrites --root, gone files move to the trash (dry-run unless --live)
    \\  publish   push, then scan, commit and push to GitHub in one go (--from --root; dry-run unless --live)
    \\  test      run one app's tests, here (--from, and --app <name> or --app-all)
    \\  build     build one app, here (--from, and --app <name> or --app-all; --target for a cross build)
    \\  revoke    kill the login token and vaulted secrets this app made (never the repo)
    \\  version   print the app version
    \\  help      print this text
    \\
    \\Flags:
    \\  --config <path>   00-config.json (default: ./00-config.json)
    \\  --steps  <path>   10-steps.json  (default: ./10-steps.json)
    \\  --home   <path>   where state, vault, audit log and keys live
    \\  --root   <path>   the repo folder to set up (required for run/plan/push)
    \\  --from   <path>   push only: the working tree to copy from
    \\  --app    <name>   test/build: one app, by name or the tail of it (github); repeat for more
    \\  --app-all         test/build: every app, forced (never the default; nothing runs without --app, --app-edit or --app-all)
    \\  --app-edit        test/build: only apps whose files changed since their last green run of the same kind
    \\  --target <name>   build only: a cross target from ciiz.rele_targets (windows, x86_64-linux); no flag = native
    \\  --live            allow calls that write (sign-up, push, secrets); omit for a dry-run
    \\
    \\Exit codes: 0 ok · 1 failed · 2 usage/config · 3 secret found · 4 waiting on a human
    \\
;

fn parseArgs(args: []const []const u8) ?Args {
    var a: Args = .{};
    if (args.len == 0) return null;
    a.cmd = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const v = args[i];
        if (std.mem.eql(u8, v, "--live")) {
            a.live = true;
        } else if (std.mem.eql(u8, v, "--app-all")) {
            a.app_all = true;
        } else if (std.mem.eql(u8, v, "--app-edit")) {
            a.app_edit = true;
        } else if (std.mem.eql(u8, v, "--app") and i + 1 < args.len and a.app_cnt < CF.apps_maxz) {
            i += 1;
            a.app_buf[a.app_cnt] = args[i];
            a.app_cnt += 1;
        } else if (std.mem.eql(u8, v, "--target") and i + 1 < args.len) {
            i += 1;
            a.target = args[i];
        } else if (std.mem.eql(u8, v, "--config") and i + 1 < args.len) {
            i += 1;
            a.conf_path = args[i];
        } else if (std.mem.eql(u8, v, "--steps") and i + 1 < args.len) {
            i += 1;
            a.step_path = args[i];
        } else if (std.mem.eql(u8, v, "--home") and i + 1 < args.len) {
            i += 1;
            a.home = args[i];
        } else if (std.mem.eql(u8, v, "--from") and i + 1 < args.len) {
            i += 1;
            a.from = args[i];
        } else if (std.mem.eql(u8, v, "--root") and i + 1 < args.len) {
            i += 1;
            a.root = args[i];
        } else return null;
    }
    return a;
}

const TABLE = [_]eng.Entry{
    .{ .acts = "tool.chec", .run = acct.toolChec },
    .{ .acts = "sign.prep", .run = acct.signPrep },
    .{ .acts = "sign.form", .run = acct.signForm },
    .{ .acts = "sign.mail", .run = acct.signMail },
    .{ .acts = "auth.devi", .run = acct.authDevi },
    .{ .acts = "mail.chec", .run = acct.mailChec },
    .{ .acts = "twof.setz", .run = acct.twofSetz },
    .{ .acts = "iden.read", .run = acct.idenRead },
    .{ .acts = "gitz.iden", .run = repo.gitzIden },
    .{ .acts = "sshz.keyz", .run = repo.sshzKeyz },
    .{ .acts = "file.igno", .run = repo.fileIgno },
    .{ .acts = "scan.secr", .run = repo.scanSecr },
    .{ .acts = "repo.make", .run = repo.repoMake },
    .{ .acts = "repo.sett", .run = repo.repoSett },
    .{ .acts = "rule.bran", .run = repo.ruleBran },
    .{ .acts = "ciiz.secr", .run = ci.ciizSecr },
    .{ .acts = "ciiz.file", .run = ci.ciizFile },
    .{ .acts = "ghcr.push", .run = ci.ghcrPush },
    .{ .acts = "mirr.push", .run = ci.mirrPush },
    .{ .acts = "repo.fina", .run = ci.repoFina },
};

// what to do about a push error, in one line ----
fn pushFix(e: anyerror) []const u8 {
    return switch (e) {
        error.RootsOverlap => "--from and --root must be two separate folders (neither inside the other)",
        error.TrashOverlap => "push.trash must be outside the --root folder",
        error.NoTrashFolder => "set push.trash in 00-config.json: files that left the work tree are moved there",
        else => "check both folders exist and are writable, then run again",
    };
}

fn pushSay(io: std.Io, line: []const u8) void {
    out.say(io, "{s}", .{line});
}

fn die(code: u8) noreturn {
    std.process.exit(code);
}

// `test` and `build`: nothing runs unless you pick apps with --app, --app-edit or --app-all ----
fn taskMain(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, cf: conf.Conf, p: Args, seen_path: []const u8) noreturn {
    const is_build = std.mem.eql(u8, p.cmd, "build");
    const from = p.from orelse {
        out.fail(io, "no source folder given", "--from is required", "pass --from <working tree>");
        die(2);
    };
    const picked = @as(u8, @intFromBool(p.app_cnt > 0)) + @intFromBool(p.app_all) + @intFromBool(p.app_edit);
    if (picked != 1) {
        out.fail(io, "no app chosen", "pick exactly one way: --app <name> (repeat for more), --app-edit, or --app-all", "e.g. github test --from <work tree> --app github");
        die(2);
    }
    if (p.target != null and !is_build) {
        out.fail(io, "--target is for build only", "test always runs on this machine", "drop --target");
        die(2);
    }
    const paths = task.apps(io, a, from, cf.push.skip_dirs) catch |e| {
        out.fail(io, "cannot list the apps", @errorName(e), "check --from is the work tree");
        die(1);
    };
    const list = task.namesAll(a, paths) catch |e| {
        out.fail(io, if (e == error.BadName) "an app folder has an odd name" else "two apps share a short name", if (e == error.BadName) "app folder names may only hold letters, digits, dash, underscore and dot" else "their last two folder names match too", "rename the app folder");
        die(2);
    };
    var chosen: std.ArrayList(task.Named) = .empty;
    if (p.app_all or p.app_edit) {
        chosen.appendSlice(a, list) catch die(1);
    } else for (p.app_buf[0..p.app_cnt]) |q| {
        const got = task.pick(a, list, q) catch die(1);
        switch (got) {
            .ok => |x| chosen.append(a, x) catch die(1),
            .none => {
                out.fail(io, std.fmt.allocPrint(a, "no app named {s}", .{q}) catch "no such app", "no app has that short name", "use the short name, like github or facebook-scrape");
                die(2);
            },
            .many => |m| {
                out.fail(io, std.fmt.allocPrint(a, "{s} matches {d} apps", .{ q, m.len }) catch "name matches many apps", "the name must pick exactly one", "use the short name, like facebook-scrape");
                die(2);
            },
        }
    }
    var targets: []const []const u8 = &.{};
    if (p.target) |t| {
        targets = task.targetsFor(a, cf.ciiz.rele_targets, t) catch die(1);
        if (targets.len == 0) {
            out.fail(io, std.fmt.allocPrint(a, "no target named {s}", .{t}) catch "no such target", "ciiz.rele_targets lists the cross targets", "use a name or a piece of one, like windows");
            die(2);
        }
    }
    var jobs = (if (is_build) task.buildJobs(a, cf.task, chosen.items, targets) else task.testJobs(a, cf.task, chosen.items)) catch die(1);
    // what each app looks like right now; a green run saves it, --app-edit compares against it
    var memo = seen.load(io, a, seen_path) catch die(1);
    var hashes: std.StringHashMapUnmanaged(seen.Hex) = .empty;
    for (chosen.items) |x| {
        const h = seen.hashApp(io, a, from, x.path, cf.push, cf.task.edit_skip) catch |e| {
            out.fail(io, std.fmt.allocPrint(a, "cannot read {s}", .{x.name}) catch "cannot read an app", @errorName(e), "check --from is the work tree");
            die(1);
        };
        hashes.put(a, x.name, h) catch die(1);
    }
    if (p.app_edit) {
        var keep: std.ArrayList(task.Job) = .empty;
        for (jobs) |j| if (memo.edited(j.key, &hashes.get(j.name).?)) keep.append(a, j) catch die(1);
        jobs = keep.items;
        if (jobs.len == 0) {
            out.say(io, "nothing edited since the last green run\n", .{});
            die(0);
        }
        out.say(io, "edited since the last green run:", .{});
        for (jobs) |j| out.say(io, " {s}", .{j.label});
        out.say(io, "\n", .{});
    }
    var real: task.Real = .{ .io = io, .a = a, .env = env, .tmos_secs = cf.task.tmos_secs };
    const res = task.runJobs(io, a, cf.task, from, jobs, task.realRun, &real, &pushSay) catch |e| {
        out.fail(io, "run failed", @errorName(e), "check --from is the work tree and zig is on PATH");
        die(1);
    };
    for (res.green) |gi| memo.put(jobs[gi].key, &hashes.get(jobs[gi].name).?) catch die(1);
    if (res.green.len > 0) memo.save(io) catch out.say(io, "note: could not save the green record ({s}); --app-edit will run these again\n", .{seen_path});
    for (res.bad) |f| out.fail(io, std.fmt.allocPrint(a, "{s} is red", .{f.label}) catch "a job is red", if (f.tail.len > 0) f.tail else "the command failed", "fix it in that app folder, then run again");
    out.say(io, "\n{s}: {d} green · {d} red\n", .{ p.cmd, res.ok, res.bad.len });
    die(if (res.bad.len == 0) 0 else 1);
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    var arena = init.arena;
    const a = arena.allocator();
    const argv = std.process.Args.toSlice(init.minimal.args, a) catch die(2);
    const parsed = parseArgs(if (argv.len > 1) argv[1..] else &.{}) orelse {
        out.err(io, "{s}", .{USAGE});
        die(2);
    };
    if (std.mem.eql(u8, parsed.cmd, "help") or std.mem.eql(u8, parsed.cmd, "--help") or std.mem.eql(u8, parsed.cmd, "-h")) {
        out.say(io, "{s}", .{USAGE});
        die(0);
    }
    if (std.mem.eql(u8, parsed.cmd, "version")) {
        out.say(io, "github {s}\n", .{build_options.version});
        die(0);
    }
    const KNOWN = [_][]const u8{ "plan", "run", "status", "revoke", "push", "publish", "test", "build" };
    var okay = false;
    for (KNOWN) |k| {
        if (std.mem.eql(u8, parsed.cmd, k)) okay = true;
    }
    if (!okay) {
        out.err(io, "{s}", .{USAGE});
        die(2);
    }
    const NEEDS_ROOT = [_][]const u8{ "plan", "run", "revoke", "push", "publish" };
    var needs_root = false;
    for (NEEDS_ROOT) |k| {
        if (std.mem.eql(u8, parsed.cmd, k)) needs_root = true;
    }
    if (needs_root and parsed.root == null) {
        out.fail(io, "no repo folder given", "--root is required", "pass --root <folder>; the app never guesses it, to avoid a nested git repo");
        die(2);
    }
    const env = init.environ_map;
    const home = parsed.home orelse (os.homePath(env) orelse {
        out.fail(io, "no home folder set", "neither --home nor HOME/USERPROFILE is set", "pass --home <path>");
        die(2);
    });
    var cf = conf.confLoad(io, a, parsed.conf_path, build_options.mock) catch {
        out.fail(io, "config problem", conf.why, "fix 00-config.json and run again");
        die(2);
    };
    const home_full = conf.homeFill(a, cf.data.root, home) catch die(2);
    cf.push.trash = conf.homeFill(a, cf.push.trash, home) catch die(2);
    conf.acctOverride(io, a, std.fs.path.join(a, &.{ home_full, cf.data.acct }) catch die(2), &cf) catch {
        out.fail(io, "account file problem", conf.why, "fix account.json in the app home (keys: logi, mail) and run again");
        die(2);
    };
    const sf = conf.stepLoad(io, a, parsed.step_path) catch {
        out.fail(io, "steps problem", conf.why, "fix 10-steps.json and run again");
        die(2);
    };
    if (std.mem.eql(u8, parsed.cmd, "test") or std.mem.eql(u8, parsed.cmd, "build")) taskMain(io, a, env, cf, parsed, std.fs.path.join(a, &.{ home_full, cf.data.seen }) catch die(2));
    if (std.mem.eql(u8, parsed.cmd, "push")) {
        const from = parsed.from orelse {
            out.fail(io, "no source folder given", "--from is required for push", "pass --from <working tree> and --root <repo folder>");
            die(2);
        };
        const rep = rpush.push(io, a, cf.push, from, parsed.root orelse "", parsed.live, @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000), &pushSay) catch |e| {
            out.fail(io, "push failed", @errorName(e), pushFix(e));
            die(1);
        };
        out.say(io, "\n{s}: copied {d} · same {d} · denied {d} · too big {d} · not listed {d} · moved to trash {d}\n", .{ if (parsed.live) "pushed" else "dry-run", rep.copied, rep.same, rep.denied, rep.big, rep.other, rep.moved });
        die(0);
    }
    var st = state.load(io, a, std.fs.path.join(a, &.{ home_full, cf.data.stat }) catch die(2)) catch |e| {
        out.fail(io, "state file problem", @errorName(e), "the file is damaged; move it aside and run again (its ids are never secret)");
        die(2);
    };
    var au: audit.Audit = .{ .a = a, .path = std.fs.path.join(a, &.{ home_full, cf.data.audi }) catch die(2) };

    var ctx: ctxm.Ctx = .{ .io = io, .a = a, .env = env, .conf = cf, .steps = sf, .stat = &st, .audi = &au, .home = home_full, .user_home = home, .root = parsed.root orelse "", .conf_dirz = std.fs.path.dirname(parsed.conf_path) orelse ".", .live = parsed.live };

    if (std.mem.eql(u8, parsed.cmd, "publish")) {
        const from = parsed.from orelse {
            out.fail(io, "no source folder given", "--from is required for publish", "pass --from <working tree> and --root <repo folder>");
            die(2);
        };
        if (repo.rootGuard(&ctx) catch null) |bad| {
            out.fail(io, bad.fail.what, bad.fail.why, bad.fail.fix);
            die(2);
        }
        const rep = rpush.push(io, a, cf.push, from, ctx.root, parsed.live, ctx.nowSecs(), &pushSay) catch |e| {
            out.fail(io, "mirror failed", @errorName(e), pushFix(e));
            die(1);
        };
        out.say(io, "mirror: copied {d} · same {d} · denied {d} · too big {d} · moved to trash {d}\n", .{ rep.copied, rep.same, rep.denied, rep.big, rep.moved });
        const flow = ci.ciizRender(&ctx, parsed.live) catch |e| {
            if (e == error.NameClash or e == error.BadName) out.fail(io, "an app folder name cannot be used", if (e == error.BadName) "app folder names may only hold letters, digits, dash, underscore and dot" else "two apps share their last two folder names", "rename the app folder; no workflow was written") else out.fail(io, "workflow file failed", @errorName(e), "keep 20-build.yml next to 00-config.json");
            die(1);
        };
        if (flow.changed + flow.dropped > 0) out.say(io, "workflows: {s} {d} file(s), {s} {d} old file(s) in {s}\n", .{ if (parsed.live) "updated" else "would update", flow.changed, if (parsed.live) "moved out" else "would move out", flow.dropped, cf.ciiz.dir_path });
        if (!parsed.live) {
            out.say(io, "dry-run: nothing scanned, committed or pushed. Pass --live to publish.\n", .{});
            die(0);
        }
        sshc.ensure(&ctx) catch |e| {
            out.fail(io, "cannot write the ssh config", @errorName(e), "check the secret folder is writable");
            die(1);
        };
        // a failed reset only means the cached "clean" mark survives; the scan below still reads the files
        ctx.stat.putz("scan_okay", "") catch {};
        const scanned = repo.scanSecr(&ctx, .acts) catch |e| {
            out.fail(io, "scan failed", @errorName(e), "run the same command again");
            die(1);
        };
        switch (scanned) {
            .fail => |f| {
                out.fail(io, f.what, f.why, f.fix);
                die(f.code);
            },
            .done => |msg| out.say(io, "scan: {s}\n", .{msg}),
            else => {},
        }
        const sent = repo.publish(&ctx) catch |e| {
            out.fail(io, "publish failed", @errorName(e), "run the same command again");
            die(1);
        };
        switch (sent) {
            .fail => |f| {
                out.fail(io, f.what, f.why, f.fix);
                die(f.code);
            },
            .done => |msg| out.say(io, "{s}\n", .{msg}),
            else => {},
        }
        die(0);
    }
    if (std.mem.eql(u8, parsed.cmd, "plan")) {
        eng.plan(&ctx, &TABLE) catch |e| {
            out.fail(io, "plan failed", @errorName(e), "run the same command again");
            die(1);
        };
        die(0);
    }
    if (std.mem.eql(u8, parsed.cmd, "status")) {
        for (sf.step) |row| {
            const r = st.getz(row.iden);
            out.say(io, "{d:0>2} {s: <6} {s}\n", .{ row.numb, @tagName(r.stat), row.name });
        }
        die(0);
    }
    if (std.mem.eql(u8, parsed.cmd, "revoke")) {
        if (!parsed.live) {
            out.say(io, "dry-run: would revoke the login token and vaulted secrets. Pass --live to do it.\n", .{});
            die(0);
        }
        ci.revoke(&ctx) catch |e| {
            out.fail(io, "revoke failed", @errorName(e), "run the same command again");
            die(1);
        };
        die(0);
    }
    if (std.mem.eql(u8, parsed.cmd, "run")) {
        if (!parsed.live) {
            // the plan sweep is informational here; the dry-run message below is the result
            eng.plan(&ctx, &TABLE) catch {};
            out.say(io, "\ndry-run only. Pass --live for the first real run (it then resumes safely).\n", .{});
            die(0);
        }
        sshc.ensure(&ctx) catch |e| {
            out.fail(io, "cannot write the ssh config", @errorName(e), "check the secret folder is writable");
            die(1);
        };
        const rep = eng.run(&ctx, &TABLE, .acts) catch |e| {
            out.fail(io, "run failed", @errorName(e), "run the same command again");
            die(1);
        };
        out.say(io, "\ndone: {d}  skipped: {d}  stopped at: {s}\n", .{ rep.done, rep.skipped, rep.stop_at orelse "(finished)" });
        die(rep.code);
    }
    unreachable; // every KNOWN command is handled above
}

test {
    _ = @import("config-load.zig");
    _ = @import("state-file.zig");
    _ = @import("vault-file.zig");
    _ = @import("audit-log.zig");
    _ = @import("totp-code.zig");
    _ = @import("seal-box.zig");
    _ = @import("ssh-key.zig");
    _ = @import("secret-scan.zig");
    _ = @import("out-text.zig");
    _ = @import("os-layer.zig");
    _ = @import("net-http.zig");
    _ = @import("git-run.zig");
    _ = @import("github-api.zig");
    _ = @import("github-account.zig");
    _ = @import("github-repo.zig");
    _ = @import("github-ci.zig");
    _ = @import("repo-push.zig");
    _ = @import("ssh-conf.zig");
    _ = @import("step-engine.zig");
    _ = @import("app-task.zig");
    _ = @import("edit-seen.zig");
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
