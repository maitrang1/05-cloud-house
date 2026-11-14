// =====================================================================
// Des: The step list as data: reads 10-steps.json (built into the program) so the dry-run and the tests use the same list the docs show.
// Flo: embed the json > parse > hand out the rows
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: 10-steps.json
// Out: Def rows
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

pub const Def = struct { numb: u32, iden: []const u8, kind: []const u8, hand: u32, name: []const u8, need: []const u8, done: []const u8 };
pub const File = struct { vers: u32, vend: []const u8, step: []const Def };

const text = @embedFile("10-steps.json");

// parse the embedded list (arena allocator expected)
pub fn load(gpa: std.mem.Allocator) !File {
    return std.json.parseFromSliceLeaky(File, gpa, text, .{ .allocate = .alloc_always });
}

// how many steps need a human
pub fn handCoun(file: File) u32 {
    var coun: u32 = 0;
    for (file.step) |item| {
        if (item.hand > 0) coun += 1;
    }
    return coun;
}

test "step list parses and has exactly 2 hand jobs" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const file = try load(aren.allocator());
    try std.testing.expectEqual(@as(usize, 11), file.step.len);
    try std.testing.expectEqual(@as(u32, 2), handCoun(file));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
