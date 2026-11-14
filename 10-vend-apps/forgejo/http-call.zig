// =====================================================================
// Des: Makes one web call at a time for the app. Waits and retries when the vendor says slow down, never follows a redirect with a token, and logs every call.
// Flo: build request > send > read status and limit headers > read body > on 429 wait and retry > audit line > return
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: method, url, optional bearer token, optional body
// Out: status code + body text
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/forgejo && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const audi = @import("audit-log.zig");

const CF = .{ .bearPref = "Bearer ", .basiPref = "Basic ", .headRetr = "retry-after", .headRema = "ratelimit-remaining", .headRemaGith = "x-ratelimit-remaining", .codeLimi = 429, .codeForb = 403, .tranSize = 64, .msecSecs = 1000 };

pub const Head = std.http.Header;

// one request
pub const Requ = struct { meth: std.http.Method = .GET, urlz: []const u8, bear: ?[]const u8 = null, basi: ?[]const u8 = null, body: ?[]const u8 = null, ctyp: []const u8 = "application/json", xtra: []const Head = &.{} };

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
    coun: u32 = 0,
    rema: ?u32 = null,
    wait: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, logz: *audi.Audi, opts: Opts) Http {
        return .{ .gpa = gpa, .io = io, .clie = .{ .allocator = gpa, .io = io }, .logz = logz, .opts = opts };
    }

    pub fn deinit(self: *Http) void {
        self.clie.deinit();
    }

    // one call with rate-limit handling; the caller owns resp.body
    pub fn call(self: *Http, requ: Requ) !Resp {
        var trys: u32 = 0;
        while (true) {
            trys += 1;
            const star = std.Io.Clock.awake.now(self.io).toMilliseconds();
            const tryz = self.once(requ) catch |erro| {
                self.logLine(requ, -1, star);
                return erro;
            };
            self.logLine(requ, tryz.resp.code, star);
            const limi = tryz.resp.code == CF.codeLimi or (tryz.resp.code == CF.codeForb and tryz.retr != null);
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
        self.coun += 1;
        const urii = try std.Uri.parse(requ.urlz);
        const bear: ?[]u8 = if (requ.bear) |toke| try std.mem.concat(self.gpa, u8, &.{ CF.bearPref, toke }) else null;
        defer if (bear) |text| self.gpa.free(text);
        // basic auth: "user:pass" in, base64 header out
        const basi: ?[]u8 = if (requ.basi) |pair| blk: {
            const enc = std.base64.standard.Encoder;
            const outp = try self.gpa.alloc(u8, CF.basiPref.len + enc.calcSize(pair.len));
            @memcpy(outp[0..CF.basiPref.len], CF.basiPref);
            _ = enc.encode(outp[CF.basiPref.len..], pair);
            break :blk outp;
        } else null;
        defer if (basi) |text| self.gpa.free(text);
        const auth: ?[]const u8 = if (bear) |text| text else if (basi) |text| text else null;
        const hasz = requ.meth.requestHasBody();

        // redirects off: a token must never follow a 3xx to another host
        var send = try self.clie.request(requ.meth, urii, .{ .redirect_behavior = .unhandled, .keep_alive = false, .extra_headers = requ.xtra, .headers = .{ .user_agent = .{ .override = self.opts.agen }, .authorization = if (auth) |text| .{ .override = text } else .default, .content_type = if (hasz) .{ .override = requ.ctyp } else .default } });
        defer send.deinit();
        if (hasz) {
            const body = requ.body orelse "";
            send.transfer_encoding = .{ .content_length = body.len };
            var writ = try send.sendBodyUnflushed(&.{});
            try writ.writer.writeAll(body);
            try writ.end();
            try send.connection.?.flush();
        } else {
            if (requ.body != null) return error.BodyNotAllowed;
            try send.sendBodiless();
        }
        var recv = try send.receiveHead(&.{});

        // headers first: they live in the connection buffer
        var retr: ?u32 = null;
        var iter = recv.head.iterateHeaders();
        while (iter.next()) |head| {
            if (std.ascii.eqlIgnoreCase(head.name, CF.headRetr)) retr = std.fmt.parseInt(u32, std.mem.trim(u8, head.value, " "), 10) catch null;
            if (std.ascii.eqlIgnoreCase(head.name, CF.headRema) or std.ascii.eqlIgnoreCase(head.name, CF.headRemaGith)) self.rema = std.fmt.parseInt(u32, std.mem.trim(u8, head.value, " "), 10) catch self.rema;
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
        var tbuf: [CF.tranSize]u8 = undefined;
        var dcmp: std.http.Decompress = undefined;
        const read = recv.readerDecompressing(&tbuf, &dcmp, dbuf);
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
    const outp = try urlzEnco(std.testing.allocator, "ann/cloud-house x");
    defer std.testing.allocator.free(outp);
    try std.testing.expectEqualStrings("ann%2Fcloud-house%20x", outp);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
