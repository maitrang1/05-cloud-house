// =====================================================================
// Des: The GitLab adapter. One small file that speaks GitLab's web API: find a user, log in by device code, make the project, protect main, manage keys and tokens.
// Flo: typed call > build url + JSON body > http call > map status to a typed error > parse the answer
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: API base urls, OAuth token, typed arguments
// Out: typed results or a typed error (never prints)
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("http-call.zig");

const CF = .{ .formType = "application/x-www-form-urlencoded", .granDevi = "urn:ietf:params:oauth:grant-type:device_code", .granRefr = "refresh_token", .mineOnly = "?statistics=true" };

pub const Erro = error{ Unauthorized, Forbidden, NotFound, Conflict, RateLimited, ApiError, BadJson };

// wire shapes: field names are GitLab's
pub const User = struct { id: u64, username: []const u8 };
pub const Self = struct { id: u64, username: []const u8, email: ?[]const u8 = null, commit_email: ?[]const u8 = null, confirmed_at: ?[]const u8 = null };
pub const Devi = struct { device_code: []const u8, user_code: []const u8, verification_uri: []const u8, verification_uri_complete: ?[]const u8 = null, expires_in: u32 = 300, interval: u32 = 5 };
pub const Toke = struct { access_token: []const u8, refresh_token: ?[]const u8 = null, expires_in: ?u32 = null, created_at: ?i64 = null };
pub const Keyz = struct { id: u64, title: []const u8 = "", key: []const u8 = "" };
pub const Leve = struct { access_level: ?u64 = null };
pub const Prot = struct { name: []const u8 = "", push_access_levels: []const Leve = &.{}, merge_access_levels: []const Leve = &.{}, allow_force_push: bool = false };
pub const Atok = struct { id: u64, name: []const u8 = "", expires_at: ?[]const u8 = null, active: bool = false, revoked: bool = false, token: ?[]const u8 = null };
const OautFail = struct { @"error": []const u8 = "" };

// answer of one device-flow poll
pub const Poll = union(enum) { pend, slow, deny, expi, okay: Toke };

pub const Gitl = struct {
    gpa: std.mem.Allocator,
    http: *http.Http,
    apiz: []const u8,
    oaut: []const u8,
    toke: []const u8 = "",
    last: []const u8 = "",

    // status code to typed error
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

    // one JSON API call with the bearer token
    fn apiCall(self: *Gitl, meth: std.http.Method, path: []const u8, body: ?[]const u8, auth: bool) !http.Resp {
        const urlz = try std.mem.concat(self.gpa, u8, &.{ self.apiz, path });
        const resp = try self.http.call(.{ .meth = meth, .urlz = urlz, .bear = if (auth) self.toke else null, .body = body });
        self.last = resp.body;
        return resp;
    }

    // one form POST to the OAuth server
    fn oauCall(self: *Gitl, path: []const u8, form: []const u8) !http.Resp {
        const urlz = try std.mem.concat(self.gpa, u8, &.{ self.oaut, path });
        const resp = try self.http.call(.{ .meth = .POST, .urlz = urlz, .body = form, .ctyp = CF.formType });
        self.last = resp.body;
        return resp;
    }

    // parse an answer into a wire shape
    fn pars(self: *Gitl, comptime Type: type, text: []const u8) Erro!Type {
        return std.json.parseFromSliceLeaky(Type, self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.BadJson;
    }

    // public lookup by username (no token)
    pub fn userFind(self: *Gitl, name: []const u8) !?User {
        const resp = try self.apiCall(.GET, try std.mem.concat(self.gpa, u8, &.{ "/users?username=", try http.urlzEnco(self.gpa, name) }), null, false);
        if (!resp.okay()) return codeErro(resp.code);
        const list = try self.pars([]User, resp.body);
        return if (list.len == 0) null else list[0];
    }

    // device flow, step 1: ask for a code
    pub fn deviStar(self: *Gitl, clid: []const u8, scop: []const u8) !Devi {
        const resp = try self.oauCall("/authorize_device", try std.fmt.allocPrint(self.gpa, "client_id={s}&scope={s}", .{ try http.urlzEnco(self.gpa, clid), try http.urlzEnco(self.gpa, scop) }));
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Devi, resp.body);
    }

    // device flow, step 2: one poll
    pub fn deviPoll(self: *Gitl, clid: []const u8, code: []const u8) !Poll {
        const resp = try self.oauCall("/token", try std.fmt.allocPrint(self.gpa, "grant_type={s}&device_code={s}&client_id={s}", .{ try http.urlzEnco(self.gpa, CF.granDevi), try http.urlzEnco(self.gpa, code), try http.urlzEnco(self.gpa, clid) }));
        if (resp.okay()) return .{ .okay = try self.pars(Toke, resp.body) };
        const fail = self.pars(OautFail, resp.body) catch return codeErro(resp.code);
        if (std.mem.eql(u8, fail.@"error", "authorization_pending")) return .pend;
        if (std.mem.eql(u8, fail.@"error", "slow_down")) return .slow;
        if (std.mem.eql(u8, fail.@"error", "access_denied")) return .deny;
        if (std.mem.eql(u8, fail.@"error", "expired_token")) return .expi;
        return codeErro(resp.code);
    }

    // swap a refresh token for a new pair
    pub fn tokeRefr(self: *Gitl, clid: []const u8, refr: []const u8) !Toke {
        const resp = try self.oauCall("/token", try std.fmt.allocPrint(self.gpa, "grant_type={s}&refresh_token={s}&client_id={s}", .{ CF.granRefr, try http.urlzEnco(self.gpa, refr), try http.urlzEnco(self.gpa, clid) }));
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Toke, resp.body);
    }

    // kill an OAuth token the app got
    pub fn tokeRevo(self: *Gitl, clid: []const u8, toke: []const u8) !void {
        const resp = try self.oauCall("/revoke", try std.fmt.allocPrint(self.gpa, "client_id={s}&token={s}", .{ try http.urlzEnco(self.gpa, clid), try http.urlzEnco(self.gpa, toke) }));
        if (!resp.okay()) return codeErro(resp.code);
    }

    // who the token belongs to
    pub fn userSelf(self: *Gitl) !Self {
        const resp = try self.apiCall(.GET, "/user", null, true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Self, resp.body);
    }

    pub fn keysList(self: *Gitl) ![]Keyz {
        const resp = try self.apiCall(.GET, "/user/keys", null, true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars([]Keyz, resp.body);
    }

    pub fn keysAddz(self: *Gitl, titl: []const u8, keyz: []const u8) !u64 {
        const resp = try self.apiCall(.POST, "/user/keys", try std.json.Stringify.valueAlloc(self.gpa, .{ .title = titl, .key = keyz }, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        return (try self.pars(Keyz, resp.body)).id;
    }

    pub fn keysDele(self: *Gitl, iden: u64) !void {
        const resp = try self.apiCall(.DELETE, try std.fmt.allocPrint(self.gpa, "/user/keys/{d}", .{iden}), null, true);
        if (!resp.okay()) return codeErro(resp.code);
    }

    // project by "user/name" path; null when it does not exist
    pub fn projFind(self: *Gitl, path: []const u8) !?std.json.Value {
        const resp = try self.apiCall(.GET, try std.mem.concat(self.gpa, u8, &.{ "/projects/", try http.urlzEnco(self.gpa, path), CF.mineOnly }), null, true);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        const json = try self.pars(std.json.Value, resp.body);
        return if (json == .object) json else error.BadJson;
    }

    // create a project in the user's own namespace
    pub fn projMake(self: *Gitl, name: []const u8, visi: []const u8, bran: []const u8) !std.json.Value {
        const resp = try self.apiCall(.POST, "/projects", try std.json.Stringify.valueAlloc(self.gpa, .{ .name = name, .path = name, .visibility = visi, .default_branch = bran, .initialize_with_readme = false }, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        const json = try self.pars(std.json.Value, resp.body);
        return if (json == .object) json else error.BadJson;
    }

    // apply settings (the body is the config object, as is)
    pub fn projEdit(self: *Gitl, iden: u64, sett: std.json.Value) !std.json.Value {
        const resp = try self.apiCall(.PUT, try std.fmt.allocPrint(self.gpa, "/projects/{d}", .{iden}), try std.json.Stringify.valueAlloc(self.gpa, sett, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        const json = try self.pars(std.json.Value, resp.body);
        return if (json == .object) json else error.BadJson;
    }

    // protection rule of a branch; null when unprotected
    pub fn protFind(self: *Gitl, iden: u64, bran: []const u8) !?Prot {
        const resp = try self.apiCall(.GET, try std.fmt.allocPrint(self.gpa, "/projects/{d}/protected_branches/{s}", .{ iden, try http.urlzEnco(self.gpa, bran) }), null, true);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        return try self.pars(Prot, resp.body);
    }

    pub fn protMake(self: *Gitl, iden: u64, bran: []const u8, push: u32, merg: u32, forc: bool) !Prot {
        const resp = try self.apiCall(.POST, try std.fmt.allocPrint(self.gpa, "/projects/{d}/protected_branches", .{iden}), try std.json.Stringify.valueAlloc(self.gpa, .{ .name = bran, .push_access_level = push, .merge_access_level = merg, .allow_force_push = forc }, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Prot, resp.body);
    }

    // make a project access token; the secret comes back once
    pub fn atokMake(self: *Gitl, iden: u64, name: []const u8, scop: []const []const u8, role: u32, expi: []const u8) !Atok {
        const resp = try self.apiCall(.POST, try std.fmt.allocPrint(self.gpa, "/projects/{d}/access_tokens", .{iden}), try std.json.Stringify.valueAlloc(self.gpa, .{ .name = name, .scopes = scop, .access_level = role, .expires_at = expi }, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Atok, resp.body);
    }

    pub fn atokFind(self: *Gitl, iden: u64, tide: u64) !?Atok {
        const resp = try self.apiCall(.GET, try std.fmt.allocPrint(self.gpa, "/projects/{d}/access_tokens/{d}", .{ iden, tide }), null, true);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        return try self.pars(Atok, resp.body);
    }

    pub fn atokList(self: *Gitl, iden: u64) ![]Atok {
        const resp = try self.apiCall(.GET, try std.fmt.allocPrint(self.gpa, "/projects/{d}/access_tokens", .{iden}), null, true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars([]Atok, resp.body);
    }

    // revoke a project access token the app made
    pub fn atokDele(self: *Gitl, iden: u64, tide: u64) !void {
        const resp = try self.apiCall(.DELETE, try std.fmt.allocPrint(self.gpa, "/projects/{d}/access_tokens/{d}", .{ iden, tide }), null, true);
        if (!resp.okay()) return codeErro(resp.code);
    }
};

// first access level of a protection list, 0 when empty
pub fn leveFrst(list: []const Leve) u64 {
    return if (list.len == 0) 0 else list[0].access_level orelse 0;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
