// =====================================================================
// Des: The CLI entry point - reads flags, loads config, asks for the passphrase, and runs pack / unpack / check / status
// Flo: parse args > load 00-config.json > passphrase (hidden prompt or env var) > run the job > print what happened > exit code
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none - `secret-bundle pack|unpack|check|status|version|help` -- --repo --config --home --go
// Out: exit 0 ok · 1 failed · 2 usage/config · 3 files differ (check)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle && zig build run -- status --repo <repo>
// Exe: /home/mai_trang/00_modules/05-cloud-house/05-jobs-apps/secret-bundle/zig-out/bin/secret-bundle
// =====================================================================
const std = @import("std");
const build_options = @import("build_options");
const conf = @import("config-load.zig");
const flow = @import("bundle-flow.zig");
const os = @import("os-layer.zig");
const out = @import("out-text.zig");

const CF = .{ .conf_file = "00-config.json", .exit_ok = 0, .exit_fail = 1, .exit_use = 2, .exit_diff = 3 };

const USAGE =
    \\secret-bundle - seal the shared secrets into one encrypted file that can sit in git, and open it on another device
    \\
    \\Usage: secret-bundle <command> --repo <folder> [flags]
    \\
    \\Commands:
    \\  pack     pick the secret files by the rules in 00-config.json and seal them in the bundle (dry-run unless --go)
    \\  unpack   open the bundle and put the files back in the repo; a different local file is saved to the trash first (dry-run unless --go)
    \\  check    open the bundle and compare it with the files on disk (read-only; exit 3 when they differ)
    \\  status   show the bundle file: size, Argon2 cost, sha256 (no passphrase)
    \\  version  print the app version
    \\  help     print this text
    \\
    \\Flags:
    \\  --repo <folder>   the repo root (required)
    \\  --config <path>   00-config.json (default: ./00-config.json)
    \\  --home <path>     home folder for {home} in unpack.trash (default: HOME / USERPROFILE)
    \\  --go              allow writes; omit for a dry-run
    \\  --rekey           pack only: replace a bundle that another passphrase made (on purpose)
    \\
    \\Passphrase: typed hidden, or read from the variable named in bundle.pass_envz.
    \\Exit codes: 0 ok · 1 failed · 2 usage or config · 3 files differ (check)
    \\
;

const Args = struct { cmd: []const u8, repo: ?[]const u8 = null, conf_path: []const u8 = CF.conf_file, home: ?[]const u8 = null, go: bool = false, rekey: bool = false };

fn parseArgs(argv: []const []const u8) ?Args {
    if (argv.len == 0) return null;
    var r: Args = .{ .cmd = argv[0] };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (std.mem.eql(u8, k, "--go")) {
            r.go = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--rekey")) {
            r.rekey = true;
            continue;
        }
        if (i + 1 >= argv.len) return null;
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, k, "--repo")) r.repo = v else if (std.mem.eql(u8, k, "--config")) r.conf_path = v else if (std.mem.eql(u8, k, "--home")) r.home = v else return null;
    }
    return r;
}

fn die(n: u8) noreturn {
    std.process.exit(n);
}

fn say(io: std.Io, text: []const u8) void {
    out.say(io, "{s}", .{text});
}

// typed hidden (twice when `confirm`), or the env variable named in config ----
fn passGet(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, c: conf.Conf, confirm: bool, enforce_min: bool) []const u8 {
    if (env.get(c.bundle.pass_envz)) |v| if (v.len > 0) return minCheck(io, v, c, enforce_min);
    out.err(io, "Passphrase: ", .{});
    const one = os.hideRead(io) orelse die(CF.exit_use);
    const first = a.dupe(u8, one) catch die(CF.exit_fail);
    if (confirm and os.isTerm(io)) {
        out.err(io, "Again: ", .{});
        const two = os.hideRead(io) orelse die(CF.exit_use);
        if (!std.mem.eql(u8, first, two)) {
            out.fail(io, "the two passphrases differ", "a typo would lock the bundle for good", "run the command again");
            die(CF.exit_use);
        }
    }
    return minCheck(io, first, c, enforce_min);
}

fn minCheck(io: std.Io, pass: []const u8, c: conf.Conf, enforce_min: bool) []const u8 {
    if (enforce_min and pass.len < c.bundle.pass_min) {
        out.fail(io, "the passphrase is too short", "bundle.pass_min is the shortest allowed", "use a longer passphrase, or lower bundle.pass_min in 00-config.json");
        die(CF.exit_use);
    }
    return pass;
}

fn flowFail(io: std.Io, e: anyerror) noreturn {
    switch (e) {
        error.BadKey => out.fail(io, "cannot open the bundle", "wrong passphrase, or the file is damaged", "retype the passphrase; if it keeps failing, restore the file from git history"),
        error.NotSealed => out.fail(io, "this is not a secret-bundle file", "the head is missing or its cost is out of range", "check bundle.path in 00-config.json"),
        error.NoBundle => out.fail(io, "no bundle file", "nothing at <repo>/<bundle.path>", "run pack --go on a device that holds the secrets, then pull"),
        error.PassDiffers => out.fail(io, "the bundle in the repo was made with another passphrase", "replacing it would lock out every device that uses the old one", "retype the right passphrase; to change it on purpose, run pack --go --rekey, then unpack on every device"),
        error.NothingPicked => out.fail(io, "nothing to pick", "no file matches pick.dirs or pick.files", "check the rules in 00-config.json and --repo"),
        error.TooMuch => out.fail(io, "the picked files are over the total cap", "pick.total_maxz_mbyt", "narrow the rules, or raise the cap on purpose"),
        error.NoRepo => out.fail(io, "cannot open the repo folder", "--repo does not exist or is not readable", "pass the repo root"),
        error.UnsafePath, error.BadArchive => out.fail(io, "the bundle holds a bad path or is damaged", "a path left the repo or a size does not fit", "do not use it; restore the file from git history"),
        error.LinkInTheWay => out.fail(io, "a link sits where a secret file should be", "writing would follow it outside the repo", "move the link away by hand, then run again"),
        error.WriteFail => out.fail(io, "cannot write a file", "folder missing, no permission, or disk full", "check the path and permissions"),
        else => out.fail(io, @errorName(e), "unexpected", "run again; report if it repeats"),
    }
    die(CF.exit_fail);
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    var arena = init.arena;
    const a = arena.allocator();
    const argv = std.process.Args.toSlice(init.minimal.args, a) catch die(CF.exit_use);
    const parsed = parseArgs(if (argv.len > 1) argv[1..] else &.{}) orelse {
        out.err(io, "{s}", .{USAGE});
        die(CF.exit_use);
    };
    if (std.mem.eql(u8, parsed.cmd, "help") or std.mem.eql(u8, parsed.cmd, "--help") or std.mem.eql(u8, parsed.cmd, "-h")) {
        out.say(io, "{s}", .{USAGE});
        die(CF.exit_ok);
    }
    if (std.mem.eql(u8, parsed.cmd, "version")) {
        out.say(io, "secret-bundle {s}\n", .{build_options.version});
        die(CF.exit_ok);
    }
    const KNOWN = [_][]const u8{ "pack", "unpack", "check", "status" };
    var known = false;
    for (KNOWN) |k| if (std.mem.eql(u8, parsed.cmd, k)) {
        known = true;
    };
    if (!known) {
        out.err(io, "{s}", .{USAGE});
        die(CF.exit_use);
    }
    const repo = parsed.repo orelse {
        out.fail(io, "no repo folder given", "--repo is required", "pass --repo <repo root>; the app never guesses it");
        die(CF.exit_use);
    };
    const env = init.environ_map;
    const home = parsed.home orelse (os.homePath(env) orelse {
        out.fail(io, "no home folder set", "neither --home nor HOME/USERPROFILE is set", "pass --home <path>");
        die(CF.exit_use);
    });
    const c = conf.confLoad(io, a, parsed.conf_path) catch {
        out.fail(io, "config problem", conf.why, "fix 00-config.json and run again");
        die(CF.exit_use);
    };
    const trash = conf.homeFill(a, c.unpack.trash, home) catch die(CF.exit_fail);
    const now_secs: i64 = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    const e: flow.Env = .{ .io = io, .a = a, .conf = c, .repo = repo, .trash = trash, .now_secs = now_secs, .say = say };

    if (std.mem.eql(u8, parsed.cmd, "status")) {
        const s = flow.status(e) catch |er| flowFail(io, er);
        out.say(io, "bundle: {s}/{s}\nsize: {d} bytes\nsha256: {s}\n", .{ repo, c.bundle.path, s.size, s.sha });
        if (s.cost) |k| out.say(io, "argon2id: time {d} · memory {d} KiB · lanes {d}\n", .{ k.time, k.memo, k.para }) else out.say(io, "argon2id: head not readable (not a secret-bundle file)\n", .{});
        die(CF.exit_ok);
    }
    if (std.mem.eql(u8, parsed.cmd, "pack")) {
        const pass: ?[]const u8 = if (parsed.go) passGet(io, a, env, c, true, true) else null;
        const r = flow.pack(e, pass, parsed.go, parsed.rekey) catch |er| flowFail(io, er);
        out.say(io, "picked {d} files · {d} bytes · skipped: {d} big, {d} browser-profile folders, {d} by pattern, {d} unreadable\n", .{ r.picked, r.bytes, r.skips.big, r.skips.profile, r.skips.glob, r.skips.other });
        if (!parsed.go) out.say(io, "dry-run: nothing sealed or written. Pass --go to seal.\n", .{}) else if (r.unchanged) out.say(io, "bundle already up to date: file left as it is\n", .{}) else out.say(io, "sealed -> {s}/{s} ({d} bytes). Commit it; never share the passphrase through git.\n", .{ repo, c.bundle.path, r.sealed_len });
        die(CF.exit_ok);
    }
    const pass = passGet(io, a, env, c, false, false);
    if (std.mem.eql(u8, parsed.cmd, "check")) {
        const r = flow.check(e, pass) catch |er| flowFail(io, er);
        out.say(io, "bundle {d} files: {d} same · {d} new here · {d} differ\n", .{ r.total, r.same, r.new, r.differs });
        die(if (r.new + r.differs == 0) CF.exit_ok else CF.exit_diff);
    }
    const r = flow.unpack(e, pass, parsed.go) catch |er| flowFail(io, er);
    out.say(io, "bundle {d} files: {d} same · {d} new · {d} differ\n", .{ r.total, r.same, r.new, r.differs });
    if (!parsed.go) out.say(io, "dry-run: nothing written. Pass --go to write.\n", .{}) else {
        out.say(io, "wrote {d} · replaced {d} (old copies in {s}) · same {d}\n", .{ r.counts.written, r.counts.replaced, trash, r.counts.same });
    }
    die(CF.exit_ok);
}

test {
    _ = @import("config-load.zig");
    _ = @import("vault-box.zig");
    _ = @import("glob-match.zig");
    _ = @import("bundle-pick.zig");
    _ = @import("bundle-archive.zig");
    _ = @import("bundle-apply.zig");
    _ = @import("bundle-flow.zig");
    _ = @import("os-layer.zig");
    _ = @import("out-text.zig");
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
