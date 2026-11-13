// =====================================================================
// Des: Writes the handoff file the Schedule layer reads: the project, region, service and the tick URL. Never holds a secret.
// Flo: build the row > write next to the file > rename over it
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path, Row
// Out: ggc-run-handoff.json
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .vers = 1, .vend = "ggcr", .part = ".part", .fileMaxz = 1 << 16 };

// the handoff contract, v1
pub const Row = struct { vers: u32 = CF.vers, vend: []const u8 = CF.vend, proj: []const u8, regi: []const u8, serv: []const u8, uri: []const u8, tick_url: []const u8 };

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

test "handoff is written once and not rewritten when equal" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const a = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmpz.dir.realPath(std.testing.io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "sub", "hand.json" });
    const row = Row{ .proj = "p", .regi = "r", .serv = "s", .uri = "https://s.run.app", .tick_url = "https://s.run.app/tick" };
    try std.testing.expect(try write(std.testing.io, a, path, row));
    try std.testing.expect(!(try write(std.testing.io, a, path, row)));
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, text, "https://s.run.app/tick") != null);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
