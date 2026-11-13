// Legal (PDPL): consent flag, retention of private rows, purge (offboard), dump (export). Secrets are never dumped.
// This is the app's own data lifecycle: purge really removes a cust's data on request (that is the feature).
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const oauth = @import("pv-oauth.zig");

pub fn setConsent(cx: *const ctx_mod.Ctx, st: *const store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, grant: bool) !void {
    var c = st.getCust(a, cust_id) catch shape.Cust{ .cust_id = cust_id };
    c.consent = grant;
    c.consent_at = if (grant) cx.nowMs() else 0;
    try st.putCust(a, c);
    st.audit(cust_id, cx.nowMs(), "legal", "consent", 0, if (grant) "granted" else "revoked");
}

pub const OldStats = struct { kept: u32 = 0, dropped: u32 = 0 };

// drop PRIVATE rows older than retention or past their own expiry (cust.retention_days, else config legal.retention_days). Public rows stay.
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
        const past_terms = r.expires > 0 and cx.nowMs() >= r.expires;
        if (r.source == .private and (r.fetch < cutoff or past_terms)) {
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

// does this row hold the Facebook user id? (configured keys anywhere in data, or a "from":{"id":...})
fn hasUser(v: std.json.Value, uid: []const u8, keys: []const []const u8) bool {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                const x = e.value_ptr.*;
                if (x == .string) {
                    for (keys) |uk| if (std.mem.eql(u8, k, uk) and std.mem.eql(u8, x.string, uid)) return true;
                } else if (x == .object and std.mem.eql(u8, k, "from")) {
                    if (x.object.get("id")) |i| if (i == .string and std.mem.eql(u8, i.string, uid)) return true;
                    if (hasUser(x, uid, keys)) return true;
                } else if (hasUser(x, uid, keys)) return true;
            }
        },
        .array => |arr| for (arr.items) |x| if (hasUser(x, uid, keys)) return true,
        else => {},
    }
    return false;
}

// data-deletion callback: remove every row about one Facebook user, in every cust. Returns rows removed.
pub fn purgeUser(cx: *const ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, uid: []const u8) !u32 {
    const dir_path = try std.fmt.allocPrint(a, "{s}/cust", .{cx.home});
    var dir = Io.Dir.cwd().openDir(cx.io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(cx.io);
    var ids: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(cx.io)) |e| if (e.kind == .directory and ctx_mod.validId(e.name)) try ids.append(a, try a.dupe(u8, e.name));
    var removed: u32 = 0;
    for (ids.items) |cid| {
        const lk = st.lock(cid) catch continue;
        defer lk.release();
        const p = try st.path(a, cid, "rows.jsonl");
        const txt = util.readAll(a, cx.io, p, 512 * 1024 * 1024) catch continue;
        var out: std.ArrayList(u8) = .empty;
        var n: u32 = 0;
        var lines = std.mem.splitScalar(u8, txt, '\n');
        while (lines.next()) |ln| {
            if (ln.len == 0) continue;
            if (shape.parseRow(a, ln)) |r| {
                if (hasUser(r.data, uid, cx.cfg.hook.user_keys)) {
                    n += 1;
                    continue;
                }
            } else |_| {}
            try out.appendSlice(a, ln);
            try out.append(a, '\n');
        }
        if (n > 0) {
            try util.writeAtomic(a, cx.io, p, out.items);
            removed += n;
            const cp = try st.path(a, cid, "deliv.cursor");
            if (util.exists(cx.io, cp)) try util.writeAtomic(a, cx.io, cp, "0\n"); // line indexes moved: redeliver from the top (dedup keeps it safe)
            st.audit(cid, cx.nowMs(), "legal", "deletion", 0, "rows of one user removed");
        }
    }
    return removed;
}

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
    oauth.release(cx, a, cust_id);
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

// ---- tests ----
const quota_mod = @import("ve-quota.zig");
const watch = @import("rw-watch.zig");

fn seed(a: std.mem.Allocator, st: *store_mod.Store, cust: []const u8, now: i64) !void {
    try st.putCust(a, .{ .cust_id = cust, .consent = true });
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"t\":1}", .{});
    const pub_row = try shape.makeRow(a, cust, .public, "https://www.facebook.com/x", "page", now, d);
    const old_priv = try shape.makeRow(a, cust, .private, "oa:msg:old", "chat", now - 200 * store_mod.day_ms, d);
    const new_priv = try shape.makeRow(a, cust, .private, "oa:msg:new", "chat", now - 5 * store_mod.day_ms, d);
    _ = try st.upsert(cust, &.{ pub_row, old_priv, new_priv });
    try st.putFile(cust, "abc.html", "<html>raw</html>");
    try st.appendLog(cust, "audit.jsonl", "{\"x\":1}");
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
