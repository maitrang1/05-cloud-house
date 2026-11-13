// Personal QR login. The sidecar prints the session once on stdout; we seal it into the vault at once (never a plain file, never argv).
// QR scan is a human step: use a throwaway/secondary Zalo account only.
const std = @import("std");
const Io = std.Io;
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const store_mod = @import("rw-store.zig");
const vault_mod = @import("pv-vault.zig");
const sidec = @import("pv-sidec.zig");

pub fn qrLogin(cx: *ctx_mod.Ctx, st: *store_mod.Store, a: std.mem.Allocator, cust_id: []const u8, fixture: ?[]const u8) anyerror!void {
    if (!cx.cfg.side.enabled) return error.PersonalTierOff;
    if (!sidec.nodeAvailable(cx, a)) return error.NoNode;
    const vault = try vault_mod.Vault.open(cx);
    try st.ensure(cust_id);
    const s = cx.cfg.side;
    const script = try std.fmt.allocPrint(a, "{s}/side.mjs", .{try cx.rel(a, s.dir)});
    const qr = try st.path(a, cust_id, "login-qr.png");
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ s.node, script, "login", "--qr", qr });
    if (cx.mock) if (fixture) |f| try argv.appendSlice(a, &.{ "--fixture", f });
    var child = try std.process.spawn(cx.io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
    defer child.kill(cx.io);
    const buf = try a.alloc(u8, 1 << 16);
    var rd = child.stdout.?.readerStreaming(cx.io, buf);
    const r = &rd.interface;
    var got = false;
    while (true) {
        var aw: Io.Writer.Allocating = .init(a);
        const n = r.streamDelimiterLimit(&aw.writer, '\n', .limited(1 << 20)) catch break;
        const eof = if (r.takeByte()) |_| false else |_| true;
        if (n > 0) {
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{ .allocate = .alloc_always }) catch continue;
            if (v == .object) {
                if (v.object.get("event")) |ev| if (ev == .string) {
                    if (std.mem.eql(u8, ev.string, "qr_saved")) util.print(cx.io, "Scan this QR with the SECONDARY Zalo account: {s}\n", .{qr});
                    if (std.mem.eql(u8, ev.string, "scanned")) util.print(cx.io, "Scanned - confirm on the phone.\n", .{});
                    if (std.mem.eql(u8, ev.string, "declined")) return error.LoginDeclined;
                    if (std.mem.eql(u8, ev.string, "session")) {
                        const sess = v.object.get("session") orelse continue;
                        try vault.putMany(cust_id, &.{ .{ "side_session", try util.jsonStr(a, sess) }, .{ "side_status", "ok" } });
                        got = true;
                    }
                };
            }
        }
        if (eof) break;
    }
    // the QR image is a login credential in disguise: blank it
    if (util.exists(cx.io, qr)) Io.Dir.cwd().deleteFile(cx.io, qr) catch {};
    if (!got) return error.LoginFailed;
    var c = try st.getCust(a, cust_id);
    c.personal_enabled = true;
    try st.putCust(a, c);
    st.audit(cust_id, cx.nowMs(), "login", "personal", 0, "session_sealed");
}

test "plogin: fixture login seals the session; nothing readable on disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SCRAPE_MASTER_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var hb: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&hb, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var cx = ctx_mod.testCtx(a, &env, home);
    cx.mock = true;
    cx.cfg.side.enabled = true;
    cx.cfg.side.dir = "side";
    if (!sidec.nodeAvailable(&cx, a)) return error.SkipZigTest;
    var st = store_mod.Store.init(cx.io, std.testing.allocator, home);
    try st.putCust(a, .{ .cust_id = "alpha", .consent = true });
    try qrLogin(&cx, &st, a, "alpha", "te-side.json");
    const v = try vault_mod.Vault.open(&cx);
    const sess = (try v.get(a, "alpha", "side_session")).?;
    try std.testing.expect(std.mem.indexOf(u8, sess, "FIXTURE-COOKIE") != null);
    const raw = try util.readAll(a, cx.io, try st.path(a, "alpha", "secrets.enc"), 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, raw, "FIXTURE") == null);
    try std.testing.expect((try st.getCust(a, "alpha")).personal_enabled);
    cx.cfg.side.enabled = false;
    try std.testing.expectError(error.PersonalTierOff, qrLogin(&cx, &st, a, "alpha", "te-side.json"));
}
