// Dump (export): a cust's rows, files and logs + a manifest with sha256 per file. secrets.enc is never exported.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");

// ---- dump ----
pub const DumpStats = struct { rows: usize, files: usize, dir: []const u8 };

const Entry = struct { name: []const u8, bytes: u64, sha256: []const u8 };
const Manifest = struct { cust_id: []const u8, ts: i64, rows: usize, files: []const Entry, note: []const u8 };

fn copyInto(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, src: []const u8, dst_dir: []const u8, name: []const u8, list: *std.ArrayList(Entry)) !void {
    const data = util.readAll(a, cx.io, src, 512 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    const dst = try std.fmt.allocPrint(a, "{s}/{s}", .{ dst_dir, name });
    if (std.mem.lastIndexOfScalar(u8, dst, '/')) |i| try util.mkdirp(cx.io, dst[0..i]);
    try util.writeAtomic(a, cx.io, dst, data);
    try list.append(a, .{ .name = name, .bytes = data.len, .sha256 = try a.dupe(u8, &util.sha256Hex(data)) });
}

pub fn dump(cx: *const ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, out_dir: []const u8) !DumpStats {
    try util.mkdirp(cx.io, out_dir);
    var list: std.ArrayList(Entry) = .empty;
    for ([_][]const u8{ "cust.json", "rows.jsonl", "usage.log", "audit.jsonl", "vendor_use.jsonl", "dlq.jsonl" }) |n| {
        try copyInto(cx, a, try st.path(a, cust_id, n), out_dir, n, &list);
    }
    var nfiles: usize = 0;
    if (Io.Dir.cwd().openDir(cx.io, try st.path(a, cust_id, "files"), .{ .iterate = true })) |dd| {
        var d = dd;
        defer d.close(cx.io);
        var it = d.iterate();
        while (try it.next(cx.io)) |e| {
            if (e.kind != .file) continue;
            const nm = try std.fmt.allocPrint(a, "files/{s}", .{e.name});
            try copyInto(cx, a, try st.path(a, cust_id, nm), out_dir, nm, &list);
            nfiles += 1;
        }
    } else |_| {}
    const rows = try st.countRows(cust_id);
    const m = Manifest{ .cust_id = cust_id, .ts = cx.nowMs(), .rows = rows, .files = list.items, .note = "secrets.enc is never exported" };
    try util.writeAtomic(a, cx.io, try std.fmt.allocPrint(a, "{s}/manifest.json", .{out_dir}), try util.jsonStr(a, m));
    return .{ .rows = rows, .files = nfiles, .dir = out_dir };
}

// recompute every hash in a dump; true when the dump is intact
pub fn verifyDump(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, dir: []const u8) !bool {
    const t = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/manifest.json", .{dir}), 16 * 1024 * 1024);
    const m = try std.json.parseFromSliceLeaky(Manifest, a, t, .{});
    for (m.files) |e| {
        const d = util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, e.name }), 512 * 1024 * 1024) catch return false;
        if (d.len != e.bytes or !std.mem.eql(u8, &util.sha256Hex(d), e.sha256)) return false;
    }
    return true;
}

