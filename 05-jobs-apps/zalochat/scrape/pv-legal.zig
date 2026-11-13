// Legal (PDPL): consent flag + retention of private rows. Purge: pv-purge.zig · dump: pv-dump.zig.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");

pub fn setConsent(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, grant: bool) !void {
    var c = st.getCust(a, cust_id) catch shape.Cust{ .cust_id = cust_id };
    c.consent = grant;
    c.consent_at = if (grant) cx.nowMs() else 0;
    try st.putCust(a, c);
    st.audit(cust_id, cx.nowMs(), "legal", "consent", 0, if (grant) "granted" else "revoked");
}

pub const OldStats = struct { kept: u32 = 0, dropped: u32 = 0 };

// drop PRIVATE rows older than retention (cust.retention_days, else config legal.retention_days). Public rows stay.
pub fn purgeOld(cx: *const ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8) !OldStats {
    const c = try st.getCust(a, cust_id);
    const days = if (c.retention_days > 0) c.retention_days else cx.cfg.legal.retention_days;
    const cutoff = cx.nowMs() - @as(i64, days) * store_mod.day_ms;
    const lk = try st.lock(cust_id);
    defer lk.release();
    const p = try st.path(a, cust_id, "rows.jsonl");
    const txt = util.readAll(a, cx.io, p, 512 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    var out: std.ArrayList(u8) = .empty;
    var s = OldStats{};
    var it = std.mem.splitScalar(u8, txt, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        const r = shape.parseRow(a, ln) catch {
            try out.appendSlice(a, ln);
            try out.append(a, '\n');
            continue;
        };
        if (r.source == .private and r.fetch < cutoff) {
            s.dropped += 1;
            continue;
        }
        s.kept += 1;
        try out.appendSlice(a, ln);
        try out.append(a, '\n');
    }
    if (s.dropped > 0) {
        try util.writeAtomic(a, cx.io, p, out.items);
        // the delivery cursor counted lines: it must not point past the new end
        const cp = try st.path(a, cust_id, "deliv.cursor");
        if (util.exists(cx.io, cp)) {
            const cur = std.fmt.parseInt(usize, std.mem.trim(u8, util.readAll(a, cx.io, cp, 64) catch "0", " \n"), 10) catch 0;
            if (cur > s.kept) try util.writeAtomic(a, cx.io, cp, try std.fmt.allocPrint(a, "{d}\n", .{s.kept}));
        }
        st.audit(cust_id, cx.nowMs(), "legal", "retention", 0, "private rows past retention removed");
    }
    return s;
}


test "legal: retention drops only old PRIVATE rows and fixes the cursor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.fake_now_ms = 1_794_000_000_000;
    cx.cfg.legal.retention_days = 90;
    var st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    try seed(a, &st, "alpha", cx.fake_now_ms);
    try util.writeAtomic(a, cx.io, try st.path(a, "alpha", "deliv.cursor"), "3\n");
    const s = try purgeOld(&cx, &st, a, "alpha");
    try std.testing.expectEqual(@as(u32, 1), s.dropped);
    try std.testing.expectEqual(@as(u32, 2), s.kept);
    try std.testing.expectEqual(@as(usize, 2), try st.countRows("alpha"));
    const cur = try util.readAll(a, cx.io, try st.path(a, "alpha", "deliv.cursor"), 64);
    try std.testing.expectEqualStrings("2\n", cur);
}

test "legal: consent grant and revoke" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cx = ctx_mod.testCtx(a, &env, home);
    var st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    try setConsent(&cx, &st, a, "alpha", true);
    try std.testing.expect((try st.getCust(a, "alpha")).consent);
    try setConsent(&cx, &st, a, "alpha", false);
    try std.testing.expect(!(try st.getCust(a, "alpha")).consent);
}

fn seed(a: std.mem.Allocator, st: *store_mod.Store, cust: []const u8, now: i64) !void {
    try st.putCust(a, .{ .cust_id = cust, .consent = true });
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"t\":1}", .{});
    const pub_row = try shape.makeRow(a, cust, .public, "https://zalo.me/x", "oa_page", now, d);
    const old_priv = try shape.makeRow(a, cust, .private, "oa:msg:old", "oa_message", now - 200 * store_mod.day_ms, d);
    const new_priv = try shape.makeRow(a, cust, .private, "oa:msg:new", "oa_message", now - 5 * store_mod.day_ms, d);
    _ = try st.upsert(cust, &.{ pub_row, old_priv, new_priv });
    try st.putFile(cust, "abc.html", "<html>raw</html>");
    try st.appendLog(cust, "audit.jsonl", "{\"x\":1}");
}

