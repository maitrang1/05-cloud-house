// =====================================================================
// Des: Cloudflare REST client. Only what the cron setup needs: accounts, workers.dev name, upload one Worker, route on, cron schedule. No delete call exists.
// Flo: build path > one http call > map status to an error > parse the result envelope
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, token, call arguments
// Out: typed results or an error (message kept in `mess`)
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("co-http.zig");

const CF = .{ .listLimi = 50, .modName = "worker.js", .boundary = "cloudhouseboundary7e3a91", .modType = "application/javascript+module" };

pub const Erro = error{ CflaAuth, CflaMiss, CflaBad, CflaLimi, CflaDown, CflaForm, CflaAcco };

pub const Acco = struct { id: []const u8, name: []const u8 = "" };

const ErrItem = struct { code: i64 = 0, message: []const u8 = "" };
fn Envl(comptime T: type) type {
    return struct { success: bool = false, errors: []const ErrItem = &.{}, result: ?T = null };
}
const SchedRes = struct { schedules: []const struct { cron: []const u8 } = &.{} };
const SubdRes = struct { subdomain: ?[]const u8 = null };
const RoutRes = struct { enabled: bool = false };

// one Worker binding; `secret` makes it write-only on Cloudflare's side
pub const Bind = struct { name: []const u8, text: []const u8, secret: bool };

pub const Cfla = struct {
    gpa: std.mem.Allocator,
    http: *http.Http,
    apiz: []const u8,
    toke: []const u8,
    mess: []const u8 = "",

    // one call; maps status codes to errors, keeps the vendor message
    fn call(self: *Cfla, meth: std.http.Method, path: []const u8, body: ?[]const u8, ctyp: []const u8) Erro![]u8 {
        const urlz = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ self.apiz, path }) catch return error.CflaDown;
        const resp = self.http.call(.{ .meth = meth, .urlz = urlz, .bear = self.toke, .body = body, .ctyp = ctyp }) catch return error.CflaDown;
        if (resp.okay()) return resp.body;
        const err = std.json.parseFromSliceLeaky(Envl(std.json.Value), self.gpa, resp.body, .{ .ignore_unknown_fields = true }) catch Envl(std.json.Value){};
        self.mess = if (err.errors.len > 0) err.errors[0].message else "";
        return switch (resp.code) {
            401, 403 => error.CflaAuth,
            404 => error.CflaMiss,
            429 => error.CflaLimi,
            500...599 => error.CflaDown,
            else => error.CflaBad,
        };
    }

    // call + unwrap `result`; success=false in a 200 is an error too
    fn res(self: *Cfla, comptime T: type, meth: std.http.Method, path: []const u8, body: ?[]const u8) Erro!T {
        const text = try self.call(meth, path, body, "application/json");
        const envl = std.json.parseFromSliceLeaky(Envl(T), self.gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.CflaForm;
        if (!envl.success) {
            self.mess = if (envl.errors.len > 0) envl.errors[0].message else "";
            return error.CflaBad;
        }
        return envl.result orelse error.CflaForm;
    }

    // the account to use: the one with id `want`, else the first
    pub fn account(self: *Cfla, want: []const u8) Erro!Acco {
        const path = std.fmt.allocPrint(self.gpa, "/accounts?per_page={d}", .{CF.listLimi}) catch return error.CflaDown;
        const rows = try self.res([]const Acco, .GET, path, null);
        for (rows) |row| if (want.len == 0 or std.mem.eql(u8, row.id, want)) return row;
        return error.CflaAcco;
    }

    // the registered workers.dev name, null when none
    pub fn subGet(self: *Cfla, acco: []const u8) Erro!?[]const u8 {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/subdomain", .{acco}) catch return error.CflaDown;
        const resu = self.res(SubdRes, .GET, path, null) catch |erro| switch (erro) {
            error.CflaMiss, error.CflaBad, error.CflaForm => return null,
            else => return erro,
        };
        const name = resu.subdomain orelse return null;
        return if (name.len == 0) null else name;
    }

    pub fn subSet(self: *Cfla, acco: []const u8, name: []const u8) Erro!void {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/subdomain", .{acco}) catch return error.CflaDown;
        const body = std.json.Stringify.valueAlloc(self.gpa, .{ .subdomain = name }, .{}) catch return error.CflaDown;
        _ = try self.res(SubdRes, .PUT, path, body);
    }

    // upload (create or replace) one module Worker with its bindings
    pub fn push(self: *Cfla, acco: []const u8, scri: []const u8, comp: []const u8, source: []const u8, binds: []const Bind) Erro!void {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/scripts/{s}", .{ acco, scri }) catch return error.CflaDown;
        const body = multi(self.gpa, comp, source, binds) catch return error.CflaDown;
        const ctyp = std.fmt.allocPrint(self.gpa, "multipart/form-data; boundary={s}", .{CF.boundary}) catch return error.CflaDown;
        const text = try self.call(.PUT, path, body, ctyp);
        const envl = std.json.parseFromSliceLeaky(Envl(std.json.Value), self.gpa, text, .{ .ignore_unknown_fields = true }) catch return error.CflaForm;
        if (!envl.success) return error.CflaBad;
    }

    // does the Worker exist (settings read)
    pub fn exists(self: *Cfla, acco: []const u8, scri: []const u8) Erro!bool {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/scripts/{s}/settings", .{ acco, scri }) catch return error.CflaDown;
        _ = self.res(std.json.Value, .GET, path, null) catch |erro| return if (erro == error.CflaMiss) false else erro;
        return true;
    }

    // turn the workers.dev address of this Worker on
    pub fn route(self: *Cfla, acco: []const u8, scri: []const u8) Erro!bool {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/scripts/{s}/subdomain", .{ acco, scri }) catch return error.CflaDown;
        const resu = try self.res(RoutRes, .POST, path, "{\"enabled\":true}");
        return resu.enabled;
    }

    // replace the cron list (empty list = cron off)
    pub fn sched(self: *Cfla, acco: []const u8, scri: []const u8, crons: []const []const u8) Erro!void {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/scripts/{s}/schedules", .{ acco, scri }) catch return error.CflaDown;
        var outp: std.ArrayList(u8) = .empty;
        outp.append(self.gpa, '[') catch return error.CflaDown;
        for (crons, 0..) |item, indx| {
            if (indx > 0) outp.append(self.gpa, ',') catch return error.CflaDown;
            const one = std.json.Stringify.valueAlloc(self.gpa, .{ .cron = item }, .{}) catch return error.CflaDown;
            outp.appendSlice(self.gpa, one) catch return error.CflaDown;
        }
        outp.append(self.gpa, ']') catch return error.CflaDown;
        _ = try self.res(SchedRes, .PUT, path, outp.items);
    }

    // the cron list now live
    pub fn schedGet(self: *Cfla, acco: []const u8, scri: []const u8) Erro![]const []const u8 {
        const path = std.fmt.allocPrint(self.gpa, "/accounts/{s}/workers/scripts/{s}/schedules", .{ acco, scri }) catch return error.CflaDown;
        const resu = try self.res(SchedRes, .GET, path, null);
        const outp = self.gpa.alloc([]const u8, resu.schedules.len) catch return error.CflaDown;
        for (resu.schedules, 0..) |item, indx| outp[indx] = item.cron;
        return outp;
    }
};

// the multipart upload body: metadata part + module part
pub fn multi(gpa: std.mem.Allocator, comp: []const u8, source: []const u8, binds: []const Bind) ![]u8 {
    var bind: std.ArrayList(u8) = .empty;
    try bind.append(gpa, '[');
    for (binds, 0..) |item, indx| {
        if (indx > 0) try bind.append(gpa, ',');
        try bind.appendSlice(gpa, try std.json.Stringify.valueAlloc(gpa, .{ .type = if (item.secret) "secret_text" else "plain_text", .name = item.name, .text = item.text }, .{}));
    }
    try bind.append(gpa, ']');
    const meta = try std.fmt.allocPrint(gpa, "{{\"main_module\":\"{s}\",\"compatibility_date\":\"{s}\",\"bindings\":{s}}}", .{ CF.modName, comp, bind.items });
    return std.fmt.allocPrint(gpa, "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{s}\r\n--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n{s}\r\n--{s}--\r\n", .{ CF.boundary, meta, CF.boundary, CF.modName, CF.modName, CF.modType, source, CF.boundary });
}

pub const boundary = CF.boundary;
pub const modName = CF.modName;

test "multipart body has both parts and the closing boundary" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const body = try multi(aren.allocator(), "2025-01-01", "export default {};", &.{ .{ .name = "A", .text = "1", .secret = false }, .{ .name = "S", .text = "x", .secret = true } });
    try std.testing.expect(std.mem.indexOf(u8, body, "name=\"metadata\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"secret_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"worker.js\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "--cloudhouseboundary7e3a91--\r\n"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
