// Personal-account sync (tier E): gated, optional, read only. Friends (no phone numbers), groups the cust is IN, group history.
// Needs: side.enabled · cust.personal_enabled · consent · risk not cut · the lease · under the daily call cap.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const sidec = @import("pv-sidec.zig");
const lease = @import("pv-lease.zig");
const risk = @import("pv-risk.zig");
const vault_mod = @import("pv-vault.zig");

pub const Stats = struct { friends: u32 = 0, groups: u32 = 0, messages: u32 = 0, added: u32 = 0, calls: u32 = 0 };
pub const Err = error{ PersonalTierOff, TierCut, NoSession, LeaseHeld, DailyCap, DeadSession, RateLimited, SidecarDown, ConsentRequired, NoNode };

fn today(st: *const store_mod.Store, a: std.mem.Allocator, cust: []const u8, now: i64) u32 {
    const t = util.readAll(a, st.io, st.path(a, cust, "side-calls.log") catch return 0, 16 * 1024 * 1024) catch return 0;
    const day = @divFloor(now, store_mod.day_ms);
    var n: u32 = 0;
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |ln| {
        var f = std.mem.tokenizeScalar(u8, ln, ' ');
        const ts = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
        const c = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        if (@divFloor(ts, store_mod.day_ms) == day) n +|= c;
    }
    return n;
}

const Ctl = struct {
    cx: *ctx_mod.Ctx,
    st: *store_mod.Store,
    a: std.mem.Allocator,
    cust: []const u8,
    side: *sidec.Side,
    holder: []const u8,
    cap_left: u32,

    // one allowed read; maps every failure to a typed error and feeds the risk state
    fn read(self: *Ctl, method: []const u8, args: []const u8) !std.json.Value {
        if (self.cap_left == 0) return Err.DailyCap;
        self.cap_left -= 1;
        _ = try lease.acquire(self.st, self.a, self.cust, self.holder, self.cx.cfg.side.lease_ttl_s, self.cx.nowMs()); // renew
        const r = try self.side.call(self.a, method, args);
        switch (r.code) {
            .ok => return r.data,
            .dead_session => {
                risk.record(self.cx, self.st, self.a, self.cust, .dead);
                const v = vault_mod.Vault.open(self.cx) catch return Err.DeadSession;
                v.put(self.cust, "side_status", "dead") catch {};
                return Err.DeadSession;
            },
            .rate_limited => {
                risk.record(self.cx, self.st, self.a, self.cust, .rate);
                return Err.RateLimited;
            },
            .refused => return error.Refused,
            else => {
                risk.record(self.cx, self.st, self.a, self.cust, .down);
                return Err.SidecarDown;
            },
        }
    }
};

fn firstObjectValue(v: std.json.Value, map_key: []const u8) std.json.Value {
    if (v != .object) return .null;
    const m = v.object.get(map_key) orelse return v;
    if (m != .object) return .null;
    var it = m.object.iterator();
    if (it.next()) |e| return e.value_ptr.*;
    return .null;
}

pub fn syncPersonal(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, fixture: ?[]const u8) anyerror!Stats {
    if (!cx.cfg.side.enabled) return Err.PersonalTierOff;
    const cust = try st.getCust(a, cust_id);
    if (!cust.personal_enabled) return Err.PersonalTierOff;
    if (cx.cfg.legal.consent_required and !cust.consent) return Err.ConsentRequired;
    if (risk.verdict(cx, risk.load(st, a, cust_id)) == .cut) return Err.TierCut;
    const vault = try vault_mod.Vault.open(cx);
    const ss = vault.get(a, cust_id, "side_status") catch null;
    if (ss != null and std.mem.eql(u8, ss.?, "dead")) return Err.DeadSession;
    const session = (try vault.get(a, cust_id, "side_session")) orelse return Err.NoSession;
    const holder = try lease.hostId(cx, a);
    if (!try lease.acquire(st, a, cust_id, holder, cx.cfg.side.lease_ttl_s, cx.nowMs())) return Err.LeaseHeld;
    defer lease.release(st, a, cust_id, holder);
    const used = today(st, a, cust_id, cx.nowMs());
    if (used >= cx.cfg.side.daily_cap) return Err.DailyCap;
    if (!sidec.nodeAvailable(cx, a)) return Err.NoNode;
    const side = sidec.Side.start(cx, a, session, fixture) catch return Err.SidecarDown;
    defer side.stop();
    var ctl = Ctl{ .cx = cx, .st = st, .a = a, .cust = cust_id, .side = side, .holder = holder, .cap_left = cx.cfg.side.daily_cap - used };
    var stats = Stats{};
    const now = cx.nowMs();
    var rows: std.ArrayList(shape.Row) = .empty;
    defer {
        var b: [48]u8 = undefined;
        if (std.fmt.bufPrint(&b, "{d} {d}", .{ now, side.calls })) |ln| st.appendLog(cust_id, "side-calls.log", ln) catch {} else |_| {}
    }
    const acc = try ctl.read("fetchAccountInfo", "[]");
    try rows.append(a, try shape.makeRow(a, cust_id, .private, "zl:account", "zl_account", now, try shape.pick(a, acc, &.{ "uid", "userId", "displayName", "zaloName", "avatar" })));
    const fr = try ctl.read("getAllFriends", "[]");
    if (fr == .array) for (fr.array.items) |f| {
        const uid = shape.strOf(f, "userId");
        if (uid.len == 0) continue;
        stats.friends += 1;
        try rows.append(a, try shape.makeRow(a, cust_id, .private, try std.fmt.allocPrint(a, "zl:friend:{s}", .{uid}), "zl_friend", now, try shape.pick(a, f, &.{ "userId", "displayName", "zaloName", "avatar" })));
    };
    var s0 = try st.upsert(cust_id, rows.items);
    stats.added += s0.added;
    rows.clearRetainingCapacity();
    // groups the cust is a member of
    const gr = try ctl.read("getAllGroups", "[]");
    var gids: std.ArrayList([]const u8) = .empty;
    const gmap = if (gr == .object) (gr.object.get("gridVerMap") orelse gr) else gr;
    if (gmap == .object) {
        var it = gmap.object.iterator();
        while (it.next()) |e| try gids.append(a, e.key_ptr.*);
    } else if (gmap == .array) for (gmap.array.items) |x| if (x == .string) try gids.append(a, x.string);
    for (gids.items, 0..) |gid, gi| {
        if (gi >= cx.cfg.side.max_groups) break;
        if (!ctx_mod.validId(std.ascii.lowerString(try a.dupe(u8, gid), gid)) and gid.len > 64) continue;
        const info = try ctl.read("getGroupInfo", try std.fmt.allocPrint(a, "[\"{s}\"]", .{gid}));
        const g = firstObjectValue(info, "gridInfoMap");
        try rows.append(a, try shape.makeRow(a, cust_id, .private, try std.fmt.allocPrint(a, "zl:group:{s}", .{gid}), "zl_group", now, try shape.pick(a, g, &.{ "groupId", "name", "totalMember", "desc" })));
        stats.groups += 1;
        const h = try ctl.read("getGroupChatHistory", try std.fmt.allocPrint(a, "[\"{s}\",{d}]", .{ gid, cx.cfg.side.history_count }));
        const msgs = if (h == .object) (h.object.get("groupMsgs") orelse .null) else h;
        if (msgs == .array) for (msgs.array.items) |m| {
            const mid = shape.strOf(m, "msgId");
            if (mid.len == 0) continue;
            const content = shape.strOf(m, "content");
            var o: std.ArrayList(u8) = .empty;
            try o.print(a, "{{\"groupId\":{s},\"msgId\":{s},\"uidFrom\":{s},\"content\":{s},\"ts\":{s}}}", .{ try util.jsonStr(a, gid), try util.jsonStr(a, mid), try util.jsonStr(a, shape.strOf(m, "uidFrom")), try util.jsonStr(a, if (content.len > 0) content else "[non-text]"), try tsOf(a, m) });
            const dv = try std.json.parseFromSliceLeaky(std.json.Value, a, o.items, .{ .allocate = .alloc_always });
            try rows.append(a, try shape.makeRow(a, cust_id, .private, try std.fmt.allocPrint(a, "zl:gmsg:{s}:{s}", .{ gid, mid }), "zl_message", now, dv));
            stats.messages += 1;
        };
        s0 = try st.upsert(cust_id, rows.items);
        stats.added += s0.added;
        rows.clearRetainingCapacity();
    }
    risk.record(cx, st, a, cust_id, .ok);
    stats.calls = side.calls;
    return stats;
}

fn tsOf(a: std.mem.Allocator, m: std.json.Value) ![]const u8 {
    if (m == .object) if (m.object.get("ts")) |t| switch (t) {
        .integer => |i| return std.fmt.allocPrint(a, "{d}", .{i}),
        .string => |s| return std.fmt.allocPrint(a, "{d}", .{std.fmt.parseInt(i64, s, 10) catch 0}),
        else => {},
    };
    return "0";
}

// ---- tests (fixture sidecar; skipped without node) ----
const Rig = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    hb: [128]u8 = undefined,
    cx: ctx_mod.Ctx = undefined,
    st: store_mod.Store = undefined,

    fn setup(self: *Rig) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.env = std.process.Environ.Map.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        const home = try std.fmt.bufPrint(&self.hb, ".zig-cache/tmp/{s}", .{&self.tmp.sub_path});
        const a = self.arena.allocator();
        try self.env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
        self.cx = ctx_mod.testCtx(a, &self.env, home);
        self.cx.mock = true;
        self.cx.cfg.side.enabled = true;
        self.cx.cfg.side.gap_ms = 0;
        self.cx.cfg.side.dir = "side";
        self.cx.cfg.side.whitelist = &.{ "fetchAccountInfo", "getAllFriends", "getAllGroups", "getGroupInfo", "getGroupChatHistory" };
        self.st = store_mod.Store.init(self.cx.io, std.testing.allocator, home);
        try self.st.putCust(a, .{ .cust_id = "alpha", .consent = true, .personal_enabled = true });
        const v = try vault_mod.Vault.open(&self.cx);
        try v.put("alpha", "side_session", "{\"imei\":\"x\",\"userAgent\":\"x\",\"cookie\":\"FIXTURE\"}");
    }
    fn teardown(self: *Rig) void {
        self.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

test "psync: fixture sync adds friends/groups/messages, no phone numbers, rerun adds 0" {
    var rig = Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    if (!sidec.nodeAvailable(&rig.cx, a)) return error.SkipZigTest;
    const s = try syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json");
    try std.testing.expectEqual(@as(u32, 2), s.friends);
    try std.testing.expectEqual(@as(u32, 2), s.groups);
    try std.testing.expectEqual(@as(u32, 3), s.messages);
    const rows = try rig.st.countRows("alpha");
    try std.testing.expectEqual(@as(usize, 1 + 2 + 2 + 3), rows);
    const raw = try util.readAll(a, rig.cx.io, try rig.st.path(a, "alpha", "rows.jsonl"), 1 << 20);
    try std.testing.expect(std.mem.indexOf(u8, raw, "0900000001") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "FIXTURE") == null);
    const s2 = try syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json");
    try std.testing.expectEqual(@as(u32, 0), s2.added);
    try std.testing.expectEqual(rows, try rig.st.countRows("alpha"));
}

test "psync: gates - tier off, no consent, lease held by another host, daily cap, risk cut" {
    var rig = Rig{ .arena = undefined, .env = undefined, .tmp = undefined };
    try rig.setup();
    defer rig.teardown();
    const a = rig.arena.allocator();
    if (!sidec.nodeAvailable(&rig.cx, a)) return error.SkipZigTest;
    rig.cx.cfg.side.enabled = false;
    try std.testing.expectError(Err.PersonalTierOff, syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json"));
    rig.cx.cfg.side.enabled = true;
    try rig.st.putCust(a, .{ .cust_id = "alpha", .consent = false, .personal_enabled = true });
    try std.testing.expectError(Err.ConsentRequired, syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json"));
    try rig.st.putCust(a, .{ .cust_id = "alpha", .consent = true, .personal_enabled = true });
    // another host holds the lease
    try std.testing.expect(try lease.acquire(&rig.st, a, "alpha", "other-host", 600, rig.cx.nowMs()));
    try std.testing.expectError(Err.LeaseHeld, syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json"));
    lease.release(&rig.st, a, "alpha", "other-host");
    // daily cap
    rig.cx.cfg.side.daily_cap = 3;
    const r = syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json");
    try std.testing.expectError(Err.DailyCap, r);
    try std.testing.expectError(Err.DailyCap, syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json")); // cap persists today
    rig.cx.cfg.side.daily_cap = 300;
    // risk cut
    risk.record(&rig.cx, &rig.st, a, "alpha", .dead);
    try std.testing.expectError(Err.TierCut, syncPersonal(&rig.cx, &rig.st, a, "alpha", "te-side.json"));
}
