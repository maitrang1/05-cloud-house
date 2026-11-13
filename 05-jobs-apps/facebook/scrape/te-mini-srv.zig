// Loopback HTTP mock server for tests: spare port from the OS, one thread per connection, handler returns a Reply.
const std = @import("std");
const Io = std.Io;

pub const Request = struct { method: []const u8, path: []const u8, head: []const u8, body: []const u8 };
pub const Reply = struct {
    status: u16 = 200,
    headers: []const u8 = "", // raw lines, each ending \r\n
    body: []const u8 = "",
    chunked: bool = false,
    raw: ?[]const u8 = null, // send verbatim (bad framing tests)
    delay_ms: u32 = 0,
    close_early: bool = false,
};
pub const Handler = *const fn (ctx: *anyopaque, a: std.mem.Allocator, req: Request) Reply;

pub const Srv = struct {
    io: Io,
    server: Io.net.Server,
    port: u16,
    handler: Handler,
    ctx: *anyopaque,
    stop_flag: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    seen: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    pub fn start(io: Io, handler: Handler, ctx: *anyopaque) !*Srv {
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var s = try addr.listen(io, .{ .reuse_address = true });
        errdefer s.deinit(io);
        const self = try std.heap.page_allocator.create(Srv);
        self.* = .{ .io = io, .server = s, .port = s.socket.address.getPort(), .handler = handler, .ctx = ctx };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    pub fn url(self: *const Srv, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch buf[0..0];
    }

    pub fn stop(self: *Srv) void {
        self.stop_flag.store(true, .release);
        // wake accept
        if (Io.net.IpAddress.parse("127.0.0.1", self.port)) |a| {
            if (a.connect(self.io, .{ .mode = .stream })) |st| st.close(self.io) else |_| {}
        } else |_| {}
        if (self.thread) |t| t.join();
        var n: u32 = 0;
        while (self.active.load(.acquire) > 0 and n < 400) : (n += 1) std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        self.server.deinit(self.io);
        std.heap.page_allocator.destroy(self);
    }
};

fn loop(self: *Srv) void {
    while (!self.stop_flag.load(.acquire)) {
        const st = self.server.accept(self.io) catch break;
        if (self.stop_flag.load(.acquire)) {
            st.close(self.io);
            break;
        }
        _ = self.active.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{}, conn, .{ self, st }) catch {
            _ = self.active.fetchSub(1, .acq_rel);
            st.close(self.io);
            continue;
        };
        th.detach();
    }
}

fn conn(self: *Srv, st_in: Io.net.Stream) void {
    defer _ = self.active.fetchSub(1, .acq_rel);
    var st = st_in;
    defer st.close(self.io);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rb: [8192]u8 = undefined;
    var wb: [4096]u8 = undefined;
    var r = st.reader(self.io, &rb);
    var w = st.writer(self.io, &wb);
    handle(self, a, &r.interface, &w.interface) catch {};
}

fn handle(self: *Srv, a: std.mem.Allocator, r: *Io.Reader, w: *Io.Writer) !void {
    var head: std.ArrayList(u8) = .empty;
    const first = try r.takeDelimiterExclusive('\n');
    r.toss(1);
    const line = std.mem.trimEnd(u8, first, "\r");
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = try a.dupe(u8, it.next() orelse return);
    const target = try a.dupe(u8, it.next() orelse return);
    var clen: usize = 0;
    while (true) {
        const l = try r.takeDelimiterExclusive('\n');
        r.toss(1);
        const t = std.mem.trimEnd(u8, l, "\r");
        if (t.len == 0) break;
        try head.appendSlice(a, t);
        try head.append(a, '\n');
        if (std.ascii.startsWithIgnoreCase(t, "content-length:")) clen = std.fmt.parseInt(usize, std.mem.trim(u8, t[15..], " "), 10) catch 0;
    }
    const body = try a.alloc(u8, @min(clen, 1 << 20));
    if (body.len > 0) try r.readSliceAll(body);
    _ = self.seen.fetchAdd(1, .acq_rel);
    const rep = self.handler(self.ctx, a, .{ .method = method, .path = target, .head = head.items, .body = body });
    if (rep.delay_ms > 0) std.Io.sleep(self.io, .fromMilliseconds(rep.delay_ms), .awake) catch {};
    if (rep.close_early) return;
    if (rep.raw) |raw| {
        try w.writeAll(raw);
        try w.flush();
        return;
    }
    try w.print("HTTP/1.1 {d} X\r\n{s}Connection: close\r\n", .{ rep.status, rep.headers });
    if (rep.chunked) {
        try w.writeAll("Transfer-Encoding: chunked\r\n\r\n");
        var off: usize = 0;
        while (off < rep.body.len) {
            const n = @min(7, rep.body.len - off);
            try w.print("{x}\r\n", .{n});
            try w.writeAll(rep.body[off .. off + n]);
            try w.writeAll("\r\n");
            off += n;
        }
        try w.writeAll("0\r\n\r\n");
    } else {
        try w.print("Content-Length: {d}\r\n\r\n", .{rep.body.len});
        try w.writeAll(rep.body);
    }
    try w.flush();
}

// header value from a raw head blob (case-insensitive), or ""
pub fn headerOf(head: []const u8, name: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, head, '\n');
    while (it.next()) |l| {
        if (l.len > name.len and l[name.len] == ':' and std.ascii.eqlIgnoreCase(l[0..name.len], name)) return std.mem.trim(u8, l[name.len + 1 ..], " ");
    }
    return "";
}
