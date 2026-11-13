// OA sync (official tier, read only): OA info, followers + profiles, recent chats + conversations, quota.
// Resumable and idempotent: rows go in page by page; a stopped run continues, a rerun adds nothing.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const oapi = @import("pv-oapi.zig");

pub const Stats = struct { followers: u32 = 0, messages: u32 = 0, added: u32 = 0, dup: u32 = 0, calls: u32 = 0, quota_stop: bool = false };
pub const SyncErr = error{ ConsentRequired, OaNotEnabled };

fn flush(st: *store_mod.Store, cust: []const u8, rows: *std.ArrayList(shape.Row), stats: *Stats) !void {
    if (rows.items.len == 0) return;
    const s = try st.upsert(cust, rows.items);
    stats.added += s.added;
    stats.dup += s.dup;
    rows.clearRetainingCapacity();
}

const msg_keys = [_][]const u8{ "message_id", "from_id", "to_id", "type", "message", "time" };
const prof_keys = [_][]const u8{ "user_id", "display_name", "avatar" };

pub fn syncOa(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, refresh_profiles: bool) anyerror!Stats {
    const cust = try st.getCust(a, cust_id);
    if (cx.cfg.legal.consent_required and !cust.consent) return error.ConsentRequired;
    if (!cust.oa_enabled) return error.OaNotEnabled;
    var c = try oapi.Client.init(cx, st, a, cust_id);
    var stats = Stats{};
    var rows: std.ArrayList(shape.Row) = .empty;
    defer stats.calls = c.calls;
    const now = cx.nowMs();
    const o = cx.cfg.oa;
    run: {
        // OA info
        const info = c.call(o.paths.info, "{}") catch |e| return fail(&stats, e);
        const oa_id = shape.strOf(info, "oa_id");
        try rows.append(a, try shape.makeRow(a, cust_id, .private, "oa:info", "oa_profile", now, try shape.pick(a, info, &.{ "oa_id", "name", "description", "avatar" })));
        // message quota (path is config; an endpoint that errors for any reason other than quota/dead token is skipped, never fatal)
        if (c.call(o.paths.quota, "{}")) |qd| {
            if (qd == .object) try rows.append(a, try shape.makeRow(a, cust_id, .private, "oa:quota", "oa_quota", now, qd));
        } else |e| switch (e) {
            oapi.Err.QuotaStop => {
                try flush(st, cust_id, &rows, &stats);
                stats.quota_stop = true;
                break :run;
            },
            oapi.Err.TokenDead, oapi.Err.NoToken => return e,
            else => {},
        }
        try flush(st, cust_id, &rows, &stats);
        // followers (first max_followers) + profiles
        var known = try st.knownKeys(a, cust_id, "oa_follower");
        var offset: u32 = 0;
        var total: u32 = std.math.maxInt(u32);
        while (offset < total and offset < o.max_followers) {
            const q = try std.fmt.allocPrint(a, "{{\"offset\":{d},\"count\":{d}}}", .{ offset, o.page_users });
            const d = c.call(o.paths.followers, q) catch |e| {
                if (e == oapi.Err.QuotaStop) {
                    stats.quota_stop = true;
                    break :run;
                }
                return fail(&stats, e);
            };
            if (d != .object) break;
            if (d.object.get("total")) |t| if (t == .integer and t.integer >= 0) {
                total = std.math.cast(u32, t.integer) orelse std.math.maxInt(u32);
            };
            const list = d.object.get("followers") orelse break;
            if (list != .array or list.array.items.len == 0) break;
            for (list.array.items) |f| {
                const uid = shape.strOf(f, "user_id");
                if (uid.len == 0) continue;
                const key = try std.fmt.allocPrint(a, "oa:follower:{s}", .{uid});
                stats.followers += 1;
                if (!refresh_profiles and known.contains(key)) continue;
                const pq = try std.fmt.allocPrint(a, "{{\"user_id\":\"{s}\"}}", .{uid});
                const pd = c.call(o.paths.profile, pq) catch |e| {
                    if (e == oapi.Err.QuotaStop) {
                        try flush(st, cust_id, &rows, &stats);
                        stats.quota_stop = true;
                        break :run;
                    }
                    return fail(&stats, e);
                };
                try rows.append(a, try shape.makeRow(a, cust_id, .private, key, "oa_follower", now, try shape.pick(a, pd, &prof_keys)));
                try known.put(a, key, {});
            }
            try flush(st, cust_id, &rows, &stats);
            offset += @intCast(list.array.items.len);
        }
        // recent chats -> partners -> conversations
        var partners: std.StringArrayHashMapUnmanaged(void) = .empty;
        var moff: u32 = 0;
        while (stats.messages < o.max_messages) {
            const q = try std.fmt.allocPrint(a, "{{\"offset\":{d},\"count\":{d}}}", .{ moff, o.page_msgs });
            const d = c.call(o.paths.recent, q) catch |e| {
                if (e == oapi.Err.QuotaStop) {
                    stats.quota_stop = true;
                    break :run;
                }
                return fail(&stats, e);
            };
            if (d != .array or d.array.items.len == 0) break;
            for (d.array.items) |m| {
                const mid = shape.strOf(m, "message_id");
                if (mid.len == 0) continue;
                try rows.append(a, try shape.makeRow(a, cust_id, .private, try std.fmt.allocPrint(a, "oa:msg:{s}", .{mid}), "oa_message", now, try shape.pick(a, m, &msg_keys)));
                stats.messages += 1;
                const from = shape.strOf(m, "from_id");
                const partner = if (std.mem.eql(u8, from, oa_id)) shape.strOf(m, "to_id") else from;
                if (partner.len > 0) try partners.put(a, partner, {});
            }
            try flush(st, cust_id, &rows, &stats);
            moff += @intCast(d.array.items.len);
        }
        for (partners.keys()) |pid| {
            var coff: u32 = 0;
            while (stats.messages < o.max_messages) {
                const q = try std.fmt.allocPrint(a, "{{\"user_id\":\"{s}\",\"offset\":{d},\"count\":{d}}}", .{ pid, coff, o.page_msgs });
                const d = c.call(o.paths.conversation, q) catch |e| {
                    if (e == oapi.Err.QuotaStop) {
                        stats.quota_stop = true;
                        break :run;
                    }
                    return fail(&stats, e);
                };
                if (d != .array or d.array.items.len == 0) break;
                for (d.array.items) |m| {
                    const mid = shape.strOf(m, "message_id");
                    if (mid.len == 0) continue;
                    try rows.append(a, try shape.makeRow(a, cust_id, .private, try std.fmt.allocPrint(a, "oa:msg:{s}", .{mid}), "oa_message", now, try shape.pick(a, m, &msg_keys)));
                    stats.messages += 1;
                }
                try flush(st, cust_id, &rows, &stats);
                coff += @intCast(d.array.items.len);
            }
        }
    }
    try flush(st, cust_id, &rows, &stats);
    return stats;
}

fn fail(stats: *Stats, e: oapi.Err) anyerror {
    _ = stats;
    return e;
}

// ---- tests ----
const mo = @import("te-mock-oapi.zig");

fn connect(rig: *oapi.Rig) !void {
    var c = try oapi.Client.init(&rig.cx, &rig.st, rig.arena.allocator(), "alpha");
    _ = try c.authorizeUrl();
    try c.exchangeCode("GOODCODE");
}

test "osync: full sync pages 50/10, resync adds 0 and skips known profiles" {
    var rig = oapi.Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    try connect(&rig);
    rig.mock.followers = 120;
    rig.mock.msgs_per_chat = 25;
    const s1 = try syncOa(&rig.cx, &rig.st, a, "alpha", false);
    try std.testing.expectEqual(@as(u32, 120), s1.followers);
    try std.testing.expectEqual(@as(u32, 120), rig.mock.profile_calls);
    // 25 recent (3 pages) + conversation of u1 (25 again, same ids -> dup)
    try std.testing.expect(s1.added == 1 + 1 + 120 + 25);
    const rows1 = try rig.st.countRows("alpha");
    try std.testing.expectEqual(@as(usize, 147), rows1);
    // resync: nothing new, profiles not refetched
    const calls_before = rig.mock.profile_calls;
    const s2 = try syncOa(&rig.cx, &rig.st, a, "alpha", false);
    try std.testing.expectEqual(@as(u32, 0), s2.added);
    try std.testing.expectEqual(calls_before, rig.mock.profile_calls);
    try std.testing.expectEqual(rows1, try rig.st.countRows("alpha"));
    // token expiry mid-way is invisible
    rig.mock.expireNow();
    const s3 = try syncOa(&rig.cx, &rig.st, a, "alpha", false);
    try std.testing.expectEqual(@as(u32, 0), s3.added);
    try std.testing.expect(rig.mock.refreshes >= 1);
}

test "osync: max_followers caps; consent and enable flags gate; quota stops softly; dead token surfaces" {
    var rig = oapi.Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    try connect(&rig);
    rig.mock.followers = 120;
    rig.cx.cfg.oa.max_followers = 60;
    const s = try syncOa(&rig.cx, &rig.st, a, "alpha", false);
    try std.testing.expect(s.followers >= 60 and s.followers <= 100); // page granularity (50)
    // consent gate
    try rig.st.putCust(a, .{ .cust_id = "alpha", .consent = false, .oa_enabled = true });
    try std.testing.expectError(SyncErr.ConsentRequired, syncOa(&rig.cx, &rig.st, a, "alpha", false));
    try rig.st.putCust(a, .{ .cust_id = "alpha", .consent = true, .oa_enabled = false });
    try std.testing.expectError(SyncErr.OaNotEnabled, syncOa(&rig.cx, &rig.st, a, "alpha", false));
    try rig.st.putCust(a, .{ .cust_id = "alpha", .consent = true, .oa_enabled = true });
    rig.mock.quota_stop = true;
    const sq = try syncOa(&rig.cx, &rig.st, a, "alpha", false);
    try std.testing.expect(sq.quota_stop);
    rig.mock.quota_stop = false;
    rig.mock.expireNow();
    rig.mock.refresh_dead = true;
    try std.testing.expectError(oapi.Err.TokenDead, syncOa(&rig.cx, &rig.st, a, "alpha", false));
}

test "osync: rows hold only whitelisted fields" {
    var rig = oapi.Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    try connect(&rig);
    rig.mock.followers = 2;
    _ = try syncOa(&rig.cx, &rig.st, a, "alpha", false);
    const pg = try rig.st.rowsSince(a, "alpha", 0, 100);
    var saw_follower = false;
    for (pg.rows) |r| {
        try std.testing.expectEqual(shape.Source.private, r.source);
        if (std.mem.eql(u8, r.kind, "oa_follower")) {
            saw_follower = true;
            try std.testing.expect(r.data.object.get("display_name") != null);
        }
    }
    try std.testing.expect(saw_follower);
}
