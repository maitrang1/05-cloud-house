// =====================================================================
// Des: The shared way every GitHub step talks to GitHub - builds the call with the login token, reads the JSON answer, and turns a refusal into plain words
// Flo: path + body > add headers and Bearer token from the vault > net-http call > Resp ; refusals > what / why / fix
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, method, API path (starts with /), optional JSON body
// Out: http.Resp | error ; read() = typed JSON or null ; refuse() = Outc.fail
// Run: not run directly - imported by github-account.zig, github-repo.zig, github-ci.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const http = @import("net-http.zig");
const ctxm = @import("app-ctx.zig");
const Ctx = ctxm.Ctx;

const CF = .{ .acce = "application/vnd.github+json", .json = "application/json", .form = "application/x-www-form-urlencoded", .toke_keyz = "auth.toke", .mess_maxz = 160 };

pub const TOKE_KEYZ = CF.toke_keyz;

pub const ApizErro = error{NoToken};

const Mess = struct { message: []const u8 = "" };

pub fn token(ctx: *Ctx) !?[]const u8 {
    if (std.mem.eql(u8, ctx.conf.auth.mode, "gh")) return ghToken(ctx);
    return ctx.secret(CF.toke_keyz);
}

// gh mode: ask `gh` every run, so a refreshed scope list is used at once and no old token lingers in the vault ----
fn ghToken(ctx: *Ctx) !?[]const u8 {
    if (ctx.gh_tok.len > 0) return ctx.gh_tok;
    const got = ctx.gitz("").tool(&.{ ctx.conf.tool.ghcl, "auth", "token" }) catch return null;
    if (!got.okay() or got.text().len == 0) return null;
    ctx.gh_tok = try ctx.a.dupe(u8, got.text());
    ctx.audi.hideAdd(ctx.gh_tok);
    return ctx.gh_tok;
}

// one API call; `auth` adds the Bearer token and fails without one ----
pub fn call(ctx: *Ctx, meth: std.http.Method, path: []const u8, body: ?[]const u8, auth: bool) !http.Resp {
    const url = try std.mem.concat(ctx.a, u8, &.{ ctx.conf.http.apiz_base, path });
    var head: [4]std.http.Header = undefined;
    var n: usize = 0;
    head[n] = .{ .name = "accept", .value = CF.acce };
    n += 1;
    head[n] = .{ .name = "x-github-api-version", .value = ctx.conf.http.apiz_vers };
    n += 1;
    if (body != null) {
        head[n] = .{ .name = "content-type", .value = CF.json };
        n += 1;
    }
    if (auth) {
        const tok = (try token(ctx)) orelse return error.NoToken;
        head[n] = .{ .name = "authorization", .value = try std.mem.concat(ctx.a, u8, &.{ "Bearer ", tok }) };
        n += 1;
    }
    return http.call(ctx.io, ctx.a, ctx.httpOpts(), .{ .meth = meth, .urlz = url, .head = head[0..n], .body = body });
}

pub fn getz(ctx: *Ctx, path: []const u8) !http.Resp {
    return call(ctx, .GET, path, null, true);
}

// percent-encode one form or path value ----
pub fn enc(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try list.append(a, c);
        } else try list.print(a, "%{X:0>2}", .{c});
    }
    return list.items;
}

pub const Pair = struct { []const u8, []const u8 };

// login endpoints live on the web host and take a form, never the API token ----
pub fn form(ctx: *Ctx, path: []const u8, pairs: []const Pair) !http.Resp {
    const url = try std.mem.concat(ctx.a, u8, &.{ ctx.conf.http.webz_base, path });
    var body: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |p, i| {
        if (i > 0) try body.append(ctx.a, '&');
        try body.print(ctx.a, "{s}={s}", .{ p[0], try enc(ctx.a, p[1]) });
    }
    const head = [_]std.http.Header{ .{ .name = "accept", .value = CF.json }, .{ .name = "content-type", .value = CF.form } };
    return http.call(ctx.io, ctx.a, ctx.httpOpts(), .{ .meth = .POST, .urlz = url, .head = &head, .body = body.items });
}

pub fn read(comptime T: type, ctx: *Ctx, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, ctx.a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

pub fn json(ctx: *Ctx, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(ctx.a, value, .{ .emit_null_optional_fields = false });
}

// a non-2xx answer in plain words; the vendor's own message is kept, redacted and cut ----
pub fn refuse(ctx: *Ctx, r: http.Resp, what: []const u8) ctxm.Outc {
    const mess = if (read(Mess, ctx, r.body)) |m| m.message else "";
    const cut = ctx.audi.redact(mess[0..@min(mess.len, CF.mess_maxz)]);
    const why = std.fmt.allocPrint(ctx.a, "GitHub answered {d}{s}{s}", .{ r.code, if (cut.len > 0) ": " else "", cut }) catch "GitHub refused the call";
    const fix: []const u8 = switch (r.code) {
        401 => "the login is no longer accepted: run the same command again to log in again",
        403 => if (r.wait > 0 or r.left == 0) "rate limit reached: wait, then run the same command again" else "the login lacks a permission: check auth.scop in 00-config.json, then log in again",
        404 => "the item is missing or the login may not see it: check the name and auth.scop",
        422 => "GitHub rejected the values: read the message above and fix the config",
        else => "run the same command again; if it repeats, check https://www.githubstatus.com",
    };
    return ctxm.fail(what, why, fix);
}

test "gh mode takes the token from gh (cached per run), device mode needs the vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    var st: @import("state-file.zig").State = .{ .a = a, .path = "" };
    var au: @import("audit-log.zig").Audit = .{ .a = a };
    var c: ctxm.Ctx = .{ .io = std.testing.io, .a = a, .env = &env, .conf = .{}, .steps = .{ .vend = "gith", .step = &.{} }, .stat = &st, .audi = &au, .home = "/h", .root = "/r", .conf_dirz = "" };
    c.conf.auth.mode = "gh";
    c.gh_tok = "gho_cached_value";
    try std.testing.expectEqualStrings("gho_cached_value", (try token(&c)).?);
    c.conf.auth.mode = "device"; // no --live: the vault stays closed
    try std.testing.expectError(error.NoPass, token(&c));
}

test "enc keeps safe characters and escapes the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("repo%20workflow%20read%3Auser", try enc(arena.allocator(), "repo workflow read:user"));
    try std.testing.expectEqualStrings("a-b_c.d~e", try enc(arena.allocator(), "a-b_c.d~e"));
    try std.testing.expectEqualStrings("urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code", try enc(arena.allocator(), "urn:ietf:params:oauth:grant-type:device_code"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
