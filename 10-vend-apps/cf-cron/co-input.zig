// =====================================================================
// Des: The one reader of what the human types. A background thread collects typed lines so the app can keep polling while it waits for a key like g, h, b or x.
// Flo: start thread once > read stdin lines into a queue > app takes a line, waits with a time limit, or asks a hidden value
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: lines typed on stdin
// Out: one line at a time, or null on timeout / end of input
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const builtin = @import("builtin");
const osyz = @import("co-os.zig");

const CF = .{ .lineMaxz = 8192, .tickMsec = 100, .msecSecs = 1000 };

pub const Inpu = struct {
    io: std.Io,
    mute: std.Io.Mutex = .init,
    list: std.ArrayList([]u8) = .empty,
    eofz: std.atomic.Value(bool) = .init(false),
    live: bool = false,

    // start the reader thread once; a test build never touches real stdin
    // (its fd may be the build runner's own --listen=- control pipe)
    pub fn star(self: *Inpu) void {
        if (self.live or builtin.is_test) return;
        self.live = true;
        const thre = std.Thread.spawn(.{}, loop, .{self}) catch {
            self.eofz.store(true, .release);
            return;
        };
        thre.detach();
    }

    // reader thread: one queue entry per typed line
    fn loop(self: *Inpu) void {
        var buff: [CF.lineMaxz]u8 = undefined;
        var read = std.Io.File.stdin().readerStreaming(self.io, &buff);
        while (true) {
            const line = (read.interface.takeDelimiter('\n') catch break) orelse break;
            const copy = std.heap.smp_allocator.dupe(u8, std.mem.trim(u8, line, " \r\t")) catch break;
            self.mute.lockUncancelable(self.io);
            self.list.append(std.heap.smp_allocator, copy) catch {};
            self.mute.unlock(self.io);
        }
        self.eofz.store(true, .release);
    }

    // oldest typed line, null when none is waiting
    pub fn take(self: *Inpu) ?[]u8 {
        self.mute.lockUncancelable(self.io);
        defer self.mute.unlock(self.io);
        return if (self.list.items.len == 0) null else self.list.orderedRemove(0);
    }

    // wait up to secs for a line; with input closed it still waits the full time
    pub fn wait(self: *Inpu, secs: u32) ?[]u8 {
        self.star();
        var left: u64 = @as(u64, secs) * CF.msecSecs;
        while (true) {
            if (self.take()) |line| return line;
            if (left == 0) return null;
            std.Io.sleep(self.io, .fromMilliseconds(CF.tickMsec), .awake) catch return null;
            left -|= CF.tickMsec;
        }
    }

    // block until a line arrives; null when input is closed
    pub fn next(self: *Inpu) ?[]u8 {
        self.star();
        while (true) {
            if (self.take()) |line| return line;
            if (self.eofz.load(.acquire)) return self.take();
            std.Io.sleep(self.io, .fromMilliseconds(CF.tickMsec), .awake) catch return null;
        }
    }

    // ask one hidden value: echo off, read a line, echo back on
    pub fn hidd(self: *Inpu, prom: []const u8) ?[]u8 {
        osyz.outz(self.io, "{s}", .{prom});
        const hide = osyz.echoSetz(false);
        defer if (hide) {
            _ = osyz.echoSetz(true);
            osyz.outz(self.io, "\n", .{});
        };
        return self.next();
    }
};

test "queue hands lines out in order" {
    var inpu = Inpu{ .io = std.testing.io };
    try std.testing.expect(inpu.take() == null);
    for ([_][]const u8{ "g", "x" }) |text| try inpu.list.append(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, text));
    defer inpu.list.deinit(std.heap.smp_allocator);
    const frst = inpu.take().?;
    defer std.heap.smp_allocator.free(frst);
    const scnd = inpu.take().?;
    defer std.heap.smp_allocator.free(scnd);
    try std.testing.expectEqualStrings("g", frst);
    try std.testing.expectEqualStrings("x", scnd);
    try std.testing.expect(inpu.take() == null);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
