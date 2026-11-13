// =====================================================================
// Des: Makes one signed web call to AWS at a time. Signs every request (SigV4), waits and retries when AWS says slow down, never follows a redirect, and refuses DELETE for good. Every call is logged.
// Flo: build request > sign > send > read status and body > on 429 wait and retry > audit line > return
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: method, url, optional JSON body
// Out: status code + body text
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const audi = @import("co-audit.zig");
const sign = @import("ap-sign.zig");
const tmpo = @import("co-time.zig");

const CF = .{ .headRetr = "retry-after", .codeLimi = 429, .tranSize = 64, .msecSecs = 1000 };

pub const Erro = error{ NeverDelete, NoCreds };

// one request
pub const Requ = struct {
    meth: std.http.Method = .GET,
    urlz: []const u8,
    body: []const u8 = "",
    serv: []const u8, // signing service name (sts, iam, events ...)
    regi: []const u8, // signing region
    ctyp: []const u8 = "", // content-type; empty for bodiless calls
    amzt: []const u8 = "", // x-amz-target
};

// one response
pub const Resp = struct {
    code: u16,
    body: []u8,

    // true for any 2xx
    pub fn okay(self: Resp) bool {
        return self.code >= 200 and self.code < 300;
    }
};

// retry settings (from config)
pub const Opts = struct { trys: u32, back: u32, maxw: u32, agen: []const u8, maxb: u32 };

const Once = struct { resp: Resp, retr: ?u32 };

pub const Http = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    clie: std.http.Client,
    logz: *audi.Audi,
    opts: Opts,
    creds: ?sign.Creds = null,
    coun: u32 = 0,
    wait: u64 = 0,
    skew: i64 = 0, // test knob: seconds added to the clock

    pub fn init(gpa: std.mem.Allocator, io: std.Io, logz: *audi.Audi, opts: Opts) Http {
        return .{ .gpa = gpa, .io = io, .clie = .{ .allocator = gpa, .io = io }, .logz = logz, .opts = opts };
    }

    pub fn deinit(self: *Http) void {
        self.clie.deinit();
    }

    // one call with rate-limit handling; the caller owns resp.body
    pub fn call(self: *Http, requ: Requ) !Resp {
        if (requ.meth == .DELETE) return error.NeverDelete; // the app never deletes anything
        var trys: u32 = 0;
        while (true) {
            trys += 1;
            const star = std.Io.Clock.awake.now(self.io).toMilliseconds();
            const tryz = self.once(requ) catch |erro| {
                self.logLine(requ, -1, star);
                return erro;
            };
            self.logLine(requ, tryz.resp.code, star);
            const limi = tryz.resp.code == CF.codeLimi;
            const busy = requ.meth == .GET and (tryz.resp.code == 502 or tryz.resp.code == 503 or tryz.resp.code == 504);
            if (!(limi or busy) or trys >= self.opts.trys) return tryz.resp;
            self.gpa.free(tryz.resp.body);
            // honor Retry-After, else back off; always capped
            const expo = std.math.shl(u64, self.opts.back, trys - 1);
            const secs = @min(@as(u64, tryz.retr orelse @intCast(@min(expo, self.opts.maxw))), self.opts.maxw);
            self.wait += secs;
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(secs * CF.msecSecs)), .awake) catch return error.Canceled;
        }
    }

    // audit one attempt
    fn logLine(self: *Http, requ: Requ, code: i64, star: i64) void {
        var buff: [2048]u8 = undefined;
        const what = std.fmt.bufPrint(&buff, "{s} {s}", .{ @tagName(requ.meth), requ.urlz }) catch buff[0..0];
        self.logz.line(self.gpa, "http", what, code, std.Io.Clock.awake.now(self.io).toMilliseconds() - star);
    }

    // one attempt, no retry
    fn once(self: *Http, requ: Requ) !Once {
        const creds = self.creds orelse return error.NoCreds;
        self.coun += 1;
        const urii = try std.Uri.parse(requ.urlz);

        // host as sent (with a port when the url has one), path and query as sent
        var hbuf: [256]u8 = undefined;
        var hwri: std.Io.Writer = .fixed(&hbuf);
        try urii.writeToStream(&hwri, .{ .authority = true });
        const host = hwri.buffered();
        var pbuf: [1024]u8 = undefined;
        var pwri: std.Io.Writer = .fixed(&pbuf);
        try urii.writeToStream(&pwri, .{ .path = true });
        const path = if (pwri.buffered().len == 0) "/" else pwri.buffered();
        var qbuf: [1024]u8 = undefined;
        var qwri: std.Io.Writer = .fixed(&qbuf);
        if (urii.query != null) try urii.query.?.formatQuery(&qwri);
        const quer = qwri.buffered();

        const secs = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), CF.msecSecs) + self.skew;
        const amzd = tmpo.amzDate(secs);
        const hasz = requ.meth.requestHasBody();
        const sigd = try sign.sign(self.gpa, creds, .{ .meth = @tagName(requ.meth), .host = host, .path = path, .query = quer, .ctyp = requ.ctyp, .amzt = requ.amzt, .body = requ.body, .regi = requ.regi, .serv = requ.serv, .amzd = &amzd });
        defer self.gpa.free(sigd.auth);

        var xtra: [2]std.http.Header = .{ .{ .name = "x-amz-date", .value = &amzd }, .{ .name = "x-amz-target", .value = requ.amzt } };
        const xcnt: usize = if (requ.amzt.len > 0) 2 else 1;

        // redirects off: a signed request must never follow a 3xx to another host
        var send = try self.clie.request(requ.meth, urii, .{ .redirect_behavior = .unhandled, .keep_alive = false, .extra_headers = xtra[0..xcnt], .headers = .{ .host = .{ .override = host }, .user_agent = .{ .override = self.opts.agen }, .authorization = .{ .override = sigd.auth }, .content_type = if (requ.ctyp.len > 0) .{ .override = requ.ctyp } else .default } });
        defer send.deinit();
        if (hasz) {
            send.transfer_encoding = .{ .content_length = requ.body.len };
            var writ = try send.sendBodyUnflushed(&.{});
            try writ.writer.writeAll(requ.body);
            try writ.end();
            try send.connection.?.flush();
        } else {
            try send.sendBodiless();
        }
        var recv = try send.receiveHead(&.{});

        // headers first: they live in the connection buffer
        var retr: ?u32 = null;
        var iter = recv.head.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, CF.headRetr)) retr = std.fmt.parseInt(u32, std.mem.trim(u8, head.value, " "), 10) catch null;
        }
        const code: u16 = @intFromEnum(recv.head.status);

        // body, decompressed when the server compressed it
        const dbuf: []u8 = switch (recv.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer self.gpa.free(dbuf);
        var tbf2: [CF.tranSize]u8 = undefined;
        var dcmp: std.http.Decompress = undefined;
        const read = recv.readerDecompressing(&tbf2, &dcmp, dbuf);
        const body = read.allocRemaining(self.gpa, .limited(self.opts.maxb)) catch |erro| switch (erro) {
            error.ReadFailed => return recv.bodyErr() orelse error.ReadFailed,
            else => return erro,
        };
        return .{ .resp = .{ .code = code, .body = body }, .retr = retr };
    }
};

// percent-encode one path or query part
pub fn urlzEnco(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var outp: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try outp.append(gpa, byte) else try outp.print(gpa, "%{X:0>2}", .{byte});
    }
    return outp.toOwnedSlice(gpa);
}

test "url encoding" {
    const outp = try urlzEnco(std.testing.allocator, "arn:x/a b");
    defer std.testing.allocator.free(outp);
    try std.testing.expectEqualStrings("arn%3Ax%2Fa%20b", outp);
}

test "DELETE is refused before any network is touched" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    var logz = audi.Audi{ .io = std.testing.io, .path = "/dev/null/none", .fail = true };
    var http = Http.init(aren.allocator(), std.testing.io, &logz, .{ .trys = 1, .back = 1, .maxw = 1, .agen = "t", .maxb = 1024 });
    defer http.deinit();
    try std.testing.expectError(error.NeverDelete, http.call(.{ .meth = .DELETE, .urlz = "http://127.0.0.1:1/x", .serv = "x", .regi = "r" }));
    try std.testing.expectEqual(@as(u32, 0), http.coun);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
