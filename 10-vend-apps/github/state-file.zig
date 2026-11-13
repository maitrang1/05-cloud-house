// =====================================================================
// Des: Remembers which setup steps are done, skipped or still open, plus plain ids like the login name, so a stopped run resumes where it left off
// Flo: load state.json (missing = fresh) > get / set step and id values in memory > save through a .part file and a rename
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: state file path, arena allocator
// Out: State (arena-owned); the file never holds a secret
// Run: not run directly - imported by app-ctx.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

const CF = .{ .file_maxz = 1024 * 1024, .vers = 1, .part = ".part" };

pub const StatErro = error{ Unreadable, BadState, WriteFail, OutOfMemory };

pub const Mark = enum { todo, done, skipped };

pub const Row = struct { iden: []const u8, stat: Mark = .todo, note: []const u8 = "", when: i64 = 0 };

pub const Pair = struct { keyz: []const u8, valu: []const u8 };

const Disk = struct { vers: u32 = CF.vers, cons: bool = false, step: []const Row = &.{}, iden: []const Pair = &.{} };

pub const State = struct {
    a: std.mem.Allocator,
    path: []const u8,
    cons: bool = false,
    step: std.ArrayList(Row) = .empty,
    iden: std.ArrayList(Pair) = .empty,

    pub fn getz(self: *const State, iden: []const u8) Row {
        for (self.step.items) |r| if (std.mem.eql(u8, r.iden, iden)) return r;
        return .{ .iden = iden };
    }

    pub fn setz(self: *State, iden: []const u8, stat: Mark, note: []const u8, when: i64) StatErro!void {
        const row: Row = .{ .iden = try self.a.dupe(u8, iden), .stat = stat, .note = try self.a.dupe(u8, note), .when = when };
        for (self.step.items) |*r| if (std.mem.eql(u8, r.iden, iden)) {
            r.* = row;
            return;
        };
        try self.step.append(self.a, row);
    }

    pub fn valu(self: *const State, keyz: []const u8) []const u8 {
        for (self.iden.items) |p| if (std.mem.eql(u8, p.keyz, keyz)) return p.valu;
        return "";
    }

    pub fn putz(self: *State, keyz: []const u8, v: []const u8) StatErro!void {
        const copy = try self.a.dupe(u8, v);
        for (self.iden.items) |*p| if (std.mem.eql(u8, p.keyz, keyz)) {
            p.valu = copy;
            return;
        };
        try self.iden.append(self.a, .{ .keyz = try self.a.dupe(u8, keyz), .valu = copy });
    }

    // write next to the file, then rename over it: no gap where the state is gone ----
    pub fn save(self: *const State, io: std.Io) StatErro!void {
        const disk: Disk = .{ .cons = self.cons, .step = self.step.items, .iden = self.iden.items };
        const text = std.json.Stringify.valueAlloc(self.a, disk, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
        const part = std.mem.concat(self.a, u8, &.{ self.path, CF.part }) catch return error.OutOfMemory;
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(self.path)) |d| cwd.createDirPath(io, d) catch return error.WriteFail;
        cwd.writeFile(io, .{ .sub_path = part, .data = text }) catch return error.WriteFail;
        cwd.rename(part, cwd, self.path, io) catch return error.WriteFail;
    }
};

pub fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) StatErro!State {
    var st: State = .{ .a = a, .path = try a.dupe(u8, path) };
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(CF.file_maxz)) catch |e| {
        return if (e == error.FileNotFound) st else error.Unreadable;
    };
    const disk = std.json.parseFromSliceLeaky(Disk, a, raw, .{ .allocate = .alloc_always }) catch return error.BadState;
    if (disk.vers != CF.vers) return error.BadState;
    st.cons = disk.cons;
    try st.step.appendSlice(a, disk.step);
    try st.iden.appendSlice(a, disk.iden);
    return st;
}

test "fresh state, set, save, load again; a broken file is refused, never reset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "sub", "state.json" });
    var st = try load(io, a, path);
    try std.testing.expectEqual(Mark.todo, st.getz("repo-make").stat);
    try st.setz("repo-make", .done, "made", 5);
    try st.setz("rule-bran", .skipped, "skipped: plan", 6);
    try st.setz("repo-make", .done, "made twice", 7);
    try st.putz("logi", "octo");
    try st.putz("logi", "octo2");
    st.cons = true;
    try st.save(io);
    const back = try load(io, a, path);
    try std.testing.expectEqual(@as(usize, 2), back.step.items.len);
    try std.testing.expectEqualStrings("made twice", back.getz("repo-make").note);
    try std.testing.expectEqual(Mark.skipped, back.getz("rule-bran").stat);
    try std.testing.expectEqualStrings("octo2", back.valu("logi"));
    try std.testing.expectEqualStrings("", back.valu("none"));
    try std.testing.expect(back.cons);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{broken" });
    try std.testing.expectError(error.BadState, load(io, a, path));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
