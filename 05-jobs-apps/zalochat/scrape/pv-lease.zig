// Lease row: only ONE host may run the personal listener/reader for a cust (Zalo allows one web session). Local plug = a file;
// the cloud adapter keeps the same {holder, expires_ms} row in the Database. A dead holder's lease expires by itself.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");

const Row = struct { holder: []const u8, expires_ms: i64 };

pub fn hostId(cx: *const ctx_mod.Ctx, a: std.mem.Allocator) ![]const u8 {
    const p = try std.fmt.allocPrint(a, "{s}/host.id", .{cx.home});
    if (util.readAll(a, cx.io, p, 128)) |t| {
        const s = std.mem.trim(u8, t, " \r\n");
        if (s.len > 0) return s;
    } else |_| {}
    var r: [8]u8 = undefined;
    cx.io.random(&r);
    const id = try util.hexEncode(a, &r);
    try util.mkdirp(cx.io, cx.home);
    try util.writeAtomic(a, cx.io, p, id);
    return id;
}

fn lockLease(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8) !Io.File {
    try st.ensure(cust);
    const p = try st.path(a, cust, "lease.lock");
    return Io.Dir.cwd().createFile(st.io, p, .{ .truncate = false, .lock = .exclusive });
}

// true = this holder now owns the lease (new, renewed, or taken over from an expired one)
pub fn acquire(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, holder: []const u8, ttl_s: u32, now: i64) !bool {
    const lf = try lockLease(st, a, cust);
    defer lf.close(st.io);
    const p = try st.path(a, cust, "lease.json");
    if (util.readAll(a, st.io, p, 4096)) |t| {
        if (std.json.parseFromSliceLeaky(Row, a, t, .{})) |cur| {
            if (!std.mem.eql(u8, cur.holder, holder) and cur.expires_ms > now) return false;
        } else |_| {}
    } else |_| {}
    const row = Row{ .holder = holder, .expires_ms = now + @as(i64, ttl_s) * 1000 };
    try util.writeAtomic(a, st.io, p, try util.jsonStr(a, row));
    return true;
}

pub fn release(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, holder: []const u8) void {
    const lf = lockLease(st, a, cust) catch return;
    defer lf.close(st.io);
    const p = st.path(a, cust, "lease.json") catch return;
    const t = util.readAll(a, st.io, p, 4096) catch return;
    const cur = std.json.parseFromSliceLeaky(Row, a, t, .{}) catch return;
    if (!std.mem.eql(u8, cur.holder, holder)) return; // never release someone else's lease
    util.writeAtomic(a, st.io, p, util.jsonStr(a, Row{ .holder = "", .expires_ms = 0 }) catch return) catch {};
}

test "lease: one holder at a time; expiry hands over; release only by owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = store_mod.Store.init(std.testing.io, std.testing.allocator, home);
    try std.testing.expect(try acquire(&st, a, "alpha", "hostA", 120, 1000));
    try std.testing.expect(!(try acquire(&st, a, "alpha", "hostB", 120, 2000))); // 2nd host refused
    try std.testing.expect(try acquire(&st, a, "alpha", "hostA", 120, 3000)); // renew
    release(&st, a, "alpha", "hostB"); // not the owner: no effect
    try std.testing.expect(!(try acquire(&st, a, "alpha", "hostB", 120, 4000)));
    try std.testing.expect(try acquire(&st, a, "alpha", "hostB", 120, 3000 + 121_000)); // expired -> takeover
    release(&st, a, "alpha", "hostB");
    try std.testing.expect(try acquire(&st, a, "alpha", "hostA", 120, 3000 + 122_000));
    // other cust unaffected
    try std.testing.expect(try acquire(&st, a, "beta", "hostB", 120, 1000));
}
