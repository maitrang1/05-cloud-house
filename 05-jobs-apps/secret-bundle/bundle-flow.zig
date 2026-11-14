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

const CF = .{ .slack_mbyt = 1, .part = ".part" };

pub const FlowErro = error{ NothingPicked, NoBundle, WriteFail, PassDiffers } || box.BoxErro || arc.ArcErro || pick.PickErro || apply.ApplyErro;

pub const Say = *const fn (std.Io, []const u8) void;

pub const Env = struct {
    io: std.Io,
    a: std.mem.Allocator,
    conf: conf.Conf,
    repo: []const u8,
    trash: []const u8,
    now_secs: i64,
    say: Say,
};

fn line(e: Env, comptime fmt: []const u8, args: anytype) void {
    e.say(e.io, std.fmt.allocPrint(e.a, fmt, args) catch return);
}

fn bundlePath(e: Env) ![]const u8 {
    return std.fs.path.join(e.a, &.{ e.repo, e.conf.bundle.path });
}

fn readBundle(e: Env) FlowErro![]const u8 {
    const cap: usize = (@as(usize, e.conf.pick.total_maxz_mbyt) + CF.slack_mbyt) * 1024 * 1024;
    const path = try bundlePath(e);
    return std.Io.Dir.cwd().readFileAlloc(e.io, path, e.a, .limited(cap)) catch error.NoBundle;
}

fn costOf(c: conf.Conf) box.Cost {
    return .{ .time = c.argon.time, .memo = c.argon.memo_kbyt, .para = c.argon.para };
}

pub const PackRes = struct { picked: u32, bytes: u64, skips: pick.Skips, wrote: bool, unchanged: bool, sealed_len: u64 };

// dry-run (go = false) needs no passphrase and writes nothing ----
pub fn pack(e: Env, pass: ?[]const u8, go: bool, rekey: bool) FlowErro!PackRes {
    const got = try pick.collect(e.io, e.a, e.repo, e.conf.pick, e.conf.bundle.path);
    for (got.items) |it| line(e, "{s} {s} ({d} bytes)\n", .{ if (go) "pick" else "would pick", it.rel, it.data.len });
    var res: PackRes = .{ .picked = @intCast(got.items.len), .bytes = got.bytes, .skips = got.skips, .wrote = false, .unchanged = false, .sealed_len = 0 };
    if (got.items.len == 0) return error.NothingPicked;
    if (!go) return res;
    const plain = try arc.encode(e.a, got.items);
    defer std.crypto.secureZero(u8, @constCast(plain));
    // same content as the bundle already in the repo: leave the file alone so git history does not grow for nothing ----
    // a bundle that this passphrase cannot open is never replaced by accident (a typo would lock every other device out): --rekey says it is on purpose ----
    if (readBundle(e)) |old| {
        if (box.unseal(e.a, e.io, pass.?, old)) |was| {
            defer std.crypto.secureZero(u8, was);
            if (std.mem.eql(u8, was, plain)) {
                res.unchanged = true;
                res.sealed_len = old.len;
                return res;
            }
        } else |_| {
            if (!rekey) return error.PassDiffers;
        }
    } else |_| {}
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

fn openAll(e: Env, pass: []const u8) FlowErro!OpenRes {
    const blob = try readBundle(e);
    const plain = try box.unseal(e.a, e.io, pass, blob);
    const items = try arc.decode(e.a, plain);
    const rows = try apply.plan(e.io, e.a, e.repo, items);
    return .{ .items = items, .rows = rows };
}

pub const UnpackRes = struct { total: u32, new: u32, same: u32, differs: u32, counts: apply.Counts };

// go = false: only the plan; go = true: write, saving a different local file to the trash first ----
pub fn unpack(e: Env, pass: []const u8, go: bool) FlowErro!UnpackRes {
    const o = try openAll(e, pass);
    var r: UnpackRes = .{ .total = @intCast(o.items.len), .new = 0, .same = 0, .differs = 0, .counts = .{} };
    for (o.rows) |row| {
        switch (row.state) {
            .new => r.new += 1,
            .same => r.same += 1,
            .differs => r.differs += 1,
        }
        if (row.state != .same) line(e, "{s} {s}\n", .{ if (go) (if (row.state == .new) "write" else "replace (old copy to trash)") else (if (row.state == .new) "would write" else "would replace"), row.rel });
    }
    if (!go) return r;
    const mode = conf.modeOf(e.conf.unpack.file_mode) orelse return error.WriteFail;
    r.counts = try apply.apply(e.io, e.a, e.repo, o.items, o.rows, e.trash, e.now_secs, mode);
    return r;
}

// read-only: how many files differ from the bundle (the caller turns that into an exit code) ----
pub fn check(e: Env, pass: []const u8) FlowErro!UnpackRes {
    return unpack(e, pass, false);
}

pub const Status = struct { size: u64, cost: ?box.Cost, sha: [64]u8 };

pub fn status(e: Env) FlowErro!Status {
    const blob = try readBundle(e);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
    return .{ .size = blob.len, .cost = box.costOf(blob), .sha = std.fmt.bytesToHex(digest, .lower) };
}

// ---- tests: whole flow on temp folders, fake secrets only ----
fn quiet(_: std.Io, _: []const u8) void {}

const TEST_PASS = "correct horse battery";

fn testEnv(a: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !Env {
    var c: conf.Conf = .{};
    c.argon = .{ .time = 1, .memo_kbyt = 8, .para = 1 };
    c.bundle.path = "out/secret-bundle.enc";
    return .{ .io = io, .a = a, .conf = c, .repo = try std.fs.path.join(a, &.{ root, name }), .trash = try std.fs.path.join(a, &.{ root, "trash" }), .now_secs = 1_800_000_000, .say = quiet };
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
    const dry = try pack(ea, null, false, false);
    try std.testing.expectEqual(@as(u32, 2), dry.picked);
    try std.testing.expect(!dry.wrote);
    try std.testing.expectError(error.NoBundle, status(ea));

    const done = try pack(ea, TEST_PASS, true, false);
    try std.testing.expect(done.wrote);
    const st = try status(ea);
    try std.testing.expectEqual(@as(u64, done.sealed_len), st.size);
    try std.testing.expect(st.cost != null);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, raw, "FAKE-KEY-ONE") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "key.json") == null);

    // a second pack with nothing changed leaves the file alone
    const again = try pack(ea, TEST_PASS, true, false);
    try std.testing.expect(again.unchanged and !again.wrote);
    const raw2 = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, raw, raw2);

    // device B gets only the bundle file
    try put(tmp.dir, io, "B/out/secret-bundle.enc", raw);
    const eb = try testEnv(a, io, root, "B");
    try std.testing.expectError(error.BadKey, unpack(eb, "wrong passphrase!!", false));
    const plan_b = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 2), plan_b.new);
    const res = try unpack(eb, TEST_PASS, true);
    try std.testing.expectEqual(@as(u32, 2), res.counts.written);
    const k = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ eb.repo, "p/.secrets/key.json" }), a, .limited(100));
    try std.testing.expectEqualStrings("FAKE-KEY-ONE", k);
    const after = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 2), after.same);
    try std.testing.expectEqual(@as(u32, 0), after.new + after.differs);

    // A changes a secret: a new pack differs, B sees a difference and keeps its own copy in the trash
    try put(tmp.dir, io, "A/p/.secrets/key.json", "FAKE-KEY-ROTATED");
    const rot = try pack(ea, TEST_PASS, true, false);
    try std.testing.expect(rot.wrote);
    const raw3 = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try put(tmp.dir, io, "B/out/secret-bundle.enc", raw3);
    const diff = try check(eb, TEST_PASS);
    try std.testing.expectEqual(@as(u32, 1), diff.differs);
    const fin = try unpack(eb, TEST_PASS, true);
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
    try std.testing.expectError(error.NothingPicked, pack(ea, TEST_PASS, true, false));
    try put(tmp.dir, io, "A/.secrets/k", "K");
    _ = try pack(ea, TEST_PASS, true, false);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    raw[raw.len - 20] ^= 1;
    try put(tmp.dir, io, "A/out/secret-bundle.enc", raw);
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
    _ = try pack(ea, TEST_PASS, true, false);
    const before = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expectError(error.PassDiffers, pack(ea, "another passphrase!!", true, false));
    const same = try std.Io.Dir.cwd().readFileAlloc(io, try bundlePath(ea), a, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, before, same);
    const re = try pack(ea, "another passphrase!!", true, true);
    try std.testing.expect(re.wrote);
    _ = try check(ea, "another passphrase!!");
    try std.testing.expectError(error.BadKey, check(ea, TEST_PASS));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
