// =====================================================================
// Des: Writes the app's private ssh config: one Host block per git host with its own key, so one `git push` can reach GitHub, GitLab and Forgejo with the right key each
// Flo: config host rows > fill {keys} and {home} in each key path > skip rows whose key file is missing > build the text > write it only when it differs (0600)
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (conf.sshc rows, secret folder, user home, known_hosts path)
// Out: the file `<secret folder>/<sshc.file>`; sshPath() for `ssh -F`
// Run: not run directly - imported by github-repo.zig and root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const ctxm = @import("app-ctx.zig");
const conf = @import("config-load.zig");

const CF = .{ .head = "# written by the github app from 00-config.json (sshc.hosts): edit the config, not this file\n" };

// forward slashes read the same on every OS and need no escaping inside quotes ----
fn slashed(a: std.mem.Allocator, p: []const u8) ![]u8 {
    const out = try a.dupe(u8, p);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn fill(a: std.mem.Allocator, text: []const u8, keys_dir: []const u8, keyz: []const u8, user_home: []const u8) ![]u8 {
    const one = try std.mem.replaceOwned(u8, a, text, "{keys}", keys_dir);
    const two = try std.mem.replaceOwned(u8, a, one, "{keyz}", keyz);
    return std.mem.replaceOwned(u8, a, two, "{home}", user_home);
}

// the whole file text; `have` says whether a key file exists (so tests need no disk) ----
pub fn build(a: std.mem.Allocator, hosts: []const conf.SshHost, keys_dir: []const u8, keyz: []const u8, user_home: []const u8, known: []const u8, have: *const fn (ctx: ?*anyopaque, path: []const u8) bool, ctx: ?*anyopaque) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, CF.head);
    for (hosts) |h| {
        const key = try slashed(a, try fill(a, h.key, keys_dir, keyz, user_home));
        if (!have(ctx, key)) continue;
        try out.print(a, "Host {s}\n  HostName {s}\n  Port {d}\n  User {s}\n  IdentityFile \"{s}\"\n  IdentitiesOnly yes\n", .{ h.name, h.host, h.port, h.user, key });
    }
    try out.print(a, "Host *\n  UserKnownHostsFile \"{s}\"\n  StrictHostKeyChecking accept-new\n", .{try slashed(a, known)});
    return out.items;
}

fn haveFile(ctx: ?*anyopaque, path: []const u8) bool {
    const c: *ctxm.Ctx = @ptrCast(@alignCast(ctx.?));
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}

pub fn sshPath(ctx: *const ctxm.Ctx) ![]const u8 {
    return ctx.path(&.{ ctx.home, ctx.conf.sshc.file });
}

// write the config when it differs from the file on disk; owner-only on POSIX ----
pub fn ensure(ctx: *ctxm.Ctx) !void {
    const keys_dir = try ctx.path(&.{ ctx.home, ctx.conf.data.keys });
    const known = try ctx.hostPath();
    const text = try build(ctx.a, ctx.conf.sshc.hosts, keys_dir, ctx.conf.sshz.keyz_name, ctx.user_home, known, &haveFile, ctx);
    const path = try sshPath(ctx);
    const cwd = std.Io.Dir.cwd();
    const have = cwd.readFileAlloc(ctx.io, path, ctx.a, .limited(64 * 1024)) catch null;
    if (have != null and std.mem.eql(u8, have.?, text)) return;
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(ctx.io, d);
    const part = try std.mem.concat(ctx.a, u8, &.{ path, ".part" });
    {
        const f = try cwd.createFile(ctx.io, part, if (comptime builtin.os.tag == .windows) .{} else .{ .permissions = .fromMode(0o600) });
        defer f.close(ctx.io);
        try f.writePositionalAll(ctx.io, text, 0);
    }
    try std.Io.Dir.rename(cwd, part, cwd, path, ctx.io);
}

fn yes(_: ?*anyopaque, _: []const u8) bool {
    return true;
}

fn onlyGit(_: ?*anyopaque, path: []const u8) bool {
    return std.mem.indexOf(u8, path, "gitlab") == null;
}

test "build: one block per host with its key, a row without a key file is skipped, paths with spaces and backslashes stay in one piece" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hosts = [_]conf.SshHost{
        .{ .name = "github", .host = "github.com", .key = "{keys}/{keyz}" },
        .{ .name = "gitlab", .host = "gitlab.com", .key = "{home}/.ssh/id_ed25519_gitlab" },
        .{ .name = "forgejo", .host = "127.0.0.1", .port = 2222, .key = "{home}/.ssh/id_ed25519_forgejo" },
    };
    const text = try build(a, &hosts, "C:\\Users\\Dell 7750\\.05-cloud-house-secre\\github-keys", "id_ed25519", "C:\\Users\\Dell 7750", "C:\\Users\\Dell 7750\\known", &onlyGit, null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host github\n  HostName github.com\n  Port 22\n  User git\n  IdentityFile \"C:/Users/Dell 7750/.05-cloud-house-secre/github-keys/id_ed25519\"\n  IdentitiesOnly yes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host gitlab") == null); // key file missing: no block
    try std.testing.expect(std.mem.indexOf(u8, text, "Host forgejo\n  HostName 127.0.0.1\n  Port 2222\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Host *\n  UserKnownHostsFile \"C:/Users/Dell 7750/known\"\n  StrictHostKeyChecking accept-new\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\") == null); // no backslash anywhere
    const all = try build(a, &hosts, "/k", "id_ed25519", "/h", "/known", &yes, null);
    try std.testing.expect(std.mem.indexOf(u8, all, "Host gitlab") != null);
}

test "ensure: writes the file once with owner-only rights, a second call leaves it alone, the generated text names only hosts with a key" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "sec/github-keys");
    try tmp.dir.writeFile(io, .{ .sub_path = "sec/github-keys/id_ed25519", .data = "k" });
    var env = std.process.Environ.Map.init(a);
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    const hosts = [_]conf.SshHost{
        .{ .name = "github", .host = "github.com", .key = "{keys}/{keyz}" },
        .{ .name = "gitlab", .host = "gitlab.com", .key = "{home}/.ssh/nope" },
    };
    var c: ctxm.Ctx = .{ .io = io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = try std.fs.path.join(a, &.{ base, "sec" }), .user_home = base, .root = "/r", .conf_dirz = "" };
    c.conf.sshc.hosts = &hosts;
    try ensure(&c);
    const text1 = try tmp.dir.readFileAlloc(io, "sec/github-ssh_config", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, text1, "Host github") != null and std.mem.indexOf(u8, text1, "Host gitlab") == null);
    if (comptime builtin.os.tag != .windows) {
        const stt = try tmp.dir.statFile(io, "sec/github-ssh_config", .{});
        try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stt.permissions.toMode() & 0o777)));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "sec/.ssh-probe", .data = "x" });
    try ensure(&c); // same text: nothing rewritten
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "sec/github-ssh_config.part", .{}));
    c.conf.sshc.hosts = &.{};
    try ensure(&c); // the host list changed: the file follows
    const text2 = try tmp.dir.readFileAlloc(io, "sec/github-ssh_config", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, text2, "Host github") == null);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
