// =====================================================================
// Des: The GitHub side of the mirror. Hands GitHub the GitLab push token as an encrypted Actions secret, sets the on/off variable, and reads the last mirror run.
// Flo: typed call > build url > http call with GitHub headers > map status > parse (secrets are sealed to the repo key first)
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: API base url, GitHub token, owner/repo, typed arguments
// Out: typed results or a typed error (never prints)
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("http-call.zig");

const Seal = std.crypto.nacl.SealedBox;
const b64s = std.base64.standard;

const CF = .{ .acce = "application/vnd.github+json", .headAcce = "Accept", .headVers = "X-GitHub-Api-Version" };

pub const Erro = error{ Unauthorized, Forbidden, NotFound, Conflict, RateLimited, ApiError, BadJson, BadKey };

// wire shapes: field names are GitHub's
const Pkey = struct { key_id: []const u8, key: []const u8 };
const Varz = struct { name: []const u8 = "", value: []const u8 = "" };
pub const Runz = struct { status: ?[]const u8 = null, conclusion: ?[]const u8 = null };
const Runs = struct { workflow_runs: []const Runz = &.{} };

pub const Gith = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    http: *http.Http,
    apiz: []const u8,
    vers: []const u8,
    toke: []const u8,
    owne: []const u8,
    repo: []const u8,

    fn codeErro(code: u16) Erro {
        return switch (code) {
            401 => error.Unauthorized,
            403 => error.Forbidden,
            404 => error.NotFound,
            409 => error.Conflict,
            429 => error.RateLimited,
            else => error.ApiError,
        };
    }

    // one call under /repos/<owner>/<repo>/actions/
    fn call(self: *Gith, meth: std.http.Method, tail: []const u8, body: ?[]const u8) !http.Resp {
        const urlz = try std.fmt.allocPrint(self.gpa, "{s}/repos/{s}/{s}/actions/{s}", .{ self.apiz, self.owne, self.repo, tail });
        const head = try self.gpa.dupe(http.Head, &.{ .{ .name = CF.headAcce, .value = CF.acce }, .{ .name = CF.headVers, .value = self.vers } });
        return self.http.call(.{ .meth = meth, .urlz = urlz, .bear = self.toke, .body = body, .xtra = head });
    }

    fn pars(self: *Gith, comptime Type: type, text: []const u8) Erro!Type {
        return std.json.parseFromSliceLeaky(Type, self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.BadJson;
    }

    // seal a secret to the repo's public key and upload it
    pub fn secrPutz(self: *Gith, name: []const u8, plai: []const u8) !void {
        const keyr = try self.call(.GET, "secrets/public-key", null);
        if (!keyr.okay()) return codeErro(keyr.code);
        const pkey = try self.pars(Pkey, keyr.body);
        var publ: [Seal.public_length]u8 = undefined;
        if ((b64s.Decoder.calcSizeForSlice(pkey.key) catch return error.BadKey) != publ.len) return error.BadKey;
        b64s.Decoder.decode(&publ, pkey.key) catch return error.BadKey;
        const ciph = try self.gpa.alloc(u8, plai.len + Seal.seal_length);
        defer std.crypto.secureZero(u8, ciph);
        Seal.seal(self.io, ciph, plai, publ) catch return error.BadKey;
        const text = try self.gpa.alloc(u8, b64s.Encoder.calcSize(ciph.len));
        const body = try std.json.Stringify.valueAlloc(self.gpa, .{ .encrypted_value = b64s.Encoder.encode(text, ciph), .key_id = pkey.key_id }, .{});
        const resp = try self.call(.PUT, try std.mem.concat(self.gpa, u8, &.{ "secrets/", name }), body);
        if (resp.code != 201 and resp.code != 204) return codeErro(resp.code);
    }

    // true when a secret with this name exists (its value is never readable)
    pub fn secrHave(self: *Gith, name: []const u8) !bool {
        const resp = try self.call(.GET, try std.mem.concat(self.gpa, u8, &.{ "secrets/", name }), null);
        if (resp.code == 404) return false;
        if (!resp.okay()) return codeErro(resp.code);
        return true;
    }

    // value of an Actions variable; null when missing
    pub fn varzGetz(self: *Gith, name: []const u8) !?[]const u8 {
        const resp = try self.call(.GET, try std.mem.concat(self.gpa, u8, &.{ "variables/", name }), null);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        return (try self.pars(Varz, resp.body)).value;
    }

    pub fn varzMake(self: *Gith, name: []const u8, valu: []const u8) !void {
        const resp = try self.call(.POST, "variables", try std.json.Stringify.valueAlloc(self.gpa, .{ .name = name, .value = valu }, .{}));
        if (resp.code != 201) return codeErro(resp.code);
    }

    // newest run of a workflow file; null when it never ran
    pub fn runzLast(self: *Gith, flow: []const u8) !?Runz {
        const resp = try self.call(.GET, try std.fmt.allocPrint(self.gpa, "workflows/{s}/runs?per_page=1", .{std.fs.path.basename(flow)}), null);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        const runs = try self.pars(Runs, resp.body);
        return if (runs.workflow_runs.len == 0) null else runs.workflow_runs[0];
    }
};

// owner + repo from a git remote url (https or ssh form)
pub const Slug = struct { owne: []const u8, repo: []const u8 };

pub fn slugPars(urlz: []const u8) ?Slug {
    var text = std.mem.trim(u8, urlz, " \r\n/");
    if (std.mem.endsWith(u8, text, ".git")) text = text[0 .. text.len - 4];
    const slas = std.mem.lastIndexOfScalar(u8, text, '/') orelse return null;
    const repo = text[slas + 1 ..];
    const head = text[0..slas];
    const cutz = std.mem.lastIndexOfAny(u8, head, "/:") orelse return null;
    const owne = head[cutz + 1 ..];
    return if (owne.len == 0 or repo.len == 0) null else .{ .owne = owne, .repo = repo };
}

test "slug from remote urls" {
    const case = [_][3][]const u8{
        .{ "https://github.com/ann/cloud-house.git", "ann", "cloud-house" },
        .{ "git@github.com:ann/cloud-house.git", "ann", "cloud-house" },
        .{ "ssh://git@github.com/ann/cloud-house", "ann", "cloud-house" },
        .{ "/tmp/remotes/github/ann/cloud-house.git\n", "ann", "cloud-house" },
    };
    for (case) |item| {
        const slug = slugPars(item[0]).?;
        try std.testing.expectEqualStrings(item[1], slug.owne);
        try std.testing.expectEqualStrings(item[2], slug.repo);
    }
    try std.testing.expect(slugPars("cloud-house") == null);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
