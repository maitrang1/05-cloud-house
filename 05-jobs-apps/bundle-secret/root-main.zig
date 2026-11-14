// =====================================================================
// Des: The CLI entry point - reads flags, loads config, asks for the passphrase, and runs pack / unpack / check / status
// Flo: parse args > load 00-config.json > passphrase (hidden prompt or env var) > run the job > print what happened > exit code
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none - `bundle-secret pack|unpack|check|status|version|help` -- --repo --config --home --go
// Out: exit 0 ok · 1 failed · 2 usage/config · 3 files differ (check)
// Run: cd /home/mai_trang/05-cloud-house/05-jobs-apps/bundle-secret && zig build run -- status --repo <repo>
// Exe: /home/mai_trang/05-cloud-house/05-jobs-apps/bundle-secret/zig-out/bin/bundle-secret
// =====================================================================
const std = @import("std");
const build_options = @import("build_options");
const conf = @import("config-load.zig");
const flow = @import("bundle-flow.zig");
const os = @import("os-layer.zig");
const passf = @import("pass-file.zig");
const sh = @import("ship-flow.zig");
const git_run = @import("git-run.zig");
const sstate = @import("sync-state.zig");
const out = @import("out-text.zig");

const CF = .{ .conf_file = "00-config.json", .exit_ok = 0, .exit_fail = 1, .exit_use = 2, .exit_diff = 3 };

const USAGE =
    \\bundle-secret - seal the shared secrets into one encrypted file that can sit in git, and open it on another device
    \\
    \\Usage: bundle-secret <command> --repo <folder> [flags]
    \\
    \\Commands:
    \\  pack     pick the secret files by the rules in 00-config.json and seal them in the bundle (dry-run unless --go)
    \\  unpack   open the bundle and put the files back in the repo; a different local file is saved to the trash first (dry-run unless --go)
    \\  check    open the bundle and compare it with the files on disk (read-only; exit 3 when they differ)
    \\  fetch    pull the vault repo and write new secrets here; a local file that differs is KEPT (dry-run unless --go)
    \\  ship     pack, commit only the bundle, push; refuses when another device shipped a newer bundle (dry-run unless --go)
    \\  keep-pass save the passphrase to an owner-only file (bundle.pass_file) so you need not type it; checked against the bundle first
    \\  status   show the bundle file: size, Argon2 cost, sha256 (no passphrase)
    \\  version  print the app version
    \\  help     print this text
    \\
    \\Flags:
    \\  --repo <folder>   the repo root (required)
    \\  --config <path>   00-config.json (default: ./00-config.json)
    \\  --home <path>     home folder for {home} in config paths (default: HOME / USERPROFILE)
    \\  --bundle-root <p> folder that holds the bundle file (default: bundle.root in the config; empty there = the repo)
    \\  --go              allow writes; omit for a dry-run
    \\  --replace         fetch only: replace a differing local file (the old copy goes to the trash)
    \\  --reseed          token files (pick.seed_only) are normally copied once and then left alone: with this flag pack/ship put THIS device's copy in the bundle, and fetch/unpack take the bundle's copy over this device's (old copy to the trash)
    \\  --rekey           pack and ship only: replace a bundle that another passphrase made (on purpose)
    \\
    \\Passphrase, first found: the variable named in bundle.pass_envz, then the file bundle.pass_file (owner-only, made by keep-pass), then typed hidden.
    \\Exit codes: 0 ok · 1 failed · 2 usage or config · 3 files differ (check) or the action was refused (fetch kept a local file; ship is stale)
    \\
;

const Args = struct { cmd: []const u8, repo: ?[]const u8 = null, conf_path: []const u8 = CF.conf_file, home: ?[]const u8 = null, go: bool = false, rekey: bool = false, replace: bool = false, reseed: bool = false, bundle_root: ?[]const u8 = null };

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
        if (std.mem.eql(u8, k, "--replace")) {
            r.replace = true;
            continue;
        }
        if (std.mem.eql(u8, k, "--reseed")) {
            r.reseed = true;
            continue;
        }
        if (i + 1 >= argv.len) return null;
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, k, "--repo")) r.repo = v else if (std.mem.eql(u8, k, "--config")) r.conf_path = v else if (std.mem.eql(u8, k, "--home")) r.home = v else if (std.mem.eql(u8, k, "--bundle-root")) r.bundle_root = v else return null;
    }
    return r;
}

fn die(n: u8) noreturn {
    std.process.exit(n);
}

fn say(io: std.Io, text: []const u8) void {
    out.say(io, "{s}", .{text});
}

// the env variable named in config, then the owner-only file (when `use_file`), then typed hidden (twice when `confirm`) ----
fn passGet(io: std.Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, c: conf.Conf, pass_file: []const u8, use_file: bool, confirm: bool, enforce_min: bool) []const u8 {
    if (env.get(c.bundle.pass_envz)) |v| if (v.len > 0) return minCheck(io, v, c, enforce_min);
    if (use_file and pass_file.len > 0) {
        if (passf.read(io, a, pass_file)) |p| return minCheck(io, p, c, enforce_min) else |er| switch (er) {
            error.Missing => {},
            error.TooOpen => {
                out.fail(io, "the passphrase file can be read by other users", pass_file, "run: chmod 600 on that file, or delete it and run keep-pass again");
                die(CF.exit_use);
            },
            error.Empty => {
                out.fail(io, "the passphrase file is empty", pass_file, "run keep-pass again");
                die(CF.exit_use);
            },
            else => {
                out.fail(io, "cannot read the passphrase file", pass_file, "check its permissions, or run keep-pass again");
                die(CF.exit_use);
            },
        }
    }
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
        error.NotSealed => out.fail(io, "this is not a bundle-secret file", "the head is missing or its cost is out of range", "check bundle.path in 00-config.json"),
        error.NoBundle => out.fail(io, "no bundle file", "nothing at <bundle.root>/<bundle.path>", "run pack --go on a device that holds the secrets, then pull"),
        error.PassDiffers => out.fail(io, "the bundle in the repo was made with another passphrase", "replacing it would lock out every device that uses the old one", "retype the right passphrase; to change it on purpose, run pack --go --rekey, then unpack on every device"),
        error.NoVaultRepo => out.fail(io, "the bundle folder is not a git checkout", "it has no .git, so the bundle would land where no sync sees it (bundle.need_git)", "clone the private vault repo into that folder first, or set bundle.root / --bundle-root"),
        error.NoPassFile => out.fail(io, "no passphrase file is set", "bundle.pass_file is empty in the config", "set bundle.pass_file in 00-config.json, or type the passphrase each time"),
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

// this device now holds the bundle it just wrote or read: remember it, so ship and fetch know where this device stands (best effort) ----
fn remember(io: std.Io, a: std.mem.Allocator, e: flow.Env, state_file: []const u8) void {
    const blob = flow.readBundle(e) catch return;
    sstate.write(io, a, state_file, &flow.shaHex(blob)) catch out.err(io, "note: could not save the sync state to {s}\n", .{state_file});
}

fn syncFail(io: std.Io, e: anyerror) noreturn {
    switch (e) {
        error.Stale => {
            out.fail(io, "this device is behind the vault repo", "another device shipped a newer bundle, or this device never fetched it", "run fetch --go first (add --replace to take the bundle's value over a local edit), then ship");
            die(CF.exit_diff);
        },
        error.Diverged => out.fail(io, "the vault repo has diverged from its remote", "local commits and remote commits both exist", "fix it by hand in the vault folder (git status, git log), then run again"),
        error.NoUpstream => out.fail(io, "the vault repo has no upstream branch", "git does not know which remote branch to follow", "in the vault folder run: git push -u origin main"),
        error.NoVaultGit => out.fail(io, "the bundle folder is not a git checkout", "fetch and ship need the vault repo cloned there", "clone the private vault repo into bundle.root first"),
        error.DirtyVault => out.fail(io, "the vault repo has other changes", "only the bundle file may differ from the last commit", "commit or restore them by hand, then run again"),
        error.PushRejected => out.fail(io, "the push was rejected", sh.why, "the vault repo was put back as it was; run fetch --go, then ship again"),
        error.GitFail => out.fail(io, "git failed", sh.why, "check the network and your git login or deploy key for the vault repo, then run again"),
        error.Missing => out.fail(io, "git is not installed", "the program name in git.bin was not found", "install git, or set git.bin in 00-config.json"),
        error.Timeout => out.fail(io, "git took too long", "git.timeout_secs ran out", "check the network, or raise git.timeout_secs"),
        else => flowFail(io, e),
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
        out.say(io, "bundle-secret {s}\n", .{build_options.version});
        die(CF.exit_ok);
    }
    const KNOWN = [_][]const u8{ "pack", "unpack", "check", "status", "keep-pass", "fetch", "ship" };
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
    const pass_file = if (c.bundle.pass_file.len == 0) "" else (conf.homeFill(a, c.bundle.pass_file, home) catch die(CF.exit_fail));
    const state_file = conf.homeFill(a, c.state.file, home) catch die(CF.exit_fail);
    const raw_root = parsed.bundle_root orelse c.bundle.root;
    const bundle_dir = if (raw_root.len == 0) repo else (conf.homeFill(a, raw_root, home) catch die(CF.exit_fail));
    const now_secs: i64 = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    const e: flow.Env = .{ .io = io, .a = a, .conf = c, .repo = repo, .bundle_dir = bundle_dir, .pass_file = pass_file, .trash = trash, .now_secs = now_secs, .say = say };

    if (std.mem.eql(u8, parsed.cmd, "fetch") or std.mem.eql(u8, parsed.cmd, "ship")) {
        const git: git_run.Git = .{ .io = io, .a = a, .env = env, .root = bundle_dir, .bin = c.git.bin, .tmos_secs = c.git.timeout_secs, .outp_maxz = (@as(usize, c.pick.total_maxz_mbyt) + 2) * 1024 * 1024 };
        const sy: sh.Sync = .{ .e = e, .git = git, .state_file = state_file };
        if (std.mem.eql(u8, parsed.cmd, "fetch")) {
            const pw = passGet(io, a, env, c, pass_file, true, false, false);
            const replace = parsed.replace or std.mem.eql(u8, c.fetch.on_differ, "replace");
            const r = sh.fetch(sy, pw, parsed.go, replace, parsed.reseed) catch |er| syncFail(io, er);
            if (r.none) die(CF.exit_ok);
            out.say(io, "bundle {d} files: {d} same · {d} new · {d} differ\n", .{ r.un.total, r.un.same, r.un.new, r.un.differs });
            if (r.conflicts > 0) {
                out.say(io, "{d} local file(s) differ from the bundle and were kept. Look at them; to take the bundle's value run fetch --go --replace (old copies go to {s}).\n", .{ r.conflicts, trash });
                die(CF.exit_diff);
            }
            if (!parsed.go) out.say(io, "dry-run: nothing pulled or written. Pass --go to fetch.\n", .{}) else out.say(io, "in sync with the vault repo (wrote {d} · replaced {d})\n", .{ r.un.counts.written, r.un.counts.replaced });
            die(CF.exit_ok);
        }
        const pw = passGet(io, a, env, c, pass_file, true, parsed.go, true);
        const r = sh.ship(sy, pw, parsed.go, parsed.rekey, parsed.reseed) catch |er| syncFail(io, er);
        out.say(io, "picked {d} files · {d} bytes · skipped: {d} big, {d} browser-profile folders, {d} by pattern, {d} unreadable\n", .{ r.pack.picked, r.pack.bytes, r.pack.skips.big, r.pack.skips.profile, r.pack.skips.glob, r.pack.skips.other });
        if (!parsed.go) out.say(io, "dry-run: nothing sealed, committed or pushed. Pass --go to ship.\n", .{}) else if (r.shipped) out.say(io, "shipped: the bundle is committed and pushed to the vault repo\n", .{}) else out.say(io, "nothing to ship: the bundle is already up to date\n", .{});
        die(CF.exit_ok);
    }
    if (std.mem.eql(u8, parsed.cmd, "status")) {
        const s = flow.status(e) catch |er| flowFail(io, er);
        out.say(io, "bundle: {s}\nsize: {d} bytes\nsha256: {s}\n", .{ flow.bundlePath(e) catch "?", s.size, s.sha });
        if (s.cost) |k| out.say(io, "argon2id: time {d} · memory {d} KiB · lanes {d}\n", .{ k.time, k.memo, k.para }) else out.say(io, "argon2id: head not readable (not a bundle-secret file)\n", .{});
        die(CF.exit_ok);
    }
    if (std.mem.eql(u8, parsed.cmd, "pack")) {
        const pass: ?[]const u8 = if (parsed.go) passGet(io, a, env, c, pass_file, true, true, true) else null;
        const r = flow.pack(e, pass, parsed.go, parsed.rekey, parsed.reseed) catch |er| flowFail(io, er);
        out.say(io, "picked {d} files · {d} bytes · skipped: {d} big, {d} browser-profile folders, {d} by pattern, {d} unreadable\n", .{ r.picked, r.bytes, r.skips.big, r.skips.profile, r.skips.glob, r.skips.other });
        if (parsed.go) remember(io, a, e, state_file);
        if (!parsed.go) out.say(io, "dry-run: nothing sealed or written. Pass --go to seal.\n", .{}) else if (r.unchanged) out.say(io, "bundle already up to date: file left as it is\n", .{}) else out.say(io, "sealed -> {s} ({d} bytes). Commit and push it in that folder; never share the passphrase through git.\n", .{ flow.bundlePath(e) catch "?", r.sealed_len });
        die(CF.exit_ok);
    }
    if (std.mem.eql(u8, parsed.cmd, "keep-pass")) {
        const pw = passGet(io, a, env, c, pass_file, false, true, true);
        const r = flow.keep(e, pw) catch |er| flowFail(io, er);
        out.say(io, "saved the passphrase to {s} (owner-only){s}\n", .{ pass_file, if (r.verified) ", checked against the bundle" else ", no bundle yet so not checked" });
        if (r.replaced) out.say(io, "the old file was copied to {s}\n", .{trash});
        out.say(io, "Keep one more copy of the passphrase offline (password manager or paper): if this disk dies, the bundle cannot be opened.\n", .{});
        die(CF.exit_ok);
    }
    const pass = passGet(io, a, env, c, pass_file, true, false, false);
    if (std.mem.eql(u8, parsed.cmd, "check")) {
        const r = flow.check(e, pass) catch |er| flowFail(io, er);
        out.say(io, "bundle {d} files: {d} same · {d} new here · {d} differ\n", .{ r.total, r.same, r.new, r.differs });
        die(if (r.new + r.differs == 0) CF.exit_ok else CF.exit_diff);
    }
    const r = flow.unpack(e, pass, parsed.go, parsed.reseed) catch |er| flowFail(io, er);
    out.say(io, "bundle {d} files: {d} same · {d} new · {d} differ\n", .{ r.total, r.same, r.new, r.differs });
    if (parsed.go) remember(io, a, e, state_file);
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
    _ = @import("pass-file.zig");
    _ = @import("git-run.zig");
    _ = @import("sync-state.zig");
    _ = @import("ship-flow.zig");
    _ = @import("out-text.zig");
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
