// One HTTP/1.1 GET to a PINNED ip. Own client: std.http.Client re-resolves DNS and follows its own rules.
// Refuses: redirects (returned, never followed), Content-Encoding (we ask identity; a gzip reply is refused = no bomb), bodies over the cap.
// Time cap: a watchdog shuts the socket at the deadline. Connect runs on a helper thread so a blackholed IP cannot hang the caller.
const std = @import("std");
const Io = std.Io;
const guard = @import("co-guard.zig");

pub const Err = error{ Timeout, Connect, Tls, Proto, TooBig, Encoded, OutOfMemory };

pub const Opts = struct {
    ua: []const u8,
    timeout_s: u32,
    cap_bytes: usize,
    headers: []const std.http.Header = &.{},
    method: []const u8 = "GET",
    body: ?[]const u8 = null,
    head_cap: usize = 16 * 1024,
};

pub const Resp = struct {
    status: u16,
    retry_after_s: u32 = 0,
    content_type: []const u8 = "",
    location: []const u8 = "",
    cf_mitigated: bool = false,
    headers: []const u8 = "", // raw head lines (for credit headers etc.), arena-owned
    body: []u8,
};

// value of a header in the raw head blob Resp.headers (case-insensitive) or ""
pub fn headerValue(head: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |l| {
        if (l.len > name.len and l[name.len] == ':' and std.ascii.eqlIgnoreCase(l[0..name.len], name)) return std.mem.trim(u8, l[name.len + 1 ..], " \t");
    }
    return "";
}

// ---- CA bundle (loaded once per process) ----
var g_bundle: std.crypto.Certificate.Bundle = .empty;
var g_lock: Io.RwLock = .init;
var g_loaded: bool = false;
// tests only: extra CA pem file (self-signed mock TLS)
pub var extra_ca_file: ?[]const u8 = null;

fn ensureBundle(io: Io) Err!void {
    g_lock.lock(io) catch return Err.Tls;
    defer g_lock.unlock(io);
    if (g_loaded) return;
    const gpa = std.heap.page_allocator;
    g_bundle.rescan(gpa, io, Io.Clock.real.now(io)) catch return Err.Tls;
    if (extra_ca_file) |p| {
        g_bundle.addCertsFromFilePath(gpa, io, Io.Clock.real.now(io), std.Io.Dir.cwd(), p) catch return Err.Tls;
    }
    g_loaded = true;
}

// ---- connect helper thread ----
const Conn = struct {
    io: Io,
    ip: Io.net.IpAddress,
    state: std.atomic.Value(u8) = .init(0), // 0 run · 1 ok · 2 err · 3 abandoned
    stream: Io.net.Stream = undefined,
};

fn connWorker(c: *Conn) void {
    if (c.ip.connect(c.io, .{ .mode = .stream })) |s| {
        c.stream = s;
        if (c.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
            s.close(c.io);
            std.heap.page_allocator.destroy(c);
        }
    } else |_| {
        if (c.state.cmpxchgStrong(0, 2, .acq_rel, .acquire) != null) std.heap.page_allocator.destroy(c);
    }
}

fn connectTimed(io: Io, ip: Io.net.IpAddress, deadline_ms: i64) Err!Io.net.Stream {
    const c = std.heap.page_allocator.create(Conn) catch return Err.OutOfMemory;
    c.* = .{ .io = io, .ip = ip };
    const th = std.Thread.spawn(.{}, connWorker, .{c}) catch {
        std.heap.page_allocator.destroy(c);
        return Err.Connect;
    };
    th.detach();
    while (true) {
        const st = c.state.load(.acquire);
        if (st == 1) {
            const s = c.stream;
            std.heap.page_allocator.destroy(c);
            return s;
        }
        if (st == 2) {
            std.heap.page_allocator.destroy(c);
            return Err.Connect;
        }
        if (Io.Clock.awake.now(io).toMilliseconds() >= deadline_ms) {
            if (c.state.cmpxchgStrong(0, 3, .acq_rel, .acquire) == null) return Err.Timeout;
            continue; // worker finished first: loop picks the result
        }
        std.Io.sleep(io, .fromMilliseconds(3), .awake) catch {};
    }
}

// ---- watchdog ----
const Dog = struct {
    io: Io,
    stream: Io.net.Stream,
    deadline_ms: i64,
    done: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),
};

fn dogMain(d: *Dog) void {
    while (!d.done.load(.acquire)) {
        if (Io.Clock.awake.now(d.io).toMilliseconds() >= d.deadline_ms) {
            d.fired.store(true, .release);
            d.stream.shutdown(d.io, .both) catch {};
            return;
        }
        std.Io.sleep(d.io, .fromMilliseconds(10), .awake) catch {};
    }
}

pub fn get(io: Io, alloc: std.mem.Allocator, t: guard.Target, ip: Io.net.IpAddress, o: Opts) Err!Resp {
    const start = Io.Clock.awake.now(io).toMilliseconds();
    const deadline = start + @as(i64, o.timeout_s) * 1000;
    if (t.tls) try ensureBundle(io);
    const stream = try connectTimed(io, ip, deadline);
    defer stream.close(io);
    var dog = Dog{ .io = io, .stream = stream, .deadline_ms = deadline };
    const dth = std.Thread.spawn(.{}, dogMain, .{&dog}) catch return Err.Connect;
    defer {
        dog.done.store(true, .release);
        dth.join();
    }
    const r = exchange(io, alloc, t, stream, o) catch |e| {
        if (dog.fired.load(.acquire)) return Err.Timeout;
        return e;
    };
    if (dog.fired.load(.acquire)) return Err.Timeout;
    return r;
}

fn exchange(io: Io, alloc: std.mem.Allocator, t: guard.Target, stream: Io.net.Stream, o: Opts) Err!Resp {
    const tlsc = std.crypto.tls.Client;
    const bl = tlsc.min_buffer_len;
    // buffers: plain uses sbuf_r/sbuf_w directly; tls adds tls_r/tls_w (heap, they are large)
    const mem = alloc.alloc(u8, bl * 4 + 16 * 1024) catch return Err.OutOfMemory;
    defer alloc.free(mem);
    const sock_r = mem[0..bl];
    const sock_w = mem[bl .. bl * 2];
    const tls_r = mem[bl * 2 .. bl * 3 + 16 * 1024];
    const tls_w = mem[bl * 3 + 16 * 1024 ..][0..bl];
    var sr = stream.reader(io, sock_r);
    var sw = stream.writer(io, sock_w);
    var client: tlsc = undefined;
    var rd: *Io.Reader = &sr.interface;
    var wr: *Io.Writer = &sw.interface;
    if (t.tls) {
        var entropy: [tlsc.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        g_lock.lockShared(io) catch return Err.Tls;
        g_lock.unlockShared(io);
        client = tlsc.init(&sr.interface, &sw.interface, .{
            .host = .{ .explicit = t.host },
            .ca = .{ .bundle = .{ .gpa = std.heap.page_allocator, .io = io, .lock = &g_lock, .bundle = &g_bundle } },
            .write_buffer = tls_w,
            .read_buffer = tls_r,
            .entropy = &entropy,
            .realtime_now = Io.Clock.real.now(io),
            .allow_truncation_attacks = true,
        }) catch return Err.Tls;
        rd = &client.reader;
        wr = &client.writer;
    }
    // request
    wr.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n", .{ o.method, t.path, hostHeader(t), o.ua }) catch return Err.Proto;
    for (o.headers) |h| {
        if (std.mem.indexOfAny(u8, h.name, "\r\n") != null or std.mem.indexOfAny(u8, h.value, "\r\n") != null) return Err.Proto;
        wr.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return Err.Proto;
    }
    if (o.body) |b| wr.print("Content-Length: {d}\r\n", .{b.len}) catch return Err.Proto;
    wr.writeAll("\r\n") catch return Err.Proto;
    if (o.body) |b| wr.writeAll(b) catch return Err.Proto;
    wr.flush() catch return Err.Proto;
    if (t.tls) sw.interface.flush() catch return Err.Proto;
    return readResp(alloc, rd, o);
}

fn hostHeader(t: guard.Target) []const u8 {
    return t.host; // port is implied 443; mock hosts use a bare host too (server ignores it)
}

fn lower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const o = try alloc.dupe(u8, s);
    for (o) |*c| c.* = std.ascii.toLower(c.*);
    return o;
}

pub fn readResp(alloc: std.mem.Allocator, r: *Io.Reader, o: Opts) Err!Resp {
    const first = r.takeDelimiterExclusive('\n') catch return Err.Proto;
    r.toss(1);
    const sl = std.mem.trimEnd(u8, first, "\r");
    if (!std.mem.startsWith(u8, sl, "HTTP/1.")) return Err.Proto;
    var parts = std.mem.tokenizeScalar(u8, sl, ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u16, parts.next() orelse return Err.Proto, 10) catch return Err.Proto;
    var resp = Resp{ .status = status, .body = &.{} };
    var chunked = false;
    var clen: ?usize = null;
    var enc = false;
    var head_bytes: usize = sl.len;
    var raw: std.ArrayList(u8) = .empty;
    while (true) {
        const l = r.takeDelimiterExclusive('\n') catch return Err.Proto;
        r.toss(1);
        head_bytes += l.len + 1;
        if (head_bytes > o.head_cap) return Err.TooBig;
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len == 0) break;
        raw.appendSlice(alloc, t) catch return Err.OutOfMemory;
        raw.append(alloc, '\n') catch return Err.OutOfMemory;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const name = t[0..colon];
        const val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) clen = std.fmt.parseInt(usize, val, 10) catch return Err.Proto;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.indexOfIgnoreCase(val, "chunked") != null) chunked = true;
        if (std.ascii.eqlIgnoreCase(name, "content-encoding")) {
            const lv = lower(alloc, val) catch return Err.OutOfMemory;
            if (!std.mem.eql(u8, lv, "identity") and lv.len > 0) enc = true;
        }
        if (std.ascii.eqlIgnoreCase(name, "retry-after")) resp.retry_after_s = @intCast(@min(std.fmt.parseInt(u32, val, 10) catch 0, 86400));
        if (std.ascii.eqlIgnoreCase(name, "content-type")) resp.content_type = alloc.dupe(u8, val) catch return Err.OutOfMemory;
        if (std.ascii.eqlIgnoreCase(name, "location")) resp.location = alloc.dupe(u8, val) catch return Err.OutOfMemory;
        if (std.ascii.eqlIgnoreCase(name, "cf-mitigated")) resp.cf_mitigated = true;
    }
    resp.headers = raw.items;
    if (enc) return Err.Encoded;
    if (status == 204 or status == 304 or (status >= 100 and status < 200) or std.mem.eql(u8, o.method, "HEAD")) return resp;
    var body: std.ArrayList(u8) = .empty;
    if (chunked) {
        while (true) {
            const ln = r.takeDelimiterExclusive('\n') catch return Err.Proto;
            r.toss(1);
            const ts = std.mem.trim(u8, std.mem.trimEnd(u8, ln, "\r"), " ");
            const semi = std.mem.indexOfScalar(u8, ts, ';') orelse ts.len;
            const n = std.fmt.parseInt(usize, ts[0..semi], 16) catch return Err.Proto;
            if (n == 0) break;
            if (body.items.len +| n > o.cap_bytes) return Err.TooBig;
            const at = body.items.len;
            body.resize(alloc, at + n) catch return Err.OutOfMemory;
            r.readSliceAll(body.items[at..]) catch return Err.Proto;
            r.discardAll(2) catch return Err.Proto; // CRLF after the chunk
        }
    } else if (clen) |n| {
        if (n > o.cap_bytes) return Err.TooBig;
        body.resize(alloc, n) catch return Err.OutOfMemory;
        r.readSliceAll(body.items) catch return Err.Proto;
    } else {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = r.readSliceShort(&buf) catch return Err.Proto;
            if (n == 0) break;
            if (body.items.len + n > o.cap_bytes) return Err.TooBig;
            body.appendSlice(alloc, buf[0..n]) catch return Err.OutOfMemory;
        }
    }
    resp.body = body.items;
    return resp;
}

// ---- tests against the loopback mock ----
const ms = @import("te-mini-srv.zig");

const Tctx = struct { mode: u8 };

fn h1(ctx: *anyopaque, a: std.mem.Allocator, req: ms.Request) ms.Reply {
    _ = a;
    const c: *Tctx = @ptrCast(@alignCast(ctx));
    _ = c;
    if (std.mem.eql(u8, req.path, "/ok")) return .{ .body = "hello", .headers = "Content-Type: text/html\r\n" };
    if (std.mem.eql(u8, req.path, "/chunk")) return .{ .body = "hello chunked world", .chunked = true };
    if (std.mem.eql(u8, req.path, "/429")) return .{ .status = 429, .headers = "Retry-After: 120\r\n" };
    if (std.mem.eql(u8, req.path, "/redir")) return .{ .status = 302, .headers = "Location: http://127.0.0.1:1/x\r\n" };
    if (std.mem.eql(u8, req.path, "/gzip")) return .{ .headers = "Content-Encoding: gzip\r\n", .body = "\x1f\x8b\x08\x00" };
    if (std.mem.eql(u8, req.path, "/big")) return .{ .body = "x" ** 5000 };
    if (std.mem.eql(u8, req.path, "/slow")) return .{ .delay_ms = 3000, .body = "late" };
    if (std.mem.eql(u8, req.path, "/ua")) return .{ .body = ms.headerOf(req.head, "user-agent") };
    return .{ .status = 404 };
}

fn getMock(srv: *ms.Srv, path: []const u8, cap: usize, tmo: u32) Err!Resp {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // caller leaks the arena into page_allocator on purpose in tests only: results live until process exit
    const a = arena.allocator();
    var ub: [128]u8 = undefined;
    const t = guard.parseUrl(a, srv.url(&ub, path), .{ .allow_hosts = &.{}, .mock = true }) catch return Err.Proto;
    const ip = Io.net.IpAddress.parse("127.0.0.1", srv.port) catch return Err.Connect;
    return get(std.testing.io, a, t, ip, .{ .ua = "test-ua/1", .timeout_s = tmo, .cap_bytes = cap });
}

test "net: ok, chunked, status, redirect not followed, ua sent" {
    var c = Tctx{ .mode = 0 };
    const srv = try ms.Srv.start(std.testing.io, h1, &c);
    defer srv.stop();
    const r = try getMock(srv, "/ok", 1000, 5);
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("hello", r.body);
    try std.testing.expectEqualStrings("text/html", r.content_type);
    const ch = try getMock(srv, "/chunk", 1000, 5);
    try std.testing.expectEqualStrings("hello chunked world", ch.body);
    const r4 = try getMock(srv, "/429", 1000, 5);
    try std.testing.expectEqual(@as(u16, 429), r4.status);
    try std.testing.expectEqual(@as(u32, 120), r4.retry_after_s);
    const rd = try getMock(srv, "/redir", 1000, 5);
    try std.testing.expectEqual(@as(u16, 302), rd.status);
    try std.testing.expect(rd.location.len > 0);
    const ua = try getMock(srv, "/ua", 1000, 5);
    try std.testing.expectEqualStrings("test-ua/1", ua.body);
}

test "net: gzip refused, oversize refused, stall times out" {
    var c = Tctx{ .mode = 0 };
    const srv = try ms.Srv.start(std.testing.io, h1, &c);
    defer srv.stop();
    try std.testing.expectError(Err.Encoded, getMock(srv, "/gzip", 1000, 5));
    try std.testing.expectError(Err.TooBig, getMock(srv, "/big", 1000, 5));
    try std.testing.expectError(Err.Timeout, getMock(srv, "/slow", 1000, 1));
}

test "net: connect refused is Connect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try guard.parseUrl(arena.allocator(), "http://127.0.0.1:1/x", .{ .allow_hosts = &.{}, .mock = true });
    const ip = try Io.net.IpAddress.parse("127.0.0.1", 1);
    try std.testing.expectError(Err.Connect, get(std.testing.io, arena.allocator(), t, ip, .{ .ua = "x", .timeout_s = 2, .cap_bytes = 10 }));
}

// M0 spike: real TLS handshake against a local `openssl s_server` with a throwaway self-signed cert (skipped when openssl is missing).
test "net: TLS GET to a local openssl mock" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_b: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_b, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cb: [200]u8 = undefined;
    var kb: [200]u8 = undefined;
    const cert = try std.fmt.bufPrint(&cb, "{s}/c.pem", .{dir});
    const key = try std.fmt.bufPrint(&kb, "{s}/k.pem", .{dir});
    const gen = std.process.run(gpa, io, .{ .argv = &.{ "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-keyout", key, "-out", cert } }) catch return error.SkipZigTest;
    defer gpa.free(gen.stdout);
    defer gpa.free(gen.stderr);
    if (gen.term != .exited or gen.term.exited != 0) return error.SkipZigTest;
    // a free port
    var probe = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    const port = probe.socket.address.getPort();
    probe.deinit(io);
    var pb: [16]u8 = undefined;
    const ps = try std.fmt.bufPrint(&pb, "{d}", .{port});
    var child = std.process.spawn(io, .{ .argv = &.{ "openssl", "s_server", "-accept", ps, "-cert", cert, "-key", key, "-www", "-quiet" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return error.SkipZigTest;
    defer child.kill(io);
    var up = false;
    var n: u32 = 0;
    while (n < 100 and !up) : (n += 1) {
        const a = try Io.net.IpAddress.parse("127.0.0.1", port);
        if (a.connect(io, .{ .mode = .stream })) |s| {
            s.close(io);
            up = true;
        } else |_| std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    }
    try std.testing.expect(up);
    extra_ca_file = cert;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ub: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&ub, "https://localhost:{d}/", .{port});
    const t = try guard.parseUrl(arena.allocator(), url, .{ .allow_hosts = &.{}, .mock = true });
    try std.testing.expect(t.tls);
    const ip = try Io.net.IpAddress.parse("127.0.0.1", port);
    const r = try get(io, arena.allocator(), t, ip, .{ .ua = "t", .timeout_s = 10, .cap_bytes = 1 << 20 });
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "s_server") != null);
}
