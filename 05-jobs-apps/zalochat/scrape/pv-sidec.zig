// Sidecar client: spawns `node side.mjs serve`, one JSON line out / one back. The Zig side checks the config whitelist FIRST;
// the sidecar checks its own read-only.json too. Cookies go over stdin only (never argv, never a plain file).
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");

pub const Code = enum { ok, refused, dead_session, rate_limited, timeout, down, bad };
pub const Reply = struct { code: Code, data: std.json.Value = .null, msg: []const u8 = "" };

pub const Side = struct {
    io: Io,
    child: std.process.Child,
    rbuf: []u8,
    reader: Io.File.Reader,
    allow: []const []const u8,
    rid: u32 = 0,
    calls: u32 = 0,

    // fixture is honored ONLY in mock builds
    pub fn start(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, session_json: []const u8, fixture: ?[]const u8) !*Side {
        const s = cx.cfg.side;
        const script = try std.fmt.allocPrint(a, "{s}/side.mjs", .{try cx.rel(a, s.dir)});
        const allow_csv = try std.mem.join(a, ",", s.whitelist);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ s.node, script, "serve", "--allow", allow_csv, "--gap-ms", try std.fmt.allocPrint(a, "{d}", .{s.gap_ms}), "--call-timeout-ms", try std.fmt.allocPrint(a, "{d}", .{s.call_timeout_ms}) });
        if (cx.mock) if (fixture) |f| try argv.appendSlice(a, &.{ "--fixture", f });
        const child = try std.process.spawn(cx.io, .{ .argv = argv.items, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
        const self = try a.create(Side);
        self.* = .{ .io = cx.io, .child = child, .rbuf = try a.alloc(u8, 1 << 16), .reader = undefined, .allow = s.whitelist };
        self.reader = self.child.stdout.?.readerStreaming(cx.io, self.rbuf);
        const hello = try std.fmt.allocPrint(a, "{{\"session\":{s}}}\n", .{session_json});
        try self.child.stdin.?.writeStreamingAll(cx.io, hello);
        const line = (try self.readLine(a, 1 << 20)) orelse return error.SidecarGone;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch return error.BadReply;
        const okv: std.json.Value = if (v == .object) (v.object.get("ok") orelse .null) else .null;
        if (okv != .bool or !okv.bool) {
            self.stop();
            return error.LoginFailed;
        }
        return self;
    }

    fn readLine(self: *Side, a: std.mem.Allocator, limit: usize) !?[]u8 {
        var aw: Io.Writer.Allocating = .init(a);
        const r = &self.reader.interface;
        const n = r.streamDelimiterLimit(&aw.writer, '\n', .limited(limit)) catch return error.BadReply;
        _ = r.takeByte() catch return if (n == 0) null else aw.written();
        return aw.written();
    }

    fn allowed(self: *const Side, m: []const u8) bool {
        for (self.allow) |n| if (std.mem.eql(u8, n, m)) return true;
        return false;
    }

    pub fn call(self: *Side, a: std.mem.Allocator, method: []const u8, args_json: []const u8) !Reply {
        if (!self.allowed(method)) return .{ .code = .refused, .msg = "not in side.whitelist" };
        self.rid += 1;
        self.calls += 1;
        const req = try std.fmt.allocPrint(a, "{{\"rid\":{d},\"method\":\"{s}\",\"args\":{s}}}\n", .{ self.rid, method, args_json });
        self.child.stdin.?.writeStreamingAll(self.io, req) catch return .{ .code = .down, .msg = "sidecar gone" };
        const line = (self.readLine(a, 64 * 1024 * 1024) catch return .{ .code = .bad, .msg = "bad reply" }) orelse return .{ .code = .down, .msg = "sidecar ended" };
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always }) catch return .{ .code = .bad, .msg = "not json" };
        if (v != .object) return .{ .code = .bad };
        const ok: std.json.Value = v.object.get("ok") orelse .null;
        if (ok == .bool and ok.bool) return .{ .code = .ok, .data = v.object.get("data") orelse .null };
        const code = if (v.object.get("code")) |c| (if (c == .string) c.string else "") else "";
        const msg = if (v.object.get("msg")) |c| (if (c == .string) c.string else "") else "";
        const cd: Code = if (std.mem.eql(u8, code, "refused")) .refused else if (std.mem.eql(u8, code, "dead_session")) .dead_session else if (std.mem.eql(u8, code, "rate_limited")) .rate_limited else if (std.mem.eql(u8, code, "timeout")) .timeout else if (std.mem.eql(u8, code, "down")) .down else .bad;
        return .{ .code = cd, .msg = msg };
    }

    pub fn stop(self: *Side) void {
        if (self.child.stdin) |f| {
            f.close(self.io);
            self.child.stdin = null;
        }
        self.child.kill(self.io);
    }
};

pub fn nodeAvailable(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) bool {
    const r = std.process.run(a, cx.io, .{ .argv = &.{ cx.cfg.side.node, "--version" } }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

// ---- tests (fixture mode; skipped when node is missing) ----
test "sidecar: whitelist enforced twice; reads work; dead session surfaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(a, &env, ".zig-cache/tmp/none");
    cx.mock = true;
    cx.cfg.side.gap_ms = 0;
    cx.cfg.side.dir = "side";
    if (!nodeAvailable(&cx, a)) return error.SkipZigTest;
    cx.cfg.side.whitelist = &.{ "getAllFriends", "sendMessage", "getAllGroups" };
    const s = try Side.start(&cx, a, "{\"imei\":\"x\",\"userAgent\":\"x\",\"cookie\":\"FIXTURE\"}", "te-side.json");
    defer s.stop();
    const r = try s.call(a, "getAllFriends", "[]");
    try std.testing.expect(r.code == .ok and r.data == .array and r.data.array.items.len == 2);
    // sendMessage is in the Zig config here on purpose: the sidecar's own read-only.json still refuses it
    const bad = try s.call(a, "sendMessage", "[]");
    try std.testing.expect(bad.code == .refused);
    // not in the Zig whitelist: refused before any I/O
    const calls_before = s.calls;
    const n = try s.call(a, "getGroupInfo", "[\"g1\"]");
    try std.testing.expect(n.code == .refused);
    try std.testing.expectEqual(calls_before, s.calls);
}
