// =====================================================================
// Des: Remembers how far the setup got. Stores each step as todo, done or skipped, plus plain ids. Never a secret. A stopped run resumes from here.
// Flo: load file (or start empty) > set step status and ids > save by write-then-rename
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: path of the state file
// Out: Stat struct in memory, JSON file on disk
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .fileMaxz = 1 << 20, .partExte = ".part", .versNowz = 1 };

// status of one step
pub const Mark = enum { todo, done, skip };

// one step row in the state file
pub const Step = struct { iden: []const u8, mark: Mark = .todo, note: []const u8 = "", time: i64 = 0 };

// plain ids the steps learn (no secrets, ever)
pub const Idsz = struct {
    ghOwne: []const u8 = "",
    ghRepo: []const u8 = "",
    ghMail: []const u8 = "",
    ghUrlz: []const u8 = "",
    glUser: []const u8 = "",
    glUsid: u64 = 0,
    glMail: []const u8 = "",
    glProj: u64 = 0,
    glUrlz: []const u8 = "",
    glKeyz: u64 = 0,
    tokeIden: u64 = 0,
    tokeExpi: []const u8 = "",
    secrIden: u64 = 0,
    pingSent: bool = false,
    logiFrom: []const u8 = "",
    handSign: bool = false,
    handMail: bool = false,
    handLogi: bool = false,
    handPast: bool = false,
};

// the state file contract, v1
pub const Data = struct { vers: u32 = CF.versNowz, step: []Step = &.{}, idsz: Idsz = .{} };

pub const Stat = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    data: Data = .{},

    // load the file, or start empty when it is missing (arena allocator expected)
    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Stat {
        var self = Stat{ .gpa = gpa, .io = io, .path = path };
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| switch (erro) {
            error.FileNotFound => return self,
            else => return erro,
        };
        self.data = try std.json.parseFromSliceLeaky(Data, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (self.data.vers != CF.versNowz) return error.StatVers;
        return self;
    }

    // status of a step, todo when unseen
    pub fn markGetz(self: *const Stat, iden: []const u8) Mark {
        for (self.data.step) |item| if (std.mem.eql(u8, item.iden, iden)) return item.mark;
        return .todo;
    }

    // note of a step, empty when unseen
    pub fn noteGetz(self: *const Stat, iden: []const u8) []const u8 {
        for (self.data.step) |item| if (std.mem.eql(u8, item.iden, iden)) return item.note;
        return "";
    }

    // set a step status in memory
    pub fn markSetz(self: *Stat, iden: []const u8, mark: Mark, note: []const u8, time: i64) !void {
        for (self.data.step) |*item| if (std.mem.eql(u8, item.iden, iden)) {
            item.* = .{ .iden = item.iden, .mark = mark, .note = try self.gpa.dupe(u8, note), .time = time };
            return;
        };
        const next = try self.gpa.alloc(Step, self.data.step.len + 1);
        @memcpy(next[0..self.data.step.len], self.data.step);
        next[self.data.step.len] = .{ .iden = try self.gpa.dupe(u8, iden), .mark = mark, .note = try self.gpa.dupe(u8, note), .time = time };
        self.data.step = next;
    }

    // write the file: .part first, then rename over the old one
    pub fn save(self: *const Stat) !void {
        const json = try std.json.Stringify.valueAlloc(self.gpa, self.data, .{ .whitespace = .indent_2 });
        const part = try std.mem.concat(self.gpa, u8, &.{ self.path, CF.partExte });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = part, .data = json });
        try std.Io.Dir.rename(std.Io.Dir.cwd(), part, std.Io.Dir.cwd(), self.path, self.io);
    }
};

test "state round trip keeps marks and ids" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    var buff: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmpz.dir.realPath(std.testing.io, &buff);
    const path = try std.fs.path.join(gpa, &.{ buff[0..size], "state.json" });

    var stat = try Stat.load(gpa, std.testing.io, path);
    try std.testing.expectEqual(Mark.todo, stat.markGetz("proj"));
    try stat.markSetz("proj", .done, "id 7", 5);
    try stat.markSetz("sshk", .skip, "", 6);
    try stat.markSetz("proj", .done, "id 8", 7);
    stat.data.idsz.glProj = 8;
    stat.data.idsz.glUser = "ann";
    try stat.save();

    const back = try Stat.load(gpa, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 2), back.data.step.len);
    try std.testing.expectEqual(Mark.done, back.markGetz("proj"));
    try std.testing.expectEqualStrings("id 8", back.noteGetz("proj"));
    try std.testing.expectEqual(Mark.skip, back.markGetz("sshk"));
    try std.testing.expectEqual(@as(u64, 8), back.data.idsz.glProj);
    try std.testing.expectEqualStrings("ann", back.data.idsz.glUser);
}

test "state file holds no secret field" {
    inline for (@typeInfo(Idsz).@"struct".fields) |fiel| {
        const name = fiel.name;
        try std.testing.expect(std.ascii.indexOfIgnoreCase(name, "secret") == null and std.ascii.indexOfIgnoreCase(name, "pass") == null and !std.mem.eql(u8, name, "token"));
    }
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
