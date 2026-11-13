// =====================================================================
// Des: Makes one web call with a hard time limit, a size cap and no redirects, waits politely when the vendor says slow down, and logs every call
// Flo: arm watchdog > send request > read status, limit headers and body > 429/403 limit: wait Retry-After and retry > audit line > Resp
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Opts{ time limit, retries, wait cap, body cap, user agent, audit } + Req{ method, url, headers, body }
// Out: Resp{ code, body, wait, left, rest } (non-2xx is a status, not an error) | HttpErro
// Run: not run directly - imported by vendor-github.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const out = @import("out-text.zig");
const audit = @import("audit-log.zig");

const CF = .{ .kilo = 1024, .wait_minz = 1, .numb_maxz = 32, .back_msec = 1000, .exit_code = 1 };

pub const HttpErro = error{ NetFail, Unsure, TooBig, BadReq, OutOfMemory };

pub const Req = struct {
    meth: std.http.Method = .GET,
    urlz: []const u8,
    head: []const std.http.Header = &.{},
    body: ?[]const u8 = null,
};

pub const Resp = struct {
    code: u16,
    body: []u8,
    // seconds the vendor asked us to wait (Retry-After), 0 when absent ----
    wait: u32 = 0,
    // calls left in this window (-1 = not told) and the unix second the window resets ----
    left: i64 = -1,
    rest: i64 = 0,

    pub fn okay(self: Resp) bool {
        return self.code >= 200 and self.code < 300;
    }
};

pub const Opts = struct {
    tmos_secs: u32 = 30,
    retr_maxz: u32 = 3,
    wait_maxz_secs: u32 = 120,
    body_maxz_kbyt: u32 = 2048,
    user_agen: []const u8 = "cloud-house-github",
    audi: ?*audit.Audit = null,
};

// std.http has no timeout: a stuck call would hang the run for ever ----
var g_gene = std.atomic.Value(u64).init(0);

fn watch(io: std.Io, gene: u64, secs: u32) void {
    std.Io.sleep(io, .fromMilliseconds(@as(i64, secs) * 1000), .awake) catch return;
    if (g_gene.load(.acquire) != gene) return;
    out.fail(io, "a web call got no answer in time", "the network or the vendor is not responding", "check the connection, then run the same command again (it resumes)");
    std.process.exit(CF.exit_code);
}

fn headNumb(v: []const u8) ?i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, v[0..@min(v.len, CF.numb_maxz)], " "), 10) catch null;
}

// connect, TLS and URL errors happen before any byte left ----
fn preSend(e: anyerror) bool {
    inline for (.{ std.http.Client.RequestError, std.Uri.ParseError }) |set| {
        inline for (@typeInfo(set).error_set.?) |x| if (e == @field(set, x.name)) return true;
    }
    return false;
}

const Shot = struct { resp: ?Resp = null, sent: bool = false, big: bool = false };

fn attempt(io: std.Io, a: std.mem.Allocator, opts: Opts, req: Req, shot: *Shot) !void {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse(req.urlz);
    var hreq = try client.request(req.meth, uri, .{ .redirect_behavior = .unhandled, .extra_headers = req.head, .keep_alive = false, .headers = .{ .user_agent = .{ .override = opts.user_agen } } });
    defer hreq.deinit();
    if (req.body) |payload| {
        hreq.transfer_encoding = .{ .content_length = payload.len };
        var bw = try hreq.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(payload);
        try bw.end();
        try hreq.connection.?.flush();
    } else try hreq.sendBodiless();
    shot.sent = true;
    var resp = try hreq.receiveHead(&.{});
    var res: Resp = .{ .code = @intFromEnum(resp.head.status), .body = &.{} };
    var it = resp.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) res.wait = @intCast(std.math.clamp(headNumb(h.value) orelse 0, 0, 86_400));
        if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-remaining")) res.left = headNumb(h.value) orelse -1;
        if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-reset")) res.rest = headNumb(h.value) orelse 0;
    }
    // 204/304 carry no body: tell the request so deinit does not wait for EOF ----
    if (res.code == 204 or res.code == 304) {
        hreq.response_content_length = 0;
        hreq.response_transfer_encoding = .none;
        shot.resp = res;
        return;
    }
    const dbuf: []u8 = switch (resp.head.content_encoding) {
        .identity => &.{},
        .zstd => try a.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try a.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (dbuf.len > 0) a.free(dbuf);
    var tbuf: [64]u8 = undefined;
    var dec: std.http.Decompress = undefined;
    const rd = resp.readerDecompressing(&tbuf, &dec, dbuf);
    const cap: usize = @as(usize, opts.body_maxz_kbyt) * CF.kilo;
    res.body = rd.allocRemaining(a, .limited(cap)) catch |e| {
        if (e == error.StreamTooLong) shot.big = true;
        return e;
    };
    shot.resp = res;
}

fn once(io: std.Io, a: std.mem.Allocator, opts: Opts, req: Req) HttpErro!Resp {
    const gene = g_gene.fetchAdd(1, .acq_rel) + 1;
    defer _ = g_gene.fetchAdd(1, .acq_rel);
    if (std.Thread.spawn(.{}, watch, .{ io, gene, opts.tmos_secs })) |th| th.detach() else |_| {}
    var shot: Shot = .{};
    attempt(io, a, opts, req, &shot) catch |e| {
        if (shot.big) return error.TooBig;
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return if (!shot.sent and preSend(e)) error.NetFail else error.Unsure;
    };
    return shot.resp orelse error.Unsure;
}

fn nowMsec(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn nowSecs(io: std.Io) i64 {
    return @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
}

fn log(io: std.Io, opts: Opts, req: Req, code: i64, t0: i64, note: []const u8) void {
    const au = opts.audi orelse return;
    // the query part may carry values: only the path is kept ----
    const cut = std.mem.indexOfScalar(u8, req.urlz, '?') orelse req.urlz.len;
    au.add(io, .{ .when = std.Io.Clock.real.now(io).toMilliseconds(), .kind = "http", .verb = @tagName(req.meth), .targ = req.urlz[0..cut], .code = code, .msec = nowMsec(io) - t0, .note = note });
}

// how long the vendor wants us to wait, 0 = this answer is not a rate limit ----
pub fn limitWait(r: Resp, now_secs: i64) u32 {
    const limited = r.code == 429 or (r.code == 403 and (r.wait > 0 or r.left == 0));
    if (!limited) return 0;
    if (r.wait > 0) return r.wait;
    if (r.left == 0 and r.rest > now_secs) return @intCast(@min(r.rest - now_secs, 86_400));
    return CF.wait_minz;
}

pub fn call(io: std.Io, a: std.mem.Allocator, opts: Opts, req_in: Req) HttpErro!Resp {
    var req = req_in;
    const needs = req.meth == .POST or req.meth == .PUT or req.meth == .PATCH;
    if (needs and req.body == null) req.body = "";
    if (!needs and req.body != null) return error.BadReq;
    var n: u32 = 0;
    while (true) : (n += 1) {
        const left = n < opts.retr_maxz;
        const t0 = nowMsec(io);
        const r = once(io, a, opts, req) catch |e| {
            log(io, opts, req, 0, t0, @errorName(e));
            // only a call that never left may go again; a write that may have landed must not ----
            if (e == error.NetFail and left) {
                std.Io.sleep(io, .fromMilliseconds(CF.back_msec), .awake) catch {};
                continue;
            }
            return e;
        };
        const wait = limitWait(r, nowSecs(io));
        if (wait == 0 or !left or wait > opts.wait_maxz_secs) {
            log(io, opts, req, r.code, t0, if (wait > 0) "rate limited" else "");
            return r;
        }
        log(io, opts, req, r.code, t0, "rate limited, waiting");
        std.Io.sleep(io, .fromMilliseconds(@as(i64, wait) * 1000), .awake) catch {};
    }
}

// ---- tests: a tiny canned server on a system-chosen loopback port ----
const TestSrv = struct {
    io: std.Io,
    srv: std.Io.net.Server,
    port: u16,
    replies: []const []const u8,
    seen: std.atomic.Value(u32) = .init(0),
    heads: [4][512]u8 = undefined,
    lens: [4]usize = .{ 0, 0, 0, 0 },

    fn start(io: std.Io, replies: []const []const u8) !*TestSrv {
        const self = try std.testing.allocator.create(TestSrv);
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .srv = try addr.listen(io, .{ .reuse_address = true }), .port = 0, .replies = replies };
        self.port = self.srv.socket.address.getPort();
        return self;
    }

    fn serve(self: *TestSrv) void {
        for (self.replies, 0..) |rep, i| {
            const st = self.srv.accept(self.io) catch return;
            defer st.close(self.io);
            var rb: [2048]u8 = undefined;
            var wb: [512]u8 = undefined;
            var r = st.reader(self.io, &rb);
            var w = st.writer(self.io, &wb);
            var n: usize = 0;
            // read the head, then a body of content-length bytes when one is announced ----
            var body_left: usize = 0;
            while (true) {
                const line = r.interface.takeDelimiterInclusive('\n') catch break;
                const keep = @min(line.len, self.heads[i].len - n);
                @memcpy(self.heads[i][n..][0..keep], line[0..keep]);
                n += keep;
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) body_left = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \r\n"), 10) catch 0;
                if (line.len <= 2) break;
            }
            r.interface.discardAll(body_left) catch {};
            self.lens[i] = n;
            _ = self.seen.fetchAdd(1, .acq_rel);
            w.interface.writeAll(rep) catch {};
            w.interface.flush() catch {};
        }
    }

    fn stop(self: *TestSrv) void {
        self.srv.deinit(self.io);
        std.testing.allocator.destroy(self);
    }
};

test "a 429 with Retry-After is waited out and tried again; headers reach the server once each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const srv = try TestSrv.start(io, &.{
        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
        "HTTP/1.1 200 OK\r\nX-RateLimit-Remaining: 41\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}",
    });
    const th = try std.Thread.spawn(.{}, TestSrv.serve, .{srv});
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/user?secret=1", .{srv.port});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pn = try tmp.dir.realPath(io, &pbuf);
    var au: audit.Audit = .{ .a = a, .path = try std.fs.path.join(a, &.{ pbuf[0..pn], "audit.jsonl" }) };
    const head = [_]std.http.Header{.{ .name = "authorization", .value = "Bearer tok-test-123456" }};
    const t0 = nowMsec(io);
    const r = try call(io, a, .{ .audi = &au, .user_agen = "ua-test" }, .{ .urlz = url, .head = &head });
    th.join();
    defer srv.stop();
    try std.testing.expectEqual(@as(u16, 200), r.code);
    try std.testing.expectEqualStrings("{\"ok\":true}", r.body);
    try std.testing.expectEqual(@as(i64, 41), r.left);
    try std.testing.expectEqual(@as(u32, 2), srv.seen.load(.acquire));
    try std.testing.expect(nowMsec(io) - t0 >= 900);
    const first = srv.heads[0][0..srv.lens[0]];
    try std.testing.expect(std.ascii.indexOfIgnoreCase(first, "authorization: Bearer tok-test-123456") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, "ua-test"));
    const logged = try std.Io.Dir.cwd().readFileAlloc(io, au.path, a, .limited(4096));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, logged, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, logged, "tok-test") == null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "secret") == null);
}

test "a wait above the cap is handed back, not slept; POST sends its body; a body on GET is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const srv = try TestSrv.start(io, &.{
        "HTTP/1.1 403 Forbidden\r\nRetry-After: 3600\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
        "HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
    });
    const th = try std.Thread.spawn(.{}, TestSrv.serve, .{srv});
    const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/x", .{srv.port});
    const r = try call(io, a, .{}, .{ .urlz = url });
    try std.testing.expectEqual(@as(u16, 403), r.code);
    try std.testing.expectEqual(@as(u32, 3600), r.wait);
    const p = try call(io, a, .{}, .{ .meth = .POST, .urlz = url, .body = "{\"name\":\"x\"}" });
    th.join();
    defer srv.stop();
    try std.testing.expectEqual(@as(u16, 201), p.code);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(srv.heads[1][0..srv.lens[1]], "content-length: 12") != null);
    try std.testing.expectError(error.BadReq, call(io, a, .{}, .{ .urlz = url, .body = "x" }));
}

test "limitWait: only real rate limits wait; a refused connect is NetFail" {
    try std.testing.expectEqual(@as(u32, 0), limitWait(.{ .code = 403, .body = &.{} }, 100));
    try std.testing.expectEqual(@as(u32, 0), limitWait(.{ .code = 404, .body = &.{}, .wait = 9 }, 100));
    try std.testing.expectEqual(@as(u32, 7), limitWait(.{ .code = 429, .body = &.{}, .wait = 7 }, 100));
    try std.testing.expectEqual(@as(u32, 1), limitWait(.{ .code = 429, .body = &.{} }, 100));
    try std.testing.expectEqual(@as(u32, 50), limitWait(.{ .code = 403, .body = &.{}, .left = 0, .rest = 150 }, 100));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.NetFail, call(std.testing.io, arena.allocator(), .{ .retr_maxz = 0 }, .{ .urlz = "http://127.0.0.1:1/x" }));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
