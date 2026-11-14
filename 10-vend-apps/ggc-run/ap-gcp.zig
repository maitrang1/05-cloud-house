// =====================================================================
// Des: The one way the app talks to Google REST: adds the bearer token and the quota-project header, parses the JSON answer, and waits for long-running operations.
// Flo: call(method, url, body) > token > http > parse JSON > Reply; lro(base, name) > poll GET until done or error or time
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: method, url, optional JSON body text
// Out: Reply{code, val, raw}; error text helper for what/why/fix lines
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("co-http.zig");
const auth = @import("ap-auth.zig");

const CF = .{ .quotHead = "X-Goog-User-Project", .msecSecs = 1000, .rawShow = 200, .emptyBody = "{}" };

pub const Erro = error{ OpFail, OpTime };

// one parsed answer
pub const Reply = struct {
    code: u16,
    val: std.json.Value,
    raw: []const u8,

    pub fn okay(self: Reply) bool {
        return self.code >= 200 and self.code < 300;
    }

    // Google's error.message, else the start of the raw body
    pub fn errText(self: Reply) []const u8 {
        if (self.val == .object) if (self.val.object.get("error")) |errv| if (errv == .object) if (errv.object.get("message")) |msg| if (msg == .string) return msg.string;
        return if (self.raw.len > CF.rawShow) self.raw[0..CF.rawShow] else self.raw;
    }
};

// object member or .null
pub fn obj(val: std.json.Value, key: []const u8) std.json.Value {
    if (val != .object) return .null;
    return val.object.get(key) orelse .null;
}

// string value or ""
pub fn str(val: std.json.Value) []const u8 {
    return if (val == .string) val.string else "";
}

// integer value (also numbers and numeric strings), else 0
pub fn int(val: std.json.Value) i64 {
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(@trunc(f)),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

pub const Gcp = struct {
    a: std.mem.Allocator,
    io: std.Io,
    http: *http.Http,
    auth: *auth.Auth,
    quot: bool,
    proj: []const u8 = "",
    lro_msec: u32,
    lro_secs: u32,

    // one call; body null for GET and DELETE, "{}" is sent for a POST without a body
    pub fn call(self: *Gcp, meth: std.http.Method, urlz: []const u8, body: ?[]const u8) !Reply {
        const toke = try self.auth.token();
        var xtra: []const http.Head = &.{};
        if (self.quot and self.proj.len != 0) {
            const one = try self.a.alloc(http.Head, 1);
            one[0] = .{ .name = CF.quotHead, .value = self.proj };
            xtra = one;
        }
        const sent: ?[]const u8 = if (meth.requestHasBody()) (body orelse CF.emptyBody) else null;
        const resp = try self.http.call(.{ .meth = meth, .urlz = urlz, .bear = toke, .body = sent, .xtra = xtra });
        const val: std.json.Value = if (resp.body.len == 0) .null else std.json.parseFromSliceLeaky(std.json.Value, self.a, resp.body, .{ .allocate = .alloc_always }) catch .null;
        return .{ .code = resp.code, .val = val, .raw = resp.body };
    }

    // wait for an operation: GET base/name until done; error when it carries an error
    pub fn lro(self: *Gcp, base: []const u8, name: []const u8) !void {
        const urlz = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ base, name });
        var left: u64 = @as(u64, self.lro_secs) * CF.msecSecs;
        while (true) {
            const rep = try self.call(.GET, urlz, null);
            if (!rep.okay()) return error.OpFail;
            const errv = obj(rep.val, "error");
            if (errv != .null) return error.OpFail;
            const done = obj(rep.val, "done");
            if (done == .bool and done.bool) return;
            if (left <= self.lro_msec) return error.OpTime;
            left -= self.lro_msec;
            std.Io.sleep(self.io, .fromMilliseconds(self.lro_msec), .awake) catch return error.OpTime;
        }
    }

    // wait for the operation named in a reply (no name or already done = nothing to wait for)
    pub fn lroOf(self: *Gcp, base: []const u8, rep: Reply) !void {
        const done = obj(rep.val, "done");
        if (done == .bool and done.bool) {
            if (obj(rep.val, "error") != .null) return error.OpFail;
            return;
        }
        const name = str(obj(rep.val, "name"));
        if (name.len == 0) return;
        return self.lro(base, name);
    }
};

test "json helpers" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const val = try std.json.parseFromSliceLeaky(std.json.Value, aren.allocator(), "{\"a\":{\"b\":\"x\"},\"n\":\"42\",\"m\":7,\"error\":{\"message\":\"nope\"}}", .{});
    try std.testing.expectEqualStrings("x", str(obj(obj(val, "a"), "b")));
    try std.testing.expectEqual(@as(i64, 42), int(obj(val, "n")));
    try std.testing.expectEqual(@as(i64, 7), int(obj(val, "m")));
    try std.testing.expect(obj(val, "zzz") == .null);
    const rep = Reply{ .code = 403, .val = val, .raw = "raw" };
    try std.testing.expectEqualStrings("nope", rep.errText());
    try std.testing.expect(!rep.okay());
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
