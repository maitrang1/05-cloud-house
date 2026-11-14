// =====================================================================
// Des: The Render REST client. One small function per call the setup needs: owners, find/create/read/patch a service, replace env vars, deploy, suspend. It never deletes.
// Flo: build JSON body > one HTTP call with the API key > check status > parse typed JSON > hand back plain values
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: base url, api key, ids and settings per call
// Out: typed values, or an error plus the vendor message in `mess`
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("co-http.zig");

const CF = .{ .ownerLimi = 100, .listLimi = 50 };

pub const Erro = error{ RendAuth, RendMiss, RendBad, RendLimi, RendDown, RendForm, RendOwner };

pub const Owne = struct { id: []const u8, name: []const u8 };

const Detz = struct { url: []const u8 = "", plan: []const u8 = "", healthCheckPath: ?[]const u8 = null };
pub const Serv = struct {
    id: []const u8,
    name: []const u8 = "",
    dashboardUrl: []const u8 = "",
    suspended: []const u8 = "not_suspended",
    serviceDetails: Detz = .{},
};

const OwneRow = struct { owner: struct { id: []const u8, name: []const u8 = "" } };
const ServRow = struct { service: Serv };
const MakeRes = struct { service: Serv, deployId: []const u8 = "" };
const ErrBody = struct { message: []const u8 = "" };

// what to create (all from config)
pub const Make = struct { name: []const u8, owne: []const u8, imag: []const u8, plan: []const u8, regi: []const u8, heal: []const u8, inst: u32, envs: []const EnvPair = &.{} };
pub const EnvPair = struct { key: []const u8, value: []const u8 };

pub const Rend = struct {
    gpa: std.mem.Allocator,
    http: *http.Http,
    apiz: []const u8,
    toke: []const u8,
    mess: []const u8 = "",
    dpid: []const u8 = "",

    // one call; maps status codes to errors, keeps the vendor message
    fn call(self: *Rend, meth: std.http.Method, path: []const u8, body: ?[]const u8) Erro![]u8 {
        const urlz = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ self.apiz, path }) catch return error.RendDown;
        const resp = self.http.call(.{ .meth = meth, .urlz = urlz, .bear = self.toke, .body = body }) catch return error.RendDown;
        if (resp.okay()) return resp.body;
        const err = std.json.parseFromSliceLeaky(ErrBody, self.gpa, resp.body, .{ .ignore_unknown_fields = true }) catch ErrBody{};
        self.mess = err.message;
        return switch (resp.code) {
            401, 403 => error.RendAuth,
            404 => error.RendMiss,
            429 => error.RendLimi,
            500...599 => error.RendDown,
            else => error.RendBad,
        };
    }

    fn parse(self: *Rend, comptime T: type, text: []const u8) Erro!T {
        return std.json.parseFromSliceLeaky(T, self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.RendForm;
    }

    // the workspace to use: the one named `want`, or the first one
    pub fn owner(self: *Rend, want: []const u8) Erro!Owne {
        const path = std.fmt.allocPrint(self.gpa, "/owners?limit={d}", .{CF.ownerLimi}) catch return error.RendDown;
        const rows = try self.parse([]OwneRow, try self.call(.GET, path, null));
        for (rows) |row| if (want.len == 0 or std.mem.eql(u8, row.owner.name, want)) return .{ .id = row.owner.id, .name = row.owner.name };
        return error.RendOwner;
    }

    // the service with this exact name, null when none
    pub fn find(self: *Rend, name: []const u8, kind: []const u8) Erro!?Serv {
        const enco = http.urlzEnco(self.gpa, name) catch return error.RendDown;
        const path = std.fmt.allocPrint(self.gpa, "/services?name={s}&type={s}&limit={d}", .{ enco, kind, CF.listLimi }) catch return error.RendDown;
        const rows = try self.parse([]ServRow, try self.call(.GET, path, null));
        for (rows) |row| if (std.mem.eql(u8, row.service.name, name)) return row.service;
        return null;
    }

    pub fn get(self: *Rend, iden: []const u8) Erro!Serv {
        const path = std.fmt.allocPrint(self.gpa, "/services/{s}", .{iden}) catch return error.RendDown;
        return self.parse(Serv, try self.call(.GET, path, null));
    }

    // create a web service from a public image
    pub fn make(self: *Rend, want: Make) Erro!Serv {
        const body = std.json.Stringify.valueAlloc(self.gpa, .{
            .type = "web_service",
            .name = want.name,
            .ownerId = want.owne,
            .image = .{ .imagePath = want.imag, .ownerId = want.owne },
            .envVars = want.envs,
            .serviceDetails = .{ .runtime = "image", .plan = want.plan, .region = want.regi, .healthCheckPath = want.heal, .numInstances = want.inst },
        }, .{}) catch return error.RendDown;
        const resu = try self.parse(MakeRes, try self.call(.POST, "/services", body));
        self.dpid = resu.deployId;
        return resu.service;
    }

    // change the health check path only (plan and billing are never touched)
    pub fn heal(self: *Rend, iden: []const u8, path: []const u8) Erro!void {
        const body = std.json.Stringify.valueAlloc(self.gpa, .{ .serviceDetails = .{ .healthCheckPath = path } }, .{}) catch return error.RendDown;
        const urlz = std.fmt.allocPrint(self.gpa, "/services/{s}", .{iden}) catch return error.RendDown;
        _ = try self.call(.PATCH, urlz, body);
    }

    // replace ALL env vars with this list (Render drops the rest)
    pub fn envs(self: *Rend, iden: []const u8, list: []const EnvPair) Erro!void {
        const body = std.json.Stringify.valueAlloc(self.gpa, list, .{}) catch return error.RendDown;
        const urlz = std.fmt.allocPrint(self.gpa, "/services/{s}/env-vars", .{iden}) catch return error.RendDown;
        _ = try self.call(.PUT, urlz, body);
    }

    // start one deploy so new env vars apply
    pub fn deploy(self: *Rend, iden: []const u8) Erro!void {
        const urlz = std.fmt.allocPrint(self.gpa, "/services/{s}/deploys", .{iden}) catch return error.RendDown;
        _ = try self.call(.POST, urlz, "{}");
    }

    // pause a service the app made (reversible); the only "stop" the app has
    pub fn suspend_(self: *Rend, iden: []const u8) Erro!void {
        const urlz = std.fmt.allocPrint(self.gpa, "/services/{s}/suspend", .{iden}) catch return error.RendDown;
        _ = try self.call(.POST, urlz, "{}");
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
