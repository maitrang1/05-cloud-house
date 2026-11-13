// =====================================================================
// Des: Reads the app settings file and the step list file, refuses any unknown or wrong setting, and names the exact line and column of a mistake
// Flo: read file > strip BOM > strict JSON parse into typed structs > range checks > Conf / Steps
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of 00-config.json or 10-steps.json, arena allocator
// Out: Conf or Steps (arena-owned) | ConfErro, with `why` filled for the user
// Run: not run directly - imported by app-ctx.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

const CF = .{ .file_maxz = 256 * 1024, .vers = 1, .why_size = 240 };

pub const ConfErro = error{ Missing, Unreadable, BadJson, BadValue, OutOfMemory };

pub const Http = struct {
    apiz_base: []const u8 = "https://api.github.com",
    webz_base: []const u8 = "https://github.com",
    apiz_vers: []const u8 = "2022-11-28",
    user_agen: []const u8 = "cloud-house-github",
    tmos_secs: u32 = 30,
    retr_maxz: u32 = 3,
    wait_maxz_secs: u32 = 120,
    body_maxz_kbyt: u32 = 2048,
};

pub const Auth = struct {
    mode: []const u8 = "device",
    clie_iden: []const u8 = "",
    scop: []const u8 = "repo workflow read:user user:email write:public_key",
    poll_maxz_secs: u32 = 900,
};

pub const Acct = struct { logi: []const u8 = "", mail: []const u8 = "" };

// where the app keeps its private files (state, audit, vault, keys, account); names are plain, the folder is shared by every cloud-house app ----
pub const Data = struct {
    root: []const u8 = "{home}/.05-cloud-house-secre",
    acct: []const u8 = "github-account.json",
    stat: []const u8 = "github-state.json",
    vaul: []const u8 = "github-main.vault",
    audi: []const u8 = "github-audit.jsonl",
    keys: []const u8 = "github-keys",
    host: []const u8 = "github-known_hosts",
};

pub const Sign = struct {
    name_base: []const u8 = "",
    name_trys: u32 = 20,
    pass_size: u32 = 24,
    path_form: []const u8 = "/signup",
    path_devi: []const u8 = "/login/device",
    path_twof: []const u8 = "/settings/security",
    path_keys: []const u8 = "/settings/keys",
    path_apps: []const u8 = "/settings/applications",
};

pub const Guid = struct { poll_secs: u32 = 5, tmos_secs: u32 = 600 };

pub const Osiz = struct { brow_open: bool = true, clip_copy: bool = true, clip_clea_secs: u32 = 60, clip_osc5: bool = true, clip_tool: []const []const u8 = &.{}, brow_tool: []const []const u8 = &.{} };

pub const Vaul = struct { pass_envz: []const u8 = "CLOUD_HOUSE_VAULT_PASS", argo_time: u32 = 3, argo_memo_kbyt: u32 = 65536, argo_para: u32 = 1 };

pub const Repo = struct {
    nest_okay: bool = false,
    name: []const u8 = "",
    visi: []const u8 = "private",
    bran: []const u8 = "main",
    desc: []const u8 = "",
    wiki: bool = false,
    proj: bool = false,
    merg_dele: bool = true,
    comm_text: []const u8 = "first commit",
    publ_text: []const u8 = "sync from the work tree",
    remo: []const u8 = "origin",
};

// the helper programs the app runs: name or full path ----
pub const Tool = struct { gitz: []const u8 = "git", ghcl: []const u8 = "gh" };

// one git host the app pushes to: its own key, port and user; a host whose key file does not exist yet is skipped ----
pub const SshHost = struct { name: []const u8, host: []const u8, port: u32 = 22, user: []const u8 = "git", key: []const u8 };

// the private ssh config the app writes (one Host block per row), used through `ssh -F` ----
pub const Sshc = struct { file: []const u8 = "github-ssh_config", hosts: []const SshHost = &.{} };

pub const Gitz = struct { scop: []const u8 = "local", prot: []const u8 = "ssh", crlf: []const u8 = "input", tmos_secs: u32 = 300 };

pub const Sshz = struct {
    keyz_name: []const u8 = "id_ed25519_deploy",
    kind: []const u8 = "deploy",
    titl: []const u8 = "cloud-house",
    host_test: bool = true,
    host_user: []const u8 = "git@github.com",
    host_tmos_secs: u32 = 20,
};

pub const File = struct { igno: []const []const u8 = &.{}, attr: []const []const u8 = &.{} };

pub const Mark = struct { pref: []const u8, tail: u32 = 0 };

pub const Scan = struct {
    name: []const []const u8 = &.{},
    mark: []const Mark = &.{},
    skip: []const []const u8 = &.{},
    wind_kbyt: u32 = 512,
    file_maxz_mbyt: u32 = 100,
};

pub const Rule = struct { onzz: bool = true, name: []const u8 = "main-guard", pull_need: bool = false, forc_bloc: bool = true, dele_bloc: bool = true };

pub const Secr = struct { name: []const u8, vaul: []const u8, need: bool = false };

pub const Ciiz = struct {
    onzz: bool = true,
    dir_path: []const u8 = ".github/workflows",
    drop: []const []const u8 = &.{},
    tmpl_file: []const u8 = "20-build.yml",
    comm_text: []const u8 = "ci: add per-app workflows",
    kill_name: []const u8 = "CI_KILL",
    runz_tmos_secs: u32 = 900,
    runs_on: []const u8 = "ubuntu-slim",
    job_tmos_mins: u32 = 15,
    zig_vers: []const u8 = "0.16.0",
    zig_base: []const u8 = "https://ziglang.org/download",
    cache: bool = true,
    rele: bool = true,
    rele_runs_on: []const u8 = "ubuntu-latest",
    rele_tmos_mins: u32 = 60,
    rele_targets: []const []const u8 = &.{ "x86_64-linux", "x86_64-windows" },
    secr: []const Secr = &.{},
};

pub const Ghcr = struct { onzz: bool = false };

pub const Mirr = struct { name: []const u8, urlz: []const u8, onzz: bool = false };

// local `test` and `build` commands: one app at a time, named by the user; build_opt is the -Doptimize value ----
pub const Task = struct { test_cmd: []const []const u8 = &.{ "zig", "build", "test" }, build_opt: []const u8 = "ReleaseSafe", tmos_secs: u32 = 900, retr: u32 = 1 };

pub const Push = struct {
    skip_dirs: []const []const u8 = &.{},
    allo: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    keep: []const []const u8 = &.{},
    trash: []const u8 = "",
    file_maxz_kbyt: u32 = 1024,
};

pub const Warn = struct { repo_maxz_mbyt: u32 = 1024, pack_maxz_mbyt: u32 = 500, acti_free_usd: u32 = 12, acti_rate_milli: u32 = 2, perc: u32 = 80 };

pub const Conf = struct {
    vers: u32 = CF.vers,
    data: Data = .{},
    tool: Tool = .{},
    sshc: Sshc = .{},
    http: Http = .{},
    auth: Auth = .{},
    acct: Acct = .{},
    sign: Sign = .{},
    guid: Guid = .{},
    osiz: Osiz = .{},
    vaul: Vaul = .{},
    repo: Repo = .{},
    gitz: Gitz = .{},
    sshz: Sshz = .{},
    file: File = .{},
    scan: Scan = .{},
    rule: Rule = .{},
    ciiz: Ciiz = .{},
    ghcr: Ghcr = .{},
    mirr: []const Mirr = &.{},
    push: Push = .{},
    task: Task = .{},
    warn: Warn = .{},
};

pub const Kind = enum { auto, guide, ask };

pub const Step = struct {
    numb: u32,
    iden: []const u8,
    kind: Kind,
    acts: []const u8,
    hand: u32 = 0,
    name: []const u8,
    need: []const u8 = "nothing",
    done: []const u8 = "",
};

pub const Steps = struct { vers: u32 = CF.vers, vend: []const u8, step: []const Step };

// last parse problem in plain words, for the caller to print ----
pub var why_buf: [CF.why_size]u8 = undefined;
pub var why: []const u8 = "";

fn note(comptime fmt: []const u8, args: anytype) void {
    why = std.fmt.bufPrint(&why_buf, fmt, args) catch "config problem (message too long)";
}

fn readAll(io: std.Io, a: std.mem.Allocator, path: []const u8) ConfErro![]const u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| {
        note("{s}: {s}", .{ path, @errorName(e) });
        return if (e == error.FileNotFound) error.Missing else error.Unreadable;
    };
    return if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) raw[3..] else raw;
}

// {home} in a path setting becomes the home folder (or --home) ----
pub fn homeFill(a: std.mem.Allocator, text: []const u8, home: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, text, "{home}", home);
}

// account.json overrides acct.logi / acct.mail when it exists and a field is non-empty; a missing file is fine ----
pub fn acctOverride(io: std.Io, a: std.mem.Allocator, path: []const u8, c: *Conf) ConfErro!void {
    const text = readAll(io, a, path) catch |e| {
        if (e == error.Missing) return;
        return e;
    };
    const o = try parse(Acct, a, text, path);
    if (o.logi.len > 0) c.acct.logi = o.logi;
    if (o.mail.len > 0) c.acct.mail = o.mail;
}

// strict: unknown key or wrong type is refused with line and column ----
pub fn parse(comptime T: type, a: std.mem.Allocator, text: []const u8, label: []const u8) ConfErro!T {
    var scan = std.json.Scanner.initCompleteInput(a, text);
    var diag: std.json.Diagnostics = .{};
    scan.enableDiagnostics(&diag);
    return std.json.parseFromTokenSourceLeaky(T, a, &scan, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        note("{s}: {s} at line {d}, column {d}", .{ label, @errorName(e), diag.getLine(), diag.getColumn() });
        return error.BadJson;
    };
}

fn oneOf(v: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |x| if (std.mem.eql(u8, v, x)) return true;
    return false;
}

// a base URL must be https, or loopback http when the build allows a mock ----
pub fn baseOkay(url: []const u8, mock: bool) bool {
    if (std.mem.indexOfAny(u8, url, "@?# ") != null) return false;
    if (std.mem.endsWith(u8, url, "/")) return false;
    if (std.mem.startsWith(u8, url, "https://")) return url.len > "https://".len;
    if (!mock) return false;
    const pre = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, url, pre)) return false;
    _ = std.fmt.parseInt(u16, url[pre.len..], 10) catch return false;
    return true;
}

pub fn check(c: *const Conf, mock: bool) ConfErro!void {
    if (c.vers != CF.vers) return bad("vers must be {d}", .{CF.vers});
    if (c.data.root.len == 0) return bad("data.root must not be empty", .{});
    inline for (.{ "acct", "stat", "vaul", "audi", "keys", "host" }) |k| {
        const v = @field(c.data, k);
        if (v.len == 0 or std.mem.indexOfAny(u8, v, "/\\") != null) return bad("data." ++ k ++ " must be a plain file name", .{});
    }
    if (!baseOkay(c.http.apiz_base, mock)) return bad("http.apiz_base must be an https URL without a trailing slash", .{});
    if (!baseOkay(c.http.webz_base, mock)) return bad("http.webz_base must be an https URL without a trailing slash", .{});
    if (c.http.tmos_secs < 1 or c.http.tmos_secs > 600) return bad("http.tmos_secs must be 1..600", .{});
    if (c.http.retr_maxz > 10) return bad("http.retr_maxz must be 0..10", .{});
    if (c.http.body_maxz_kbyt < 16 or c.http.body_maxz_kbyt > 65536) return bad("http.body_maxz_kbyt must be 16..65536", .{});
    if (!oneOf(c.auth.mode, &.{ "device", "gh" })) return bad("auth.mode must be device or gh", .{});
    if (c.auth.scop.len == 0) return bad("auth.scop must not be empty", .{});
    if (c.sign.name_trys < 1 or c.sign.name_trys > 200) return bad("sign.name_trys must be 1..200", .{});
    if (c.sign.pass_size < 16 or c.sign.pass_size > 64) return bad("sign.pass_size must be 16..64", .{});
    if (c.guid.poll_secs < 1 or c.guid.poll_secs > 300) return bad("guid.poll_secs must be 1..300", .{});
    if (c.vaul.pass_envz.len == 0) return bad("vaul.pass_envz must name an environment variable", .{});
    if (c.vaul.argo_time < 1 or c.vaul.argo_time > 16) return bad("vaul.argo_time must be 1..16", .{});
    if (c.vaul.argo_memo_kbyt < 8 or c.vaul.argo_memo_kbyt > 1048576) return bad("vaul.argo_memo_kbyt must be 8..1048576", .{});
    if (c.vaul.argo_para < 1 or c.vaul.argo_para > 8) return bad("vaul.argo_para must be 1..8", .{});
    if (!oneOf(c.repo.visi, &.{ "private", "public" })) return bad("repo.visi must be private or public", .{});
    if (c.push.file_maxz_kbyt < 1 or c.push.file_maxz_kbyt > 65536) return bad("push.file_maxz_kbyt must be 1..65536", .{});
    for (c.push.skip_dirs) |d| if (d.len == 0 or std.mem.indexOfAny(u8, d, "/\\") != null) return bad("push.skip_dirs must be plain folder names", .{});
    if (c.repo.remo.len == 0 or std.mem.indexOfAny(u8, c.repo.remo, " /\\") != null) return bad("repo.remo must be a plain remote name like origin", .{});
    if (c.tool.gitz.len == 0 or c.tool.ghcl.len == 0) return bad("tool.gitz and tool.ghcl must not be empty", .{});
    if (c.sshc.file.len == 0 or std.mem.indexOfAny(u8, c.sshc.file, "/\\") != null) return bad("sshc.file must be a plain file name", .{});
    for (c.sshc.hosts, 0..) |h, i| {
        if (h.name.len == 0 or h.host.len == 0 or h.key.len == 0) return bad("sshc.hosts rows need name, host and key", .{});
        if (std.mem.indexOfAny(u8, h.host, " \t\"'#") != null or std.mem.indexOfAny(u8, h.user, " \t\"'#") != null) return bad("sshc.hosts host and user must be plain words", .{});
        if (h.port < 1 or h.port > 65535) return bad("sshc.hosts port must be 1..65535", .{});
        for (c.sshc.hosts[0..i]) |o| if (std.mem.eql(u8, o.name, h.name)) return bad("sshc.hosts names must be unique", .{});
    }
    if (c.repo.bran.len == 0) return bad("repo.bran must not be empty", .{});
    if (!oneOf(c.gitz.scop, &.{ "local", "global" })) return bad("gitz.scop must be local or global", .{});
    if (!oneOf(c.gitz.prot, &.{ "ssh", "https" })) return bad("gitz.prot must be ssh or https", .{});
    if (!oneOf(c.gitz.crlf, &.{ "input", "false", "true" })) return bad("gitz.crlf must be input, false or true", .{});
    if (c.gitz.tmos_secs < 5) return bad("gitz.tmos_secs must be 5 or more", .{});
    if (c.sshz.keyz_name.len == 0 or std.mem.indexOfAny(u8, c.sshz.keyz_name, "/\\") != null) return bad("sshz.keyz_name must be a plain file name", .{});
    if (!oneOf(c.sshz.kind, &.{ "deploy", "account" })) return bad("sshz.kind must be deploy or account", .{});
    if (c.task.tmos_secs < 10 or c.task.retr > 3) return bad("task.tmos_secs must be 10 or more and task.retr 0..3", .{});
    if (c.task.test_cmd.len == 0 or c.task.build_opt.len == 0) return bad("task.test_cmd and task.build_opt must not be empty", .{});
    if (c.ciiz.dir_path.len == 0 or std.mem.startsWith(u8, c.ciiz.dir_path, "/") or std.mem.indexOf(u8, c.ciiz.dir_path, "..") != null) return bad("ciiz.dir_path must be a relative folder like .github/workflows", .{});
    for (c.ciiz.drop) |d| if (d.len == 0 or std.mem.indexOfAny(u8, d, "/\\") != null) return bad("ciiz.drop entries are plain file names", .{});
    if (c.warn.perc < 1 or c.warn.perc > 100) return bad("warn.perc must be 1..100", .{});
    for (c.scan.mark) |m| if (m.pref.len < 4) return bad("scan.mark pref must be 4 letters or more", .{});
    if (c.ciiz.runs_on.len == 0 or c.ciiz.zig_vers.len == 0 or c.ciiz.zig_base.len == 0) return bad("ciiz.runs_on, zig_vers and zig_base must not be empty", .{});
    if (c.ciiz.job_tmos_mins < 1 or c.ciiz.job_tmos_mins > 360) return bad("ciiz.job_tmos_mins must be 1..360", .{});
    if (c.warn.acti_free_usd < 1 or c.warn.acti_rate_milli < 1) return bad("warn.acti_free_usd and acti_rate_milli must be 1 or more", .{});
    if (c.ciiz.rele_tmos_mins < 1 or c.ciiz.rele_tmos_mins > 360) return bad("ciiz.rele_tmos_mins must be 1..360", .{});
    if (c.ciiz.rele_runs_on.len == 0) return bad("ciiz.rele_runs_on must name a runner", .{});
    if (c.ciiz.rele and c.ciiz.rele_targets.len == 0) return bad("ciiz.rele_targets must list a target", .{});
    for (c.ciiz.rele_targets) |t| for (t) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-')) return bad("ciiz.rele_targets entries are plain target names like x86_64-linux", .{});
    for (c.ciiz.secr) |s| if (s.name.len == 0 or s.vaul.len == 0) return bad("ciiz.secr rows need name and vaul", .{});
    for (c.mirr) |m| if (m.name.len == 0 or m.urlz.len == 0) return bad("mirr rows need name and urlz", .{});
}

fn bad(comptime fmt: []const u8, args: anytype) ConfErro {
    note(fmt, args);
    return error.BadValue;
}

pub fn confLoad(io: std.Io, a: std.mem.Allocator, path: []const u8, mock: bool) ConfErro!Conf {
    const c = try parse(Conf, a, try readAll(io, a, path), path);
    try check(&c, mock);
    return c;
}

pub fn stepLoad(io: std.Io, a: std.mem.Allocator, path: []const u8) ConfErro!Steps {
    const s = try parse(Steps, a, try readAll(io, a, path), path);
    if (s.vers != CF.vers) return bad("{s}: vers must be {d}", .{ path, CF.vers });
    if (s.step.len == 0) return bad("{s}: no steps", .{path});
    for (s.step, 0..) |row, i| {
        if (row.iden.len == 0 or row.acts.len == 0) return bad("{s}: step {d} needs iden and acts", .{ path, i });
        for (s.step[0..i]) |old| if (std.mem.eql(u8, old.iden, row.iden)) return bad("{s}: step iden '{s}' is used twice", .{ path, row.iden });
    }
    return s;
}

test "shipped config and steps parse, defaults match the shipped file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try confLoad(std.testing.io, a, "00-config.json", false);
    const d: Conf = .{};
    try std.testing.expectEqualStrings(d.http.apiz_base, c.http.apiz_base);
    try std.testing.expectEqualStrings(d.auth.scop, c.auth.scop);
    try std.testing.expectEqualStrings(d.vaul.pass_envz, c.vaul.pass_envz);
    try std.testing.expectEqual(d.http, Http{ .apiz_base = d.http.apiz_base, .webz_base = d.http.webz_base, .apiz_vers = d.http.apiz_vers, .user_agen = d.http.user_agen, .tmos_secs = c.http.tmos_secs, .retr_maxz = c.http.retr_maxz, .wait_maxz_secs = c.http.wait_maxz_secs, .body_maxz_kbyt = c.http.body_maxz_kbyt });
    try std.testing.expectEqual(d.vaul.argo_memo_kbyt, c.vaul.argo_memo_kbyt);
    try std.testing.expectEqual(d.guid, c.guid);
    try std.testing.expectEqual(d.warn, c.warn);
    try std.testing.expectEqual(@as(usize, 9), c.scan.mark.len);
    try std.testing.expectEqual(false, c.ghcr.onzz);
    try std.testing.expectEqual(@as(usize, 0), c.mirr.len);
    const s = try stepLoad(std.testing.io, a, "10-steps.json");
    try std.testing.expectEqual(@as(usize, 20), s.step.len);
    var hand: u32 = 0;
    for (s.step) |row| hand = @max(hand, row.hand);
    try std.testing.expectEqual(@as(u32, 4), hand);
}

test "unknown key is refused with line and column; bad values are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.BadJson, parse(Conf, a, "{\n  \"htpp\": {}\n}", "t"));
    try std.testing.expect(std.mem.indexOf(u8, why, "line 2") != null);
    var c: Conf = .{};
    try check(&c, false);
    c.http.apiz_base = "http://127.0.0.1:9";
    try std.testing.expectError(error.BadValue, check(&c, false));
    try check(&c, true);
    c.http.apiz_base = "http://127.0.0.1:9@evil.test";
    try std.testing.expectError(error.BadValue, check(&c, true));
    c.http.apiz_base = "http://evil.test";
    try std.testing.expectError(error.BadValue, check(&c, true));
    c = .{};
    c.auth.mode = "pat";
    try std.testing.expectError(error.BadValue, check(&c, false));
    c = .{};
    c.vaul.argo_memo_kbyt = 1;
    try std.testing.expectError(error.BadValue, check(&c, false));
    c = .{};
    c.sshz.kind = "repo";
    try std.testing.expectError(error.BadValue, check(&c, false));
    c.sshz.kind = "account";
    try check(&c, false);
    c = .{};
    c.task.test_cmd = &.{};
    try std.testing.expectError(error.BadValue, check(&c, false));
    c = .{};
    c.task.retr = 4;
    try std.testing.expectError(error.BadValue, check(&c, false));
    c = .{};
    c.ciiz.dir_path = "../outside";
    try std.testing.expectError(error.BadValue, check(&c, false));
    c.ciiz.dir_path = "/abs";
    try std.testing.expectError(error.BadValue, check(&c, false));
    c = .{};
    c.ciiz.drop = &.{"sub/build.yml"};
    try std.testing.expectError(error.BadValue, check(&c, false));
    c.ciiz.drop = &.{"build.yml"};
    try check(&c, false);
}

test "account.json fills logi and mail; a missing file changes nothing; an unknown key is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "github-account.json" });
    var c: Conf = .{};
    try acctOverride(io, a, path, &c);
    try std.testing.expectEqualStrings("", c.acct.mail);
    try tmp.dir.writeFile(io, .{ .sub_path = "github-account.json", .data = "{\"logi\":\"ann\",\"mail\":\"ann@example.com\"}" });
    try acctOverride(io, a, path, &c);
    try std.testing.expectEqualStrings("ann", c.acct.logi);
    try std.testing.expectEqualStrings("ann@example.com", c.acct.mail);
    try tmp.dir.writeFile(io, .{ .sub_path = "github-account.json", .data = "{\"logi\":\"\"}" });
    try acctOverride(io, a, path, &c);
    try std.testing.expectEqualStrings("ann", c.acct.logi);
    try tmp.dir.writeFile(io, .{ .sub_path = "github-account.json", .data = "{\"pass\":\"x\"}" });
    try std.testing.expectError(error.BadJson, acctOverride(io, a, path, &c));
    const shipped = try confLoad(io, a, "00-config.json", false);
    try std.testing.expectEqualStrings("", shipped.acct.mail); // the synced file carries no personal value
    try std.testing.expectEqualStrings("", shipped.acct.logi);
}

test "homeFill puts the home folder into path settings; the shipped trash path carries no machine name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/u/me/.x", try homeFill(a, "{home}/.x", "/u/me"));
    try std.testing.expectEqualStrings("plain", try homeFill(a, "plain", "/u/me"));
    const shipped = try confLoad(std.testing.io, a, "00-config.json", false);
    try std.testing.expect(std.mem.startsWith(u8, shipped.push.trash, "{home}/"));
    try std.testing.expect(std.mem.indexOf(u8, shipped.data.root, "{home}") != null);
}

test "repo.visi: private by default, public allowed, anything else refused; shipped push rules load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: Conf = .{};
    try std.testing.expectEqualStrings("private", c.repo.visi);
    c.repo.visi = "public";
    try check(&c, false);
    c.repo.visi = "open";
    try std.testing.expectError(error.BadValue, check(&c, false));
    const shipped = try confLoad(std.testing.io, a, "00-config.json", false);
    try std.testing.expectEqualStrings("public", shipped.repo.visi);
    try std.testing.expect(shipped.push.allo.len > 0 and shipped.push.skip_dirs.len > 0);
}

test "a BOM is stripped and duplicate step ids are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "c.json", .data = "\xEF\xBB\xBF{\"vers\":1}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "s.json", .data = "{\"vend\":\"gith\",\"step\":[{\"numb\":0,\"iden\":\"a\",\"kind\":\"auto\",\"acts\":\"x\",\"name\":\"n\"},{\"numb\":1,\"iden\":\"a\",\"kind\":\"ask\",\"acts\":\"y\",\"name\":\"n\"}]}" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const cp = try std.fs.path.join(a, &.{ buf[0..n], "c.json" });
    const sp = try std.fs.path.join(a, &.{ buf[0..n], "s.json" });
    _ = try confLoad(std.testing.io, a, cp, false);
    try std.testing.expectError(error.BadValue, stepLoad(std.testing.io, a, sp));
    try std.testing.expectError(error.Missing, confLoad(std.testing.io, a, "no-such-file.json", false));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
