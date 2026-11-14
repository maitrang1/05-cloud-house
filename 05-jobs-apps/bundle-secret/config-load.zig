// =====================================================================
// Des: Reads 00-config.json, refuses any unknown or wrong setting, and names the exact line and column of a mistake
// Flo: read file > strict JSON parse into Conf > value checks > Conf (every tunable of the app lives here, none in the other files)
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json
// Out: Conf | ConfErro (why holds the one-line reason)
// Run: not run directly - imported by root-main.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const box = @import("vault-box.zig");

const CF = .{ .vers = 1, .file_maxz = 64 * 1024, .name_maxz = 128, .kbyt_maxz = 1048576, .mbyt_maxz = 4096, .pass_floor = 8, .pass_ceil = 1024 };

pub const ConfErro = error{ Missing, Unreadable, BadJson, BadValue, OutOfMemory };

pub const Pick = struct {
    dirs: []const []const u8 = &.{".secrets"},
    files: []const []const u8 = &.{ "*token.json", "*client_secret.json", "*credentials.json" },
    skip_dirs: []const []const u8 = &.{ ".git", "zig-out", ".zig-cache", "node_modules", "zzzz-delete-force-items" },
    skip_markers: []const []const u8 = &.{ "Local State", "Preferences" },
    skip: []const []const u8 = &.{"*session*"},
    seed_only: []const []const u8 = &.{"*token.json"},
    file_maxz_kbyt: u32 = 256,
    total_maxz_mbyt: u32 = 64,
};
pub const Bundle = struct { root: []const u8 = "{home}/05-cloud-house-vault", path: []const u8 = "bundle-secret.enc", need_git: bool = true, pass_file: []const u8 = "{home}/.05-cloud-house-secre/05-cloud-house-vault.pass", pass_envz: []const u8 = "BUNDLE_SECRET_PASS", pass_min: u32 = 16 };
pub const Argon = struct { time: u32 = 3, memo_kbyt: u32 = 65536, para: u32 = 1 };
pub const Unpack = struct { file_mode: []const u8 = "600", trash: []const u8 = "{home}/.05-cloud-house-secre/bundle-trash" };
pub const GitCf = struct { bin: []const u8 = "git", timeout_secs: u32 = 120 };
pub const FetchCf = struct { on_differ: []const u8 = "keep" };
pub const ShipCf = struct { message: []const u8 = "update bundle" };
pub const StateCf = struct { file: []const u8 = "{home}/.05-cloud-house-secre/bundle-secret-state.json" };
pub const Conf = struct { vers: u32 = CF.vers, pick: Pick = .{}, bundle: Bundle = .{}, argon: Argon = .{}, unpack: Unpack = .{}, git: GitCf = .{}, fetch: FetchCf = .{}, ship: ShipCf = .{}, state: StateCf = .{} };

var why_buf: [512]u8 = undefined;
pub var why: []const u8 = "";

fn note(comptime fmt: []const u8, args: anytype) void {
    why = std.fmt.bufPrint(&why_buf, fmt, args) catch "config problem";
}

fn bad(comptime fmt: []const u8, args: anytype) ConfErro {
    note(fmt, args);
    return error.BadValue;
}

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ConfErro![]const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| {
        note("{s}: {s}", .{ path, @errorName(e) });
        return if (e == error.FileNotFound) error.Missing else error.Unreadable;
    };
    return if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
}

// strict: unknown key or wrong type is refused with line and column ----
pub fn parse(a: std.mem.Allocator, text: []const u8, label: []const u8) ConfErro!Conf {
    var scan = std.json.Scanner.initCompleteInput(a, text);
    var diag: std.json.Diagnostics = .{};
    scan.enableDiagnostics(&diag);
    return std.json.parseFromTokenSourceLeaky(Conf, a, &scan, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        note("{s}: {s} at line {d}, column {d}", .{ label, @errorName(e), diag.getLine(), diag.getColumn() });
        return error.BadJson;
    };
}

// {home} in a path setting becomes the home folder (or --home) ----
pub fn homeFill(a: std.mem.Allocator, text: []const u8, home: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, text, "{home}", home);
}

// octal text such as "600" (owner only); anything with group or other bits is refused ----
pub fn modeOf(text: []const u8) ?u32 {
    if (text.len < 3 or text.len > 4) return null;
    const m = std.fmt.parseInt(u32, text, 8) catch return null;
    if (m > 0o777 or m & 0o077 != 0 or m & 0o400 == 0) return null;
    return m;
}

fn nameList(label: []const u8, list: []const []const u8, slash_ok: bool) ConfErro!void {
    for (list) |n| {
        if (n.len == 0 or n.len > CF.name_maxz) return bad("{s}: an entry is empty or longer than {d}", .{ label, CF.name_maxz });
        if (!slash_ok and std.mem.indexOfAny(u8, n, "/\\") != null) return bad("{s}: '{s}' must be a plain name, not a path", .{ label, n });
    }
}

fn envName(n: []const u8) bool {
    if (n.len == 0 or n.len > CF.name_maxz) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

// a folder or file setting: empty (switched off), {home}/..., or an absolute path ----
fn homeOrAbs(p: []const u8) bool {
    return p.len == 0 or std.mem.startsWith(u8, p, "{home}") or p[0] == '/' or (p.len > 2 and p[1] == ':');
}

pub fn check(c: *const Conf) ConfErro!void {
    if (c.vers != CF.vers) return bad("vers must be {d}", .{CF.vers});
    if (c.pick.dirs.len == 0 and c.pick.files.len == 0) return bad("pick: dirs and files are both empty, nothing would be picked", .{});
    try nameList("pick.dirs", c.pick.dirs, false);
    try nameList("pick.skip_dirs", c.pick.skip_dirs, false);
    try nameList("pick.skip_markers", c.pick.skip_markers, false);
    try nameList("pick.files", c.pick.files, true);
    try nameList("pick.skip", c.pick.skip, true);
    try nameList("pick.seed_only", c.pick.seed_only, true);
    if (c.pick.file_maxz_kbyt < 1 or c.pick.file_maxz_kbyt > CF.kbyt_maxz) return bad("pick.file_maxz_kbyt must be 1..{d}", .{CF.kbyt_maxz});
    if (c.pick.total_maxz_mbyt < 1 or c.pick.total_maxz_mbyt > CF.mbyt_maxz) return bad("pick.total_maxz_mbyt must be 1..{d}", .{CF.mbyt_maxz});
    if (!homeOrAbs(c.bundle.root)) return bad("bundle.root must be empty (the scanned repo), start with {{home}}, or be an absolute path", .{});
    if (!homeOrAbs(c.bundle.pass_file)) return bad("bundle.pass_file must be empty (no file), start with {{home}}, or be an absolute path", .{});
    const bp = c.bundle.path;
    if (bp.len == 0 or bp[0] == '/' or bp[0] == '\\' or std.mem.indexOfAny(u8, bp, ":\\") != null) return bad("bundle.path must be a relative path with '/' separators", .{});
    var it = std.mem.splitScalar(u8, bp, '/');
    while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return bad("bundle.path must not hold '', '.' or '..' parts", .{});
    if (!envName(c.bundle.pass_envz)) return bad("bundle.pass_envz must be an environment variable name (letters, digits, _)", .{});
    if (c.bundle.pass_min < CF.pass_floor or c.bundle.pass_min > CF.pass_ceil) return bad("bundle.pass_min must be {d}..{d}", .{ CF.pass_floor, CF.pass_ceil });
    if (!box.costOkay(.{ .time = c.argon.time, .memo = c.argon.memo_kbyt, .para = c.argon.para })) return bad("argon: time 1..16, memo_kbyt 8..1048576, para 1..8", .{});
    if (modeOf(c.unpack.file_mode) == null) return bad("unpack.file_mode must be octal owner-only, such as 600", .{});
    if (c.unpack.trash.len == 0) return bad("unpack.trash must not be empty", .{});
    if (c.git.bin.len == 0 or std.mem.indexOfAny(u8, c.git.bin, " \t\r\n") != null) return bad("git.bin must be one program name or path, without spaces", .{});
    if (c.git.timeout_secs < 5 or c.git.timeout_secs > 3600) return bad("git.timeout_secs must be 5..3600", .{});
    if (!std.mem.eql(u8, c.fetch.on_differ, "keep") and !std.mem.eql(u8, c.fetch.on_differ, "replace")) return bad("fetch.on_differ must be keep or replace", .{});
    if (c.ship.message.len == 0 or c.ship.message.len > CF.name_maxz or std.mem.indexOfAny(u8, c.ship.message, "\r\n") != null) return bad("ship.message must be one line of 1..{d} characters", .{CF.name_maxz});
    if (c.state.file.len == 0 or !homeOrAbs(c.state.file)) return bad("state.file must start with {{home}} or be an absolute path", .{});
}

pub fn confLoad(io: std.Io, a: std.mem.Allocator, path: []const u8) ConfErro!Conf {
    const c = try parse(a, try readAll(io, a, path), path);
    try check(&c);
    return c;
}

test "shipped config parses and equals the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try confLoad(std.testing.io, a, "00-config.json");
    const d: Conf = .{};
    try std.testing.expectEqual(d.vers, c.vers);
    try std.testing.expectEqual(d.argon, c.argon);
    try std.testing.expectEqual(d.bundle.pass_min, c.bundle.pass_min);
    try std.testing.expectEqualStrings(d.bundle.path, c.bundle.path);
    try std.testing.expectEqualStrings(d.bundle.root, c.bundle.root);
    try std.testing.expectEqual(d.bundle.need_git, c.bundle.need_git);
    try std.testing.expectEqualStrings(d.bundle.pass_file, c.bundle.pass_file);
    try std.testing.expectEqualStrings(d.bundle.pass_envz, c.bundle.pass_envz);
    try std.testing.expectEqual(d.pick.file_maxz_kbyt, c.pick.file_maxz_kbyt);
    try std.testing.expectEqual(d.pick.total_maxz_mbyt, c.pick.total_maxz_mbyt);
    try std.testing.expectEqual(d.pick.dirs.len, c.pick.dirs.len);
    try std.testing.expectEqual(d.pick.files.len, c.pick.files.len);
    try std.testing.expectEqual(d.pick.skip_dirs.len, c.pick.skip_dirs.len);
    try std.testing.expectEqual(d.pick.skip_markers.len, c.pick.skip_markers.len);
    try std.testing.expectEqual(d.pick.seed_only.len, c.pick.seed_only.len);
    try std.testing.expectEqual(d.pick.skip.len, c.pick.skip.len);
    try std.testing.expectEqualStrings(d.unpack.trash, c.unpack.trash);
    try std.testing.expectEqualStrings(d.unpack.file_mode, c.unpack.file_mode);
    try std.testing.expectEqualStrings(d.git.bin, c.git.bin);
    try std.testing.expectEqual(d.git.timeout_secs, c.git.timeout_secs);
    try std.testing.expectEqualStrings(d.fetch.on_differ, c.fetch.on_differ);
    try std.testing.expectEqualStrings(d.ship.message, c.ship.message);
    try std.testing.expectEqualStrings(d.state.file, c.state.file);
}

test "unknown key is refused with line and column; bad values are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadJson, parse(a, "{\n \"vers\": 1,\n \"nope\": 2\n}", "t.json"));
    try std.testing.expect(std.mem.indexOf(u8, why, "line 3") != null);
    const cases = [_][]const u8{
        \\{"vers":2}
        ,
        \\{"pick":{"dirs":[],"files":[]}}
        ,
        \\{"pick":{"dirs":["a/b"]}}
        ,
        \\{"pick":{"seed_only":[""]}}
        ,
        \\{"pick":{"file_maxz_kbyt":0}}
        ,
        \\{"pick":{"total_maxz_mbyt":99999}}
        ,
        \\{"bundle":{"path":"/abs/x.enc"}}
        ,
        \\{"bundle":{"path":"a/../x.enc"}}
        ,
        \\{"bundle":{"path":"a\\x.enc"}}
        ,
        \\{"bundle":{"root":"relative/folder"}}
        ,
        \\{"bundle":{"pass_file":"rel/x.pass"}}
        ,
        \\{"bundle":{"pass_envz":"BAD NAME"}}
        ,
        \\{"bundle":{"pass_min":3}}
        ,
        \\{"argon":{"time":0}}
        ,
        \\{"unpack":{"file_mode":"644"}}
        ,
        \\{"unpack":{"file_mode":"7"}}
        ,
        \\{"unpack":{"trash":""}}
        ,
        \\{"git":{"bin":"git status"}}
        ,
        \\{"git":{"timeout_secs":1}}
        ,
        \\{"fetch":{"on_differ":"overwrite"}}
        ,
        \\{"ship":{"message":""}}
        ,
        \\{"ship":{"message":"two\nlines"}}
        ,
        \\{"state":{"file":""}}
        ,
        \\{"state":{"file":"relative.json"}}
    };
    for (cases) |text| {
        const c = try parse(a, text, "t.json");
        try std.testing.expectError(error.BadValue, check(&c));
    }
    const good = try parse(a, "{\"unpack\":{\"file_mode\":\"0600\"}}", "t.json");
    try check(&good);
    for ([_][]const u8{ "", "{home}/v", "/abs/v", "C:\\v" }) |root| {
        var ok_conf: Conf = .{};
        ok_conf.bundle.root = root;
        ok_conf.bundle.pass_file = root;
        try check(&ok_conf);
    }
}

test "modes: owner-only octal only; home placeholder fills" {
    try std.testing.expectEqual(@as(?u32, 0o600), modeOf("600"));
    try std.testing.expectEqual(@as(?u32, 0o700), modeOf("0700"));
    try std.testing.expectEqual(@as(?u32, null), modeOf("640"));
    try std.testing.expectEqual(@as(?u32, null), modeOf("abc"));
    try std.testing.expectEqual(@as(?u32, null), modeOf("1700"));
    const a = std.testing.allocator;
    const p = try homeFill(a, "{home}/x", "/h/me");
    defer a.free(p);
    try std.testing.expectEqualStrings("/h/me/x", p);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
