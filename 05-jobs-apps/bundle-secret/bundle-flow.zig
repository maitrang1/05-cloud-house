// =====================================================================
// Des: The four jobs - pack, unpack, check, status - on plain inputs so tests can run them on temp folders
// Flo: pack: pick > encode > (skip if unchanged) > seal > write .part + rename | unpack/check: read > unseal > decode > plan > apply | status: read the file head
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Env (io, allocator, Conf, repo folder, trash folder, time, say), passphrase, go flag
// Out: result structs | FlowErro
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const conf = @import("config-load.zig");
const box = @import("vault-box.zig");
const pick = @import("bundle-pick.zig");
const arc = @import("bundle-archive.zig");
const apply = @import("bundle-apply.zig");
const passf = @import("pass-file.zig");
const gm = @import("glob-match.zig");

const CF = .{ .slack_mbyt = 1, .part = ".part" };

pub const FlowErro = error{ NothingPicked, NoBundle, NoVaultRepo, NoPassFile, WriteFail, PassDiffers } || passf.PassErro || box.BoxErro || arc.ArcErro || pick.PickErro || apply.ApplyErro;

pub const Say = *const fn (std.Io, []const u8) void;

pub const Env = struct {
    io: std.Io,
    a: std.mem.Allocator,
    conf: conf.Conf,
    repo: []const u8,
    bundle_dir: []const u8,
    pass_file: []const u8,
    trash: []const u8,
    now_secs: i64,
    say: Say,
};

fn line(e: Env, comptime fmt: []const u8, args: anytype) void {
    e.say(e.io, std.fmt.allocPrint(e.a, fmt, args) catch return);
}

pub fn bundlePath(e: Env) ![]const u8 {
    return std.fs.path.join(e.a, &.{ e.bundle_dir, e.conf.bundle.path });
}

fn sameDir(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, x, "/\\"), std.mem.trimEnd(u8, y, "/\\"));
}

// the bundle's path inside the scanned repo (so it is never picked itself), or "" when it lives elsewhere ----
fn ownRel(a: std.mem.Allocator, repo: []const u8, file: []const u8) []const u8 {
    const r = std.mem.trimEnd(u8, repo, "/\\");
    if (!std.mem.startsWith(u8, file, r) or file.len <= r.len + 1 or (file[r.len] != '/' and file[r.len] != '\\')) return "";
    const rel = a.dupe(u8, file[r.len + 1 ..]) catch return "";
    std.mem.replaceScalar(u8, rel, '\\', '/');
    return rel;
}

// a bundle folder outside the repo must be a git checkout, or the file would land in a plain folder no sync ever sees ----
fn vaultReady(e: Env) FlowErro!void {
    if (!e.conf.bundle.need_git or sameDir(e.bundle_dir, e.repo)) return;
    const g = std.fs.path.join(e.a, &.{ e.bundle_dir, ".git" }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().access(e.io, g, .{}) catch return error.NoVaultRepo;
}

pub fn readBundle(e: Env) FlowErro![]const u8 {
    const cap: usize = (@as(usize, e.conf.pick.total_maxz_mbyt) + CF.slack_mbyt) * 1024 * 1024;
    const path = try bundlePath(e);
    return std.Io.Dir.cwd().readFileAlloc(e.io, path, e.a, .limited(cap)) catch error.NoBundle;
}

fn costOf(c: conf.Conf) box.Cost {
    return .{ .time = c.argon.time, .memo = c.argon.memo_kbyt, .para = c.argon.para };
}

pub const PackRes = struct { picked: u32, bytes: u64, skips: pick.Skips, wrote: bool, unchanged: bool, sealed_len: u64 };

// dry-run (go = false) needs no passphrase and writes nothing ----
// `reseed`: seed-only files are taken from this device now, not frozen at the bundle's copy ----
pub fn pack(e: Env, pass: ?[]const u8, go: bool, rekey: bool, reseed: bool) FlowErro!PackRes {
    if (go) try vaultReady(e);
    const got = try pick.collect(e.io, e.a, e.repo, e.conf.pick, ownRel(e.a, e.repo, try bundlePath(e)));
    for (got.items) |it| line(e, "{s} {s} ({d} bytes)\n", .{ if (go) "pick" else "would pick", it.rel, it.data.len });
    var res: PackRes = .{ .picked = @intCast(got.items.len), .bytes = got.bytes, .skips = got.skips, .wrote = false, .unchanged = false, .sealed_len = 0 };
    if (got.items.len == 0) return error.NothingPicked;
    if (!go) return res;
    // an existing bundle this passphrase opens: seed-only files keep the bundle's copy, so a token refreshed by a program does not make a new bundle ----
    var was_plain: ?[]u8 = null;
    defer if (was_plain) |w| std.crypto.secureZero(u8, w);
    var old_len: u64 = 0;
    // a bundle that this passphrase cannot open is never replaced by accident (a typo would lock every other device out): --rekey says it is on purpose ----
    if (readBundle(e)) |old| {
        if (box.unseal(e.a, e.io, pass.?, old)) |was| {
            was_plain = was;
            old_len = old.len;
            if (!reseed) if (arc.decode(e.a, was)) |old_items| {
                for (got.items) |*it| {
                    if (!gm.hitAny(e.conf.pick.seed_only, it.rel)) continue;
                    for (old_items) |o| if (std.mem.eql(u8, o.rel, it.rel)) {
                        it.data = o.data;
                        break;
                    };
                }
            } else |_| {};
        } else |_| {
            if (!rekey) return error.PassDiffers;
        }
    } else |_| {}
    const plain = try arc.encode(e.a, got.items);
    defer std.crypto.secureZero(u8, @constCast(plain));
    // same content as the bundle already in the repo: leave the file alone so git history does not grow for nothing ----
    if (was_plain) |w| if (std.mem.eql(u8, w, plain)) {
        res.unchanged = true;
        res.sealed_len = old_len;
        return res;
    };
    const sealed = try box.seal(e.a, e.io, pass.?, plain, costOf(e.conf));
    const path = try bundlePath(e);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(e.io, d) catch return error.WriteFail;
    const part = try std.mem.concat(e.a, u8, &.{ path, CF.part });
    {
        const f = cwd.createFile(e.io, part, .{}) catch return error.WriteFail;
        defer f.close(e.io);
        f.writePositionalAll(e.io, sealed, 0) catch return error.WriteFail;
    }
    cwd.rename(part, cwd, path, e.io) catch return error.WriteFail;
    res.wrote = true;
    res.sealed_len = sealed.len;
    return res;
}

pub const OpenRes = struct { items: []arc.Item, rows: []apply.Row };

pub fn shaHex(blob: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn openBlob(e: Env, pass: []const u8, blob: []const u8, reseed: bool) FlowErro!OpenRes {
    const plain = try box.unseal(e.a, e.io, pass, blob);
    const items = try arc.decode(e.a, plain);
    const rows = try apply.plan(e.io, e.a, e.repo, items, e.conf.pick.seed_only, reseed);
    return .{ .items = items, .rows = rows };
}

pub const UnpackRes = struct { total: u32, new: u32, same: u32, differs: u32, keeps: u32, counts: apply.Counts };

pub fn unpack(e: Env, pass: []const u8, go: bool, reseed: bool) FlowErro!UnpackRes {
    return unpackWith(e, pass, try readBundle(e), go, true, reseed);
}

// go = false: only the plan; go = true: write. A differing local file is saved to the trash and replaced when `replace`, else it stays as it is ----
pub fn unpackWith(e: Env, pass: []const u8, blob: []const u8, go: bool, replace: bool, reseed: bool) FlowErro!UnpackRes {
    const o = try openBlob(e, pass, blob, reseed);
    var r: UnpackRes = .{ .total = @intCast(o.items.len), .new = 0, .same = 0, .differs = 0, .keeps = 0, .counts = .{} };
    for (o.rows) |row| {
        switch (row.state) {
            .new => r.new += 1,
            .same => r.same += 1,
            .differs => r.differs += 1,
        }
        if (row.state != .same) {
            const takes = replace or (reseed and row.seed);
            if (row.state == .differs and !takes) r.keeps += 1;
            const verb = switch (row.state) {
                .new => if (go) "write" else "would write",
                else => if (!takes) "keep (local file differs)" else if (go) "replace (old copy to trash)" else "would replace",
            };
            line(e, "{s} {s}\n", .{ verb, row.rel });
        }
    }
    if (!go) return r;
    const mode = conf.modeOf(e.conf.unpack.file_mode) orelse return error.WriteFail;
    r.counts = try apply.apply(e.io, e.a, e.repo, o.items, o.rows, e.trash, e.now_secs, mode, replace, reseed);
    return r;
}

// read-only: how many files differ from the bundle (the caller turns that into an exit code) ----
pub fn check(e: Env, pass: []const u8) FlowErro!UnpackRes {
    return unpack(e, pass, false, false);
}

pub const KeepRes = struct { verified: bool, replaced: bool };

// save the passphrase to the owner-only file: only after it opens the existing bundle (a typo is never saved); a file already there is copied to the trash first ----
pub fn keep(e: Env, pass: []const u8) FlowErro!KeepRes {
    if (e.pass_file.len == 0) return error.NoPassFile;
    var verified = false;
    if (readBundle(e)) |blob| {
        const plain = try box.unseal(e.a, e.io, pass, blob);
        std.crypto.secureZero(u8, plain);
        verified = true;
    } else |_| {}
    var replaced = false;
    if (passf.exists(e.io, e.pass_file)) {
        const old = std.Io.Dir.cwd().readFileAlloc(e.io, e.pass_file, e.a, .limited(4096)) catch return error.WriteFail;
        const batch = try std.fs.path.join(e.a, &.{ e.trash, try apply.stampOf(e.a, e.now_secs), std.fs.path.basename(e.pass_file) });
        try apply.writeOwner(e.io, batch, old, 0o600, e.a);
        replaced = true;
    }
    try passf.write(e.io, e.a, e.pass_file, pass);
    return .{ .verified = verified, .replaced = replaced };
}

pub const Status = struct { size: u64, cost: ?box.Cost, sha: [64]u8 };

pub fn status(e: Env) FlowErro!Status {
    const blob = try readBundle(e);
    return .{ .size = blob.len, .cost = box.costOf(blob), .sha = shaHex(blob) };
}

// ---- tests: whole flow on temp folders, fake secrets only ----
fn quiet(_: std.Io, _: []const u8) void {}

const TEST_PASS = "correct horse battery";

fn testEnv(a: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !Env {
    var c: conf.Conf = .{};
    c.argon = .{ .time = 1, .memo_kbyt = 8, .para = 1 };
    c.bundle.path = "out/bundle-secret.enc";
    const repo = try std.fs.path.join(a, &.{ root, name });
    return .{ .io = io, .a = a, .conf = c, .repo = repo, .bundle_dir = repo, .pass_file = "", .trash = try std.fs.path.join(a, &.{ root, "trash" }), .now_secs = 1_800_000_000, .say = quiet };
}

fn put(dir: std.Io.Dir, io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

test "pack on A, unpack on B: same files, no plaintext in the bundle, wrong passphrase refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/p/.secrets/key.json", "FAKE-KEY-ONE");
    try put(tmp.dir, io, "A/q/gg-token.json", "FAKE-TOKEN-TWO");
    try put(tmp.dir, io, "A/readme.txt", "not a secret");
    const ea = try testEnv(a, io, root, "A");

    // dry-run writes nothing and needs no passphrase
    const dry = try pack(ea, null, false, false, false);
    try std.testing.expectEqual(@as(u32, 2), dry.picked);
    try std.testing.expect(!dry.wrote);
    try std.testing.expectError(error.NoBundle, status(ea));

    const done = try pack(ea, TEST_PASS, true, false, false);
    try std.testing.expect(done.wrote);
    const st = try status(ea);
    try std.testing.expectEqual(@as(u64, done.sealed_len), st.size);
    try std.testing.expect(st.cost != null);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, raw, "FAKE-KEY-ONE") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "key.json") == null);

    // a second pack with nothing changed leaves the file alone
    const again = try pack(ea, TEST_PASS, true, false, false);
    try std.testing.expect(again.unchanged and !again.wrote);
    const raw2 = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, raw, raw2);

    // device B gets only the bundle file
    try put(tmp.dir, io, "B/out/bundle-secret.enc", raw);
    const eb = try testEnv(a, io, root, "B");
    try std.testing.expectError(error.BadKey, unpack(eb, "wrong passphrase!!", false, false));
    const plan_b = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 2), plan_b.new);
    const res = try unpack(eb, TEST_PASS, true, false);
    try std.testing.expectEqual(@as(u32, 2), res.counts.written);
    const k = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ eb.repo, "p/.secrets/key.json" }), a, .limited(100));
    try std.testing.expectEqualStrings("FAKE-KEY-ONE", k);
    const after = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 2), after.same);
    try std.testing.expectEqual(@as(u32, 0), after.new + after.differs);

    // A changes a secret: a new pack differs, B sees a difference and keeps its own copy in the trash
    try put(tmp.dir, io, "A/p/.secrets/key.json", "FAKE-KEY-ROTATED");
    const rot = try pack(ea, TEST_PASS, true, false, false);
    try std.testing.expect(rot.wrote);
    const raw3 = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try put(tmp.dir, io, "B/out/bundle-secret.enc", raw3);
    const diff = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 1), diff.differs);
    const fin = try unpack(eb, TEST_PASS, true, false);
    try std.testing.expectEqual(@as(u32, 1), fin.counts.replaced);
    const stamp = try apply.stampOf(a, 1_800_000_000);
    const old = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ eb.trash, stamp, "p/.secrets/key.json" }), a, .limited(100));
    try std.testing.expectEqualStrings("FAKE-KEY-ONE", old);
}

test "nothing to pick is an error; a tampered bundle is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/readme.txt", "x");
    const ea = try testEnv(a, io, root, "A");
    try std.testing.expectError(error.NothingPicked, pack(ea, TEST_PASS, true, false, false));
    try put(tmp.dir, io, "A/.secrets/k", "K");
    _ = try pack(ea, TEST_PASS, true, false, false);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    raw[raw.len - 20] ^= 1;
    try put(tmp.dir, io, "A/out/bundle-secret.enc", raw);
    try std.testing.expectError(error.BadKey, check(ea, TEST_PASS));
}
test "a bundle another passphrase made is not replaced unless --rekey is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/.secrets/k", "K1");
    const ea = try testEnv(a, io, root, "A");
    _ = try pack(ea, TEST_PASS, true, false, false);
    const before = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expectError(error.PassDiffers, pack(ea, "another passphrase!!", true, false, false));
    const same = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, before, same);
    const re = try pack(ea, "another passphrase!!", true, true, false);
    try std.testing.expect(re.wrote);
    _ = try check(ea, "another passphrase!!");
    try std.testing.expectError(error.BadKey, check(ea, TEST_PASS));
}
test "the bundle can live in a separate git folder; it must be a checkout; it is never picked itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/p/.secrets/k", "K");
    try put(tmp.dir, io, "V/readme", "vault repo");
    var ea = try testEnv(a, io, root, "A");
    ea.bundle_dir = try std.fs.path.join(a, &.{ root, "V" });
    ea.conf.bundle.path = "bundle-secret.enc";
    // a dry-run needs no vault repo; writing does, and refuses a folder without .git
    try std.testing.expectEqual(@as(u32, 1), (try pack(ea, null, false, false, false)).picked);
    try std.testing.expectError(error.NoVaultRepo, pack(ea, TEST_PASS, true, false, false));
    try tmp.dir.createDirPath(io, "V/.git");
    const r = try pack(ea, TEST_PASS, true, false, false);
    try std.testing.expect(r.wrote);
    try std.testing.expect(!std.mem.eql(u8, ea.repo, ea.bundle_dir));
    _ = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, "V", "bundle-secret.enc" }), a, .limited(1 << 20));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, "A", "bundle-secret.enc" }), a, .limited(10)));
    // need_git off: any folder will do
    var eb = ea;
    eb.bundle_dir = try std.fs.path.join(a, &.{ root, "plain" });
    eb.conf.bundle.need_git = false;
    try std.testing.expect((try pack(eb, TEST_PASS, true, false, false)).wrote);
    // unpack from the vault folder into another repo
    var ec = try testEnv(a, io, root, "C");
    ec.bundle_dir = ea.bundle_dir;
    ec.conf.bundle.path = "bundle-secret.enc";
    const u = try unpack(ec, TEST_PASS, true, false);
    try std.testing.expectEqual(@as(u32, 1), u.counts.written);
    // a bundle that sits inside the scanned repo is never picked
    try put(tmp.dir, io, "A/in/.secrets/own.enc", "x");
    var ed = try testEnv(a, io, root, "A");
    ed.conf.bundle.path = "in/.secrets/own.enc";
    const d = try pack(ed, null, false, false, false);
    try std.testing.expectEqual(@as(u32, 1), d.picked);
    try std.testing.expectEqualStrings("in/.secrets/own.enc", ownRel(a, ed.repo, try bundlePath(ed)));
    try std.testing.expectEqualStrings("", ownRel(a, ed.repo, "/elsewhere/x.enc"));
}
test "keep-pass: saved only when it opens the bundle; an old file goes to the trash; the file reads back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/.secrets/k", "K");
    var ea = try testEnv(a, io, root, "A");
    try std.testing.expectError(error.NoPassFile, keep(ea, TEST_PASS));
    ea.pass_file = try std.fs.path.join(a, &.{ root, "home", "v.pass" });
    // no bundle yet: saved, but not verified
    const first = try keep(ea, TEST_PASS);
    try std.testing.expect(!first.verified and !first.replaced);
    try std.testing.expectEqualStrings(TEST_PASS, try passf.read(io, a, ea.pass_file));
    _ = try pack(ea, TEST_PASS, true, false, false);
    // a wrong passphrase never reaches the file
    try std.testing.expectError(error.BadKey, keep(ea, "not the right one!!!"));
    try std.testing.expectEqualStrings(TEST_PASS, try passf.read(io, a, ea.pass_file));
    // the right one replaces it; the old file is kept in the trash
    const again = try keep(ea, TEST_PASS);
    try std.testing.expect(again.verified and again.replaced);
    const stamp = try apply.stampOf(a, ea.now_secs);
    const old = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ ea.trash, stamp, "v.pass" }), a, .limited(200));
    try std.testing.expect(std.mem.startsWith(u8, old, TEST_PASS));
}
test "seed-only files: a refreshed token does not make a new bundle, a new one is added, and fetch never calls it a conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/p/.secrets/key", "KEY");
    try put(tmp.dir, io, "A/p/.secrets/gg-token.json", "TOKEN-1");
    const ea = try testEnv(a, io, root, "A");
    _ = try pack(ea, TEST_PASS, true, false, false);
    // the program refreshes the token: the bundle is left alone
    try put(tmp.dir, io, "A/p/.secrets/gg-token.json", "TOKEN-2");
    try std.testing.expect((try pack(ea, TEST_PASS, true, false, false)).unchanged);
    // a new seed-only file is added; the old one keeps the bundle's copy
    try put(tmp.dir, io, "A/p/.secrets/other-token.json", "OTHER");
    try std.testing.expect((try pack(ea, TEST_PASS, true, false, false)).wrote);
    // device B gets the seeds once, keeps its own refreshed copy afterwards, and a real secret still counts
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try put(tmp.dir, io, "B/out/bundle-secret.enc", raw);
    const eb = try testEnv(a, io, root, "B");
    const first = try unpack(eb, TEST_PASS, true, false);
    try std.testing.expectEqual(@as(u32, 3), first.counts.written);
    try std.testing.expectEqualStrings("TOKEN-1", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ eb.repo, "p/.secrets/gg-token.json" }), a, .limited(100)));
    try put(tmp.dir, io, "B/p/.secrets/gg-token.json", "B-REFRESHED");
    const chk = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 0), chk.differs + chk.new);
    try put(tmp.dir, io, "B/p/.secrets/key", "B-CHANGED-KEY");
    try std.testing.expectEqual(@as(u32, 1), (try check(eb, TEST_PASS)).differs);
}
test "reseed: pack puts this device's token in the bundle; fetch/unpack with reseed take the bundle's token over a local one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    try put(tmp.dir, io, "A/p/.secrets/gg-token.json", "TOKEN-1");
    const ea = try testEnv(a, io, root, "A");
    _ = try pack(ea, TEST_PASS, true, false, false);
    // the owner re-authorizes on A: a normal pack ignores it, a reseed pack publishes it
    try put(tmp.dir, io, "A/p/.secrets/gg-token.json", "TOKEN-NEW-AUTH");
    try std.testing.expect((try pack(ea, TEST_PASS, true, false, false)).unchanged);
    const re = try pack(ea, TEST_PASS, true, false, true);
    try std.testing.expect(re.wrote);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    // B holds the old token; a plain unpack leaves it, an unpack with reseed takes the new one
    try put(tmp.dir, io, "B/out/bundle-secret.enc", raw);
    try put(tmp.dir, io, "B/p/.secrets/gg-token.json", "TOKEN-1");
    const eb = try testEnv(a, io, root, "B");
    try std.testing.expectEqual(@as(u32, 0), (try check(eb, TEST_PASS)).differs);
    const plain = try unpack(eb, TEST_PASS, true, false);
    try std.testing.expectEqual(@as(u32, 0), plain.counts.replaced);
    try std.testing.expectEqualStrings("TOKEN-1", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ eb.repo, "p/.secrets/gg-token.json" }), a, .limited(100)));
    const seeded = try unpack(eb, TEST_PASS, true, true);
    try std.testing.expectEqual(@as(u32, 1), seeded.counts.replaced);
    try std.testing.expectEqualStrings("TOKEN-NEW-AUTH", try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ eb.repo, "p/.secrets/gg-token.json" }), a, .limited(100)));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
