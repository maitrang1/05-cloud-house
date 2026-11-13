// =====================================================================
// Des: Keeps a local, append-only record of every outside call the app makes. Secrets are masked before a line is written, so the log is safe to read.
// Flo: take a call > mask secrets > build one JSON line > append to the log file
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: kind, text (url or command), status code, milliseconds
// Out: one line appended to the audit log
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .mask = "***", .keyzList = [_][]const u8{ "token", "secret", "code", "key", "pass" }, .prefList = [_][]const u8{ "cfut_", "cfat_", "cfk_", "ghp_", "gho_", "github_pat_" } };

// one audit line, v1
const Line = struct { time: i64, step: []const u8, kind: []const u8, what: []const u8, code: i64, msec: i64 };

// true for bytes that can be part of a token
fn tokeByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.';
}

// true when a query key names a secret
fn keyzSecr(keyz: []const u8) bool {
    for (CF.keyzList) |need| if (std.ascii.indexOfIgnoreCase(keyz, need) != null) return true;
    return false;
}

// mask secrets: url passwords, secret query values, known token prefixes
pub fn redaText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var outp: std.ArrayList(u8) = .empty;
    var indx: usize = 0;
    while (indx < text.len) {
        // user:password@ inside a url
        if (std.mem.startsWith(u8, text[indx..], "://")) {
            const rest = text[indx + 3 ..];
            const stop = std.mem.indexOfAny(u8, rest, "/ ?") orelse rest.len;
            if (std.mem.lastIndexOfScalar(u8, rest[0..stop], '@')) |atzz| {
                try outp.appendSlice(gpa, "://" ++ CF.mask ++ "@");
                indx += 3 + atzz + 1;
                continue;
            }
        }
        // ?key=value or &key=value with a secret key
        if (text[indx] == '?' or text[indx] == '&') {
            const rest = text[indx + 1 ..];
            const stop = std.mem.indexOfAny(u8, rest, "& ") orelse rest.len;
            if (std.mem.indexOfScalar(u8, rest[0..stop], '=')) |eqzz| if (keyzSecr(rest[0..eqzz])) {
                try outp.append(gpa, text[indx]);
                try outp.appendSlice(gpa, rest[0 .. eqzz + 1]);
                try outp.appendSlice(gpa, CF.mask);
                indx += 1 + stop;
                continue;
            };
        }
        // a bare token by its prefix
        const pref: ?[]const u8 = for (CF.prefList) |item| {
            if (std.mem.startsWith(u8, text[indx..], item)) break item;
        } else null;
        if (pref) |item| {
            try outp.appendSlice(gpa, item);
            try outp.appendSlice(gpa, CF.mask);
            indx += item.len;
            while (indx < text.len and tokeByte(text[indx])) indx += 1;
            continue;
        }
        try outp.append(gpa, text[indx]);
        indx += 1;
    }
    return outp.toOwnedSlice(gpa);
}

// the audit log file
pub const Audi = struct {
    io: std.Io,
    path: []const u8,
    step: []const u8 = "-",
    fail: bool = false,

    // append one masked line; a write failure is flagged, never fatal
    pub fn line(self: *Audi, gpa: std.mem.Allocator, kind: []const u8, what: []const u8, code: i64, msec: i64) void {
        self.lineTryz(gpa, kind, what, code, msec) catch {
            if (!self.fail) std.debug.print("warn: audit log not writable: {s}\n", .{self.path});
            self.fail = true;
        };
    }

    fn lineTryz(self: *Audi, gpa: std.mem.Allocator, kind: []const u8, what: []const u8, code: i64, msec: i64) !void {
        const safe = try redaText(gpa, what);
        defer gpa.free(safe);
        const json = try std.json.Stringify.valueAlloc(gpa, Line{ .time = std.Io.Clock.real.now(self.io).toMilliseconds(), .step = self.step, .kind = kind, .what = safe, .code = code, .msec = msec }, .{});
        defer gpa.free(json);
        const text = try std.mem.concat(gpa, u8, &.{ json, "\n" });
        defer gpa.free(text);
        var file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{ .read = true, .truncate = false });
        defer file.close(self.io);
        try file.writePositionalAll(self.io, text, try file.length(self.io));
    }
};

test "redaction masks every secret shape" {
    const gpa = std.testing.allocator;
    const case = [_][2][]const u8{
        .{ "https://user:pw@api.render.com/v1/services", "https://***@api.render.com/v1/services" },
        .{ "GET https://x.test/o?name=1&api_key=zzz&limit=5", "GET https://x.test/o?name=1&api_key=***&limit=5" },
        .{ "key cfut_AbC_12-xy. done", "key cfut_*** done" },
        .{ "https://api.render.com/v1/services?name=cloud-house", "https://api.render.com/v1/services?name=cloud-house" },
    };
    for (case) |pair| {
        const outp = try redaText(gpa, pair[0]);
        defer gpa.free(outp);
        try std.testing.expectEqualStrings(pair[1], outp);
    }
}

test "audit appends lines and never a secret" {
    const gpa = std.testing.allocator;
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buff: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmpz.dir.realPath(std.testing.io, &buff);
    const path = try std.fs.path.join(gpa, &.{ buff[0..size], "audit.log" });
    defer gpa.free(path);
    var audi = Audi{ .io = std.testing.io, .path = path };
    audi.line(gpa, "http", "POST https://x.test/t?token=cfut_SECRET", 201, 5);
    audi.line(gpa, "tool", "git push", 0, 9);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4096));
    defer gpa.free(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "git push") != null);
    try std.testing.expect(!audi.fail);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
