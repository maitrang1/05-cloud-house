// =====================================================================
// Des: The Forgejo adapter. One small file behind the HTTP+JSON contract: version, who-am-I, SSH keys, repo, branch protection, branch head, and token delete.
// Flo: build a request > call with the bearer token (or basic auth for the token endpoint) > map the status to a typed error > parse the JSON
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Forgejo base API url (".../api/v1"), token, calls
// Out: typed answers, or an error (Unauthorized, Forbidden, NotFound, Conflict, RateLimited, ApiError, BadJson)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("http-call.zig");

pub const Erro = error{ Unauthorized, Forbidden, NotFound, Conflict, RateLimited, ApiError, BadJson };

// wire shapes: field names are Forgejo's
pub const Vers = struct { version: []const u8 };
pub const Self = struct { id: u64, login: []const u8, email: ?[]const u8 = null };
pub const Keyz = struct { id: u64, title: []const u8 = "", key: []const u8 = "" };
pub const Repo = struct { id: u64, name: []const u8 = "", full_name: []const u8 = "", private: bool = false, default_branch: []const u8 = "", has_wiki: bool = false, has_issues: bool = false, has_pull_requests: bool = false, has_projects: bool = false, has_actions: bool = false };
pub const Prot = struct { branch_name: []const u8 = "", enable_push: bool = false, enable_force_push: bool = false };
pub const Comm = struct { id: []const u8 = "" };
pub const Bran = struct { name: []const u8 = "", commit: Comm = .{} };

pub const Forg = struct {
    gpa: std.mem.Allocator,
    http: *http.Http,
    apiz: []const u8,
    toke: []const u8 = "",
    last: []const u8 = "",

    // status code to typed error
    fn codeErro(code: u16) Erro {
        return switch (code) {
            401 => error.Unauthorized,
            403 => error.Forbidden,
            404 => error.NotFound,
            409, 422 => error.Conflict,
            429 => error.RateLimited,
            else => error.ApiError,
        };
    }

    // one JSON API call with the bearer token
    fn apiCall(self: *Forg, meth: std.http.Method, path: []const u8, body: ?[]const u8, auth: bool) !http.Resp {
        const urlz = try std.mem.concat(self.gpa, u8, &.{ self.apiz, path });
        const resp = try self.http.call(.{ .meth = meth, .urlz = urlz, .bear = if (auth) self.toke else null, .body = body });
        self.last = resp.body;
        return resp;
    }

    // parse an answer into a wire shape
    fn pars(self: *Forg, comptime Type: type, text: []const u8) Erro!Type {
        return std.json.parseFromSliceLeaky(Type, self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.BadJson;
    }

    // the server version; no token needed, so it doubles as the "is it up" probe
    pub fn versGetz(self: *Forg) !Vers {
        const resp = try self.apiCall(.GET, "/version", null, false);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Vers, resp.body);
    }

    // who the token belongs to
    pub fn userSelf(self: *Forg) !Self {
        const resp = try self.apiCall(.GET, "/user", null, true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Self, resp.body);
    }

    pub fn keysList(self: *Forg) ![]Keyz {
        const resp = try self.apiCall(.GET, "/user/keys", null, true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars([]Keyz, resp.body);
    }

    pub fn keysAddz(self: *Forg, titl: []const u8, keyz: []const u8) !u64 {
        const resp = try self.apiCall(.POST, "/user/keys", try std.json.Stringify.valueAlloc(self.gpa, .{ .title = titl, .key = keyz }, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        return (try self.pars(Keyz, resp.body)).id;
    }

    // repo by owner + name; null when it does not exist
    pub fn repoFind(self: *Forg, owne: []const u8, name: []const u8) !?Repo {
        const resp = try self.apiCall(.GET, try std.fmt.allocPrint(self.gpa, "/repos/{s}/{s}", .{ try http.urlzEnco(self.gpa, owne), try http.urlzEnco(self.gpa, name) }), null, true);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        return try self.pars(Repo, resp.body);
    }

    // create an empty repo in the token owner's namespace
    pub fn repoMake(self: *Forg, name: []const u8, privat: bool, bran: []const u8) !Repo {
        const resp = try self.apiCall(.POST, "/user/repos", try std.json.Stringify.valueAlloc(self.gpa, .{ .name = name, .private = privat, .default_branch = bran, .auto_init = false }, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Repo, resp.body);
    }

    // apply settings (the body is the config object, as is)
    pub fn repoEdit(self: *Forg, owne: []const u8, name: []const u8, sett: std.json.Value) !Repo {
        const resp = try self.apiCall(.PATCH, try std.fmt.allocPrint(self.gpa, "/repos/{s}/{s}", .{ try http.urlzEnco(self.gpa, owne), try http.urlzEnco(self.gpa, name) }), try std.json.Stringify.valueAlloc(self.gpa, sett, .{}), true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Repo, resp.body);
    }

    // protection rule of a branch; null when unprotected
    pub fn protFind(self: *Forg, owne: []const u8, name: []const u8, bran: []const u8) !?Prot {
        const resp = try self.apiCall(.GET, try std.fmt.allocPrint(self.gpa, "/repos/{s}/{s}/branch_protections/{s}", .{ try http.urlzEnco(self.gpa, owne), try http.urlzEnco(self.gpa, name), try http.urlzEnco(self.gpa, bran) }), null, true);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        return try self.pars(Prot, resp.body);
    }

    // create a rule: the config body plus the branch name
    pub fn protMake(self: *Forg, owne: []const u8, name: []const u8, bran: []const u8, body: std.json.Value) !Prot {
        const base = try std.json.Stringify.valueAlloc(self.gpa, body, .{});
        const head = std.mem.trimEnd(u8, base, "}");
        const sepa: []const u8 = if (std.mem.eql(u8, std.mem.trim(u8, head, " {"), "")) "" else ",";
        const quot = try std.json.Stringify.valueAlloc(self.gpa, bran, .{}); // JSON-escaped, quotes included
        const full = try std.fmt.allocPrint(self.gpa, "{s}{s}\"branch_name\":{s},\"rule_name\":{s}}}", .{ head, sepa, quot, quot });
        const resp = try self.apiCall(.POST, try std.fmt.allocPrint(self.gpa, "/repos/{s}/{s}/branch_protections", .{ try http.urlzEnco(self.gpa, owne), try http.urlzEnco(self.gpa, name) }), full, true);
        if (!resp.okay()) return codeErro(resp.code);
        return self.pars(Prot, resp.body);
    }

    // head commit of a branch; null when the branch does not exist yet
    pub fn branHead(self: *Forg, owne: []const u8, name: []const u8, bran: []const u8) !?[]const u8 {
        const resp = try self.apiCall(.GET, try std.fmt.allocPrint(self.gpa, "/repos/{s}/{s}/branches/{s}", .{ try http.urlzEnco(self.gpa, owne), try http.urlzEnco(self.gpa, name), try http.urlzEnco(self.gpa, bran) }), null, true);
        if (resp.code == 404) return null;
        if (!resp.okay()) return codeErro(resp.code);
        return (try self.pars(Bran, resp.body)).commit.id;
    }

    // delete a token by name; this endpoint takes basic auth only ("user:pass")
    pub fn tokeDele(self: *Forg, user: []const u8, name: []const u8, basi: []const u8) !void {
        const urlz = try std.fmt.allocPrint(self.gpa, "{s}/users/{s}/tokens/{s}", .{ self.apiz, try http.urlzEnco(self.gpa, user), try http.urlzEnco(self.gpa, name) });
        const resp = try self.http.call(.{ .meth = .DELETE, .urlz = urlz, .basi = basi });
        self.last = resp.body;
        if (resp.code == 404) return;
        if (!resp.okay()) return codeErro(resp.code);
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
