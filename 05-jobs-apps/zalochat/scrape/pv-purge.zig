// Purge (offboard): remove a cust's whole folder (rows, files, secrets, logs), then scrub the cust id from the ops-level files.
// The app's own data lifecycle: purge really removes a cust's data on request (the PDPL feature). Always behind --yes in the CLI.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");

pub const PurgeStats = struct { rows: usize = 0, files: usize = 0, had_secrets: bool = false };

pub fn countCust(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust_id: []const u8) !PurgeStats {
    var s = PurgeStats{};
    s.rows = try st.countRows(cust_id);
    s.had_secrets = util.exists(cx.io, try st.path(a, cust_id, "secrets.enc"));
    var d = Io.Dir.cwd().openDir(cx.io, try st.path(a, cust_id, "files"), .{ .iterate = true }) catch return s;
    defer d.close(cx.io);
    var it = d.iterate();
    while (try it.next(cx.io)) |_| s.files += 1;
    return s;
}

// remove a cust's whole folder (rows, files, secrets, logs), then scrub the cust id out of the ops-level files
pub fn purgeCust(cx: *const ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8) !PurgeStats {
    const stats = try countCust(cx, st, a, cust_id);
    const parent_path = try std.fmt.allocPrint(a, "{s}/cust", .{cx.home});
    var parent = try Io.Dir.cwd().openDir(cx.io, parent_path, .{});
    defer parent.close(cx.io);
    try parent.deleteTree(cx.io, cust_id);
    try scrubOps(cx, a, cust_id);
    const line = try std.fmt.allocPrint(a, "{d} purged rows={d} files={d} secrets={}", .{ cx.nowMs(), stats.rows, stats.files, stats.had_secrets });
    try util.mkdirp(cx.io, cx.home);
    try util.appendLine(cx.io, try std.fmt.allocPrint(a, "{s}/purges.log", .{cx.home}), line); // receipt carries no cust id
    return stats;
}

fn scrubFile(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, path: []const u8, cust_id: []const u8, mode: enum { field3, json }) !void {
    const txt = util.readAll(a, cx.io, path, 256 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, txt, '\n');
    var changed = false;
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        switch (mode) {
            .field3 => { // "<ts> <vendor> <cust> <credits>"
                var f = std.mem.splitScalar(u8, ln, ' ');
                const ts = f.next() orelse "";
                const v = f.next() orelse "";
                const c = f.next() orelse "";
                const rest = f.rest();
                if (std.mem.eql(u8, c, cust_id)) {
                    try out.print(a, "{s} {s} purged {s}\n", .{ ts, v, rest });
                    changed = true;
                    continue;
                }
            },
            .json => {
                const needle = try std.fmt.allocPrint(a, "\"cust\":\"{s}\"", .{cust_id});
                if (std.mem.indexOf(u8, ln, needle)) |i| {
                    try out.appendSlice(a, ln[0..i]);
                    try out.appendSlice(a, "\"cust\":\"purged\"");
                    try out.appendSlice(a, ln[i + needle.len ..]);
                    try out.append(a, '\n');
                    changed = true;
                    continue;
                }
            },
        }
        try out.appendSlice(a, ln);
        try out.append(a, '\n');
    }
    if (changed) try util.writeAtomic(a, cx.io, path, out.items);
}

fn scrubOps(cx: *const ctx_mod.Ctx, a: std.mem.Allocator, cust_id: []const u8) !void {
    try scrubFile(cx, a, try std.fmt.allocPrint(a, "{s}/vendors/use.log", .{cx.home}), cust_id, .field3);
    try scrubFile(cx, a, try std.fmt.allocPrint(a, "{s}/metrics.log", .{cx.home}), cust_id, .json);
}


// ---- tests ----
const quota_mod = @import("ve-quota.zig");
const watch = @import("rw-watch.zig");
const dumpm = @import("pv-dump.zig");
const dump = dumpm.dump;
const verifyDump = dumpm.verifyDump;

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

test "legal: purge removes rows+files+secrets+logs, scrubs ops files, leaves other custs; dump matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.fake_now_ms = 1_794_000_000_000;
    var st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    try seed(a, &st, "alpha", cx.fake_now_ms);
    try seed(a, &st, "beta", cx.fake_now_ms);
    const vault = try @import("pv-vault.zig").Vault.open(&cx);
    try vault.put("alpha", "oa_access", "TOPSECRET");
    try vault.put("beta", "oa_access", "BETASECRET");
    const q = quota_mod.Quota{ .io = cx.io, .gpa = std.testing.allocator, .home = home };
    try q.record("zenrows", "alpha", 3, cx.fake_now_ms);
    try q.record("zenrows", "beta", 2, cx.fake_now_ms);
    watch.record(&cx, .{ .ts = 1, .cust = "alpha", .job = "scan", .code = 0, .fetched = 1, .added = 1, .blocked = 0, .failed = 0, .credits = 0, .ms = 1 });
    // dump first: matches the store, has no secrets
    const out = try std.fmt.allocPrint(a, "{s}/dump-alpha", .{home});
    const ds = try dump(&cx, &st, a, "alpha", out);
    try std.testing.expectEqual(try st.countRows("alpha"), ds.rows);
    try std.testing.expectEqual(@as(usize, 1), ds.files);
    try std.testing.expect(try verifyDump(&cx, a, out));
    try std.testing.expect(!util.exists(cx.io, try std.fmt.allocPrint(a, "{s}/secrets.enc", .{out})));
    // tamper -> verify fails
    try util.writeAtomic(a, cx.io, try std.fmt.allocPrint(a, "{s}/rows.jsonl", .{out}), "tampered");
    try std.testing.expect(!(try verifyDump(&cx, a, out)));
    // purge alpha
    const ps = try purgeCust(&cx, &st, a, "alpha");
    try std.testing.expectEqual(@as(usize, 3), ps.rows);
    try std.testing.expect(ps.had_secrets);
    try std.testing.expect(!util.exists(cx.io, try st.path(a, "alpha", "")));
    try std.testing.expect(util.exists(cx.io, try st.path(a, "beta", "rows.jsonl")));
    try std.testing.expectEqualStrings("BETASECRET", (try vault.get(a, "beta", "oa_access")).?);
    const use = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/vendors/use.log", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, use, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, use, "beta") != null);
    const met = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/metrics.log", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, met, "alpha") == null);
    const rec = try util.readAll(a, cx.io, try std.fmt.allocPrint(a, "{s}/purges.log", .{home}), 4096);
    try std.testing.expect(std.mem.indexOf(u8, rec, "alpha") == null);
}

