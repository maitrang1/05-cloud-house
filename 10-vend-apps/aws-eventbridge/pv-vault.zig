// =====================================================================
// Des: The local vault. Keeps tokens and keys in one encrypted file on this machine, locked with a passphrase. Nothing in it ever reaches git, logs or the screen.
// Flo: passphrase > Argon2id key > AES-256-GCM open > get or put a value > seal with a fresh nonce > write-then-rename
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: vault path, passphrase, Argon2 settings from config
// Out: values by key in memory, sealed JSON file on disk
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const Aead = std.crypto.aead.aes_gcm.Aes256Gcm;
const argo = std.crypto.pwhash.argon2;

const CF = .{ .fileMaxz = 4 << 20, .partExte = ".part", .versNowz = 1, .saltSize = 16, .addiData = "cloud-house-vault-v1", .passMinz = 8 };

// Argon2id cost settings (from config)
pub const Cost = struct { time: u32, memo: u32, para: u24 };

// the sealed file contract, v1 (hex text fields)
const Seal = struct { vers: u32, time: u32, memo: u32, para: u24, salt: []const u8, nonc: []const u8, tagz: []const u8, data: []const u8 };

// one secret inside the vault
const Pair = struct { keyz: []const u8, valu: []const u8 };

pub const Erro = error{ VaulPass, VaulForm, VaulWeak };

pub const Vaul = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    pass: []const u8,
    cost: Cost,
    list: std.ArrayList(Pair) = .empty,
    fresh: bool = true,

    // open the vault, or start an empty one when the file is missing (arena allocator expected)
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, pass: []const u8, cost: Cost) !Vaul {
        if (pass.len < CF.passMinz) return error.VaulWeak;
        var self = Vaul{ .gpa = gpa, .io = io, .path = path, .pass = pass, .cost = cost };
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(CF.fileMaxz)) catch |erro| switch (erro) {
            error.FileNotFound => return self,
            else => return erro,
        };
        self.fresh = false;
        const seal = std.json.parseFromSliceLeaky(Seal, gpa, text, .{ .allocate = .alloc_always }) catch return error.VaulForm;
        if (seal.vers != CF.versNowz or seal.salt.len != CF.saltSize * 2 or seal.nonc.len != Aead.nonce_length * 2 or seal.tagz.len != Aead.tag_length * 2 or seal.data.len % 2 != 0) return error.VaulForm;
        var salt: [CF.saltSize]u8 = undefined;
        var nonc: [Aead.nonce_length]u8 = undefined;
        var tagz: [Aead.tag_length]u8 = undefined;
        const ciph = try gpa.alloc(u8, seal.data.len / 2);
        _ = std.fmt.hexToBytes(&salt, seal.salt) catch return error.VaulForm;
        _ = std.fmt.hexToBytes(&nonc, seal.nonc) catch return error.VaulForm;
        _ = std.fmt.hexToBytes(&tagz, seal.tagz) catch return error.VaulForm;
        _ = std.fmt.hexToBytes(ciph, seal.data) catch return error.VaulForm;
        var keyz: [Aead.key_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &keyz);
        try keyzMake(gpa, io, &keyz, pass, &salt, .{ .time = seal.time, .memo = seal.memo, .para = seal.para });
        const plai = try gpa.alloc(u8, ciph.len);
        Aead.decrypt(plai, ciph, tagz, CF.addiData, nonc, keyz) catch return error.VaulPass;
        const pair = std.json.parseFromSliceLeaky([]Pair, gpa, plai, .{ .allocate = .alloc_always }) catch return error.VaulForm;
        try self.list.appendSlice(gpa, pair);
        return self;
    }

    // value of a key, null when absent
    pub fn getz(self: *const Vaul, keyz: []const u8) ?[]const u8 {
        for (self.list.items) |item| if (std.mem.eql(u8, item.keyz, keyz)) return item.valu;
        return null;
    }

    // set a value and save
    pub fn putz(self: *Vaul, keyz: []const u8, valu: []const u8) !void {
        const copy = try self.gpa.dupe(u8, valu);
        for (self.list.items) |*item| if (std.mem.eql(u8, item.keyz, keyz)) {
            item.valu = copy;
            return self.save();
        };
        try self.list.append(self.gpa, .{ .keyz = try self.gpa.dupe(u8, keyz), .valu = copy });
        return self.save();
    }

    // drop a key and save (used by revoke)
    pub fn drop(self: *Vaul, keyz: []const u8) !void {
        for (self.list.items, 0..) |item, indx| if (std.mem.eql(u8, item.keyz, keyz)) {
            _ = self.list.orderedRemove(indx);
            return self.save();
        };
    }

    // seal everything with a fresh salt and nonce, write-then-rename
    pub fn save(self: *Vaul) !void {
        const plai = try std.json.Stringify.valueAlloc(self.gpa, self.list.items, .{});
        var salt: [CF.saltSize]u8 = undefined;
        var nonc: [Aead.nonce_length]u8 = undefined;
        var tagz: [Aead.tag_length]u8 = undefined;
        self.io.random(&salt);
        self.io.random(&nonc);
        var keyz: [Aead.key_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &keyz);
        try keyzMake(self.gpa, self.io, &keyz, self.pass, &salt, self.cost);
        const ciph = try self.gpa.alloc(u8, plai.len);
        Aead.encrypt(ciph, &tagz, plai, CF.addiData, nonc, keyz);
        const seal = Seal{ .vers = CF.versNowz, .time = self.cost.time, .memo = self.cost.memo, .para = self.cost.para, .salt = &std.fmt.bytesToHex(salt, .lower), .nonc = &std.fmt.bytesToHex(nonc, .lower), .tagz = &std.fmt.bytesToHex(tagz, .lower), .data = try hexzMake(self.gpa, ciph) };
        const json = try std.json.Stringify.valueAlloc(self.gpa, seal, .{});
        const part = try std.mem.concat(self.gpa, u8, &.{ self.path, CF.partExte });
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = part, .data = json, .flags = .{ .permissions = permOwne() } });
        try std.Io.Dir.rename(std.Io.Dir.cwd(), part, std.Io.Dir.cwd(), self.path, self.io);
        self.fresh = false;
    }
};

// owner-only file mode where the OS has one
fn permOwne() std.Io.File.Permissions {
    return if (@hasDecl(std.Io.File.Permissions, "fromMode")) std.Io.File.Permissions.fromMode(0o600) else .default_file;
}

// passphrase to key, Argon2id
fn keyzMake(gpa: std.mem.Allocator, io: std.Io, keyz: []u8, pass: []const u8, salt: []const u8, cost: Cost) !void {
    argo.kdf(gpa, keyz, pass, salt, .{ .t = cost.time, .m = cost.memo, .p = cost.para }, .argon2id, io) catch return error.VaulWeak;
}

// bytes to lowercase hex text
fn hexzMake(gpa: std.mem.Allocator, byte: []const u8) ![]u8 {
    const outp = try gpa.alloc(u8, byte.len * 2);
    for (byte, 0..) |item, indx| _ = std.fmt.bufPrint(outp[indx * 2 ..][0..2], "{x:0>2}", .{item}) catch unreachable; // 2 bytes always fit
    return outp;
}

const testCost = Cost{ .time = 1, .memo = 64, .para = 1 };

// temp vault path for tests
fn testPath(gpa: std.mem.Allocator, tmpz: *std.testing.TmpDir) ![]u8 {
    var buff: [std.fs.max_path_bytes]u8 = undefined;
    const size = try tmpz.dir.realPath(std.testing.io, &buff);
    return std.fs.path.join(gpa, &.{ buff[0..size], "vault.json" });
}

test "vault round trip, update, drop" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    const path = try testPath(gpa, &tmpz);

    var vaul = try Vaul.open(gpa, std.testing.io, path, "correct horse", testCost);
    try std.testing.expect(vaul.fresh);
    try vaul.putz("gitl.mirr", "glpat-FAKE-1");
    try vaul.putz("gith.token", "gho_FAKE");
    try vaul.putz("gitl.mirr", "glpat-FAKE-2");

    var back = try Vaul.open(gpa, std.testing.io, path, "correct horse", testCost);
    try std.testing.expect(!back.fresh);
    try std.testing.expectEqualStrings("glpat-FAKE-2", back.getz("gitl.mirr").?);
    try std.testing.expectEqualStrings("gho_FAKE", back.getz("gith.token").?);
    try back.drop("gith.token");
    const last = try Vaul.open(gpa, std.testing.io, path, "correct horse", testCost);
    try std.testing.expect(last.getz("gith.token") == null);
    try std.testing.expectEqual(@as(usize, 1), last.list.items.len);
}

test "vault refuses a wrong passphrase, a tampered file, a weak passphrase" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var tmpz = std.testing.tmpDir(.{});
    defer tmpz.cleanup();
    const path = try testPath(gpa, &tmpz);

    var vaul = try Vaul.open(gpa, std.testing.io, path, "correct horse", testCost);
    try vaul.putz("gitl.mirr", "glpat-FAKE-1");
    try std.testing.expectError(error.VaulPass, Vaul.open(gpa, std.testing.io, path, "wrong horse!", testCost));
    try std.testing.expectError(error.VaulWeak, Vaul.open(gpa, std.testing.io, path, "short", testCost));

    // the secret must not sit in the file as plain text
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(CF.fileMaxz));
    try std.testing.expect(std.mem.indexOf(u8, text, "glpat") == null and std.mem.indexOf(u8, text, "gitl.mirr") == null);

    // flip one hex digit of the data field
    const spot = std.mem.indexOf(u8, text, "\"data\":\"").? + 8;
    text[spot] = if (text[spot] == '0') '1' else '0';
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = text });
    try std.testing.expectError(error.VaulPass, Vaul.open(gpa, std.testing.io, path, "correct horse", testCost));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
