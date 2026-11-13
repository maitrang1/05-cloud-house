// =====================================================================
// Des: The two small files shared with other apps. Reads the tick URL out of the Trigger layer's handoff file (ggc-run). Writes this app's own handoff file: job id, tick URL, header name, the vault key name of the secret. Never the secret itself.
// Flo: read: parse JSON > take the url field > check > return; write: build the row > skip when equal > write next to the file > rename over it
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: file paths, field name, Row
// Out: the tick URL text; cronjoborg-handoff.json
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .vers = 1, .vend = "cjob", .part = ".part", .fileMaxz = 1 << 16 };

pub const Erro = error{ HandMiss, HandForm };

// the handoff contract, v1 (secret_key = the vault key NAME, not a value)
pub const Row = struct { vers: u32 = CF.vers, vend: []const u8 = CF.vend, job_id: []const u8, title: []const u8, tick_url: []const u8, schedule: []const u8, secret_head: []const u8, secret_key: []const u8 };

// the url in another app's handoff file; error when the file or field is missing
pub fn tickRead(io: std.Io, a: std.mem.Allocator, path: []const u8, fiel: []const u8) ![]const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.fileMaxz)) catch return error.HandMiss;
    const val = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch return error.HandForm;
    if (val != .object) return error.HandForm;
    const one = val.object.get(fiel) orelse return error.HandForm;
    if (one != .string or one.string.len == 0) return error.HandForm;
    return one.string;
}

// write the row; returns true when the file text changed
pub fn write(io: std.Io, a: std.mem.Allocator, path: []const u8, row: Row) !bool {
    const text = try std.json.Stringify.valueAlloc(a, row, .{ .whitespace = .indent_2 });
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.fileMaxz)) catch "";
    if (std.mem.eql(u8, old, text)) return false;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    const part = try std.mem.concat(a, u8, &.{ path, CF.part });
    try cwd.writeFile(io, .{ .sub_path = part, .data = text });
    try cwd.rename(part, cwd, path, io);
    return true;
}

test "handoff is written once, not rewritten when equal, and holds no secret" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const a = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmpz.dir.realPath(std.testing.io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "sub", "hand.json" });
    const row = Row{ .job_id = "42", .title = "t", .tick_url = "https://s.run.app/tick", .schedule = "every minute", .secret_head = "X-Tick-Secret", .secret_key = "cronjoborg.tick" };
    try std.testing.expect(try write(std.testing.io, a, path, row));
    try std.testing.expect(!(try write(std.testing.io, a, path, row)));
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, text, "https://s.run.app/tick") != null);
}

test "tick url read from another handoff file" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const a = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmpz.dir.realPath(std.testing.io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "ggc.json" });
    try std.testing.expectError(error.HandMiss, tickRead(std.testing.io, a, path, "tick_url"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{\"tick_url\":\"https://x.run.app/tick\",\"proj\":\"p\"}" });
    try std.testing.expectEqualStrings("https://x.run.app/tick", try tickRead(std.testing.io, a, path, "tick_url"));
    try std.testing.expectError(error.HandForm, tickRead(std.testing.io, a, path, "nope"));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "[1]" });
    try std.testing.expectError(error.HandForm, tickRead(std.testing.io, a, path, "tick_url"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
