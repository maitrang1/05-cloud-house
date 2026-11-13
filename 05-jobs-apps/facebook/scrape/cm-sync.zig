// sync --cust ID [--only inbox,wall,lead,lives,stats] [--page P]: own lane. Pulls the cust's own Page(s) through Graph and stores private rows
// (expiry set, personal flag set). Needs consent. A dead token marks the Page dead and alerts (exit 3). Read-only.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const shape = @import("rw-shape.zig");
const store_mod = @import("rw-store.zig");
const graph = @import("ap-graph.zig");
const rowm = @import("ap-row.zig");
const inbox = @import("ap-inbox.zig");
const wall = @import("ap-wall.zig");
const lead = @import("ap-lead.zig");
const lives = @import("ap-lives.zig");
const stats = @import("ap-stats.zig");
const oauth = @import("pv-oauth.zig");
const vault_mod = @import("pv-vault.zig");
const meter = @import("rw-meter.zig");
const sche = @import("rw-sche.zig");
const watch = @import("rw-watch.zig");

const Puller = struct { name: []const u8, run: *const fn (*rowm.Job, *std.ArrayList(shape.Row)) anyerror!void };
const pullers = [_]Puller{
    .{ .name = "inbox", .run = inbox.run },
    .{ .name = "wall", .run = wall.run },
    .{ .name = "lead", .run = lead.run },
    .{ .name = "lives", .run = lives.run },
    .{ .name = "stats", .run = stats.run },
};

pub const Result = struct {
    pages: u32 = 0,
    added: u32 = 0,
    dup: u32 = 0,
    calls: u32 = 0,
    dead: u32 = 0,
    limited: u32 = 0,
    failed: u32 = 0,
    no_consent: bool = false,

    pub fn code(self: Result) u8 {
        if (self.no_consent) return 2;
        if (self.dead > 0 or self.limited > 0) return 3;
        if (self.failed > 0) return 1;
        return 0;
    }
};

fn wanted(only: []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    var it = std.mem.splitScalar(u8, only, ',');
    while (it.next()) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

pub fn syncCust(cx: *ctx_mod.Ctx, st: *store_mod.Store, cust_id: []const u8, only: []const u8, page_only: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cust = try st.getCust(a, cust_id);
    var res = Result{};
    if (cx.cfg.legal.consent_required and !cust.consent) {
        res.no_consent = true;
        return res;
    }
    const v = try vault_mod.Vault.open(cx);
    var g = try graph.Client.init(cx, a);
    const now = cx.nowMs();
    var rows: std.ArrayList(shape.Row) = .empty;
    for (cust.pages) |page| {
        if (page_only.len > 0 and !std.mem.eql(u8, page, page_only)) continue;
        if (oauth.isDead(&v, a, cust_id, page)) {
            res.dead += 1;
            continue;
        }
        const tok = (try oauth.pageToken(&v, a, cust_id, page)) orelse {
            res.dead += 1;
            continue;
        };
        res.pages += 1;
        var j = rowm.Job{ .cx = cx, .st = st, .g = &g, .a = a, .cust = cust_id, .page = page, .token = tok, .now = now };
        for (pullers) |p| {
            if (!wanted(only, p.name)) continue;
            p.run(&j, &rows) catch |e| switch (e) {
                error.DeadToken => {
                    oauth.markDead(&v, a, cust_id, page);
                    st.audit(cust_id, now, "sync", page, 190, "token_dead");
                    res.dead += 1;
                    break;
                },
                error.Blocked, error.RateLimited, error.UsageStop => {
                    st.audit(cust_id, now, "sync", page, 0, @errorName(e));
                    res.limited += 1;
                    break;
                },
                else => {
                    st.audit(cust_id, now, "sync", p.name, 0, @errorName(e));
                    res.failed += 1;
                },
            };
        }
        if (g.stopped) break;
    }
    res.calls = g.calls;
    if (rows.items.len > 0) {
        const s = try st.upsert(cust_id, rows.items);
        res.added = s.added;
        res.dup = s.dup;
    }
    if (g.calls > 0) try st.bumpFetches(cust_id, now, g.calls);
    if (res.code() == 0 and res.pages > 0) meter.record(st, cust_id, now, "sync", g.calls, 0) catch {};
    return res;
}

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: sync works for one cust\nfix: scrape sync --cust ID [--only inbox,wall,lead,lives,stats]\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return 2;
    }
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    switch (sche.check(cx, &st, cust)) {
        .go => {},
        .killed => {
            util.eprint(cx.io, "error: kill switch is on\nwhy: config sche.kill_switch or the KILL file\nfix: turn it off to run\n", .{});
            return 3;
        },
        .paused => {
            util.eprint(cx.io, "error: cust {s} is paused\nwhy: repeated failed runs\nfix: fix the cause, then scrape state --cust {s} --resume\n", .{ cust, cust });
            return 3;
        },
    }
    const only = args.value(av, "--only") orelse "";
    if (only.len > 0) {
        var it = std.mem.splitScalar(u8, only, ',');
        while (it.next()) |x| {
            var ok = false;
            for (pullers) |p| if (std.mem.eql(u8, p.name, x)) {
                ok = true;
            };
            if (!ok) {
                util.eprint(cx.io, "error: unknown part '{s}'\nwhy: parts are inbox, wall, lead, lives, stats\nfix: use --only inbox,wall\n", .{x});
                return 2;
            }
        }
    }
    const t0 = util.monoMs(cx.io);
    const r = syncCust(cx, &st, cust, only, args.value(av, "--page") orelse "") catch |e| {
        switch (e) {
            error.NoSecret => util.eprint(cx.io, "error: app secret missing\nwhy: env {s} is empty\nfix: export it (the proof needs it)\n", .{cx.cfg.graph.app_secret_env}),
            error.NoMasterKey, error.BadMasterKey => util.eprint(cx.io, "error: master key missing or bad\nwhy: tokens are sealed with it\nfix: export {s}=$(openssl rand -hex 32)\n", .{cx.cfg.secrets.master_env}),
            error.FileNotFound => util.eprint(cx.io, "error: no such cust\nwhy: no cust file for {s}\nfix: scrape login --cust {s}\n", .{ cust, cust }),
            else => util.eprint(cx.io, "error: sync failed ({s})\nwhy: store locked, or Graph unreachable\nfix: retry; check state\n", .{@errorName(e)}),
        }
        return 2;
    };
    if (r.no_consent) {
        util.eprint(cx.io, "error: no consent for {s}\nwhy: messages and comments are personal data\nfix: scrape consent --cust {s} --grant\n", .{ cust, cust });
        return 2;
    }
    sche.finish(cx, &st, cust, "sync", r.code());
    watch.record(cx, .{ .ts = cx.nowMs(), .cust = cust, .job = "sync", .code = r.code(), .fetched = r.calls, .added = r.added, .blocked = r.dead + r.limited, .failed = r.failed, .credits = 0, .ms = util.monoMs(cx.io) - t0 });
    if (r.dead > 0) watch.alert(cx, &st, cust, "Page token is dead: reconnect");
    watch.ping(cx, r.code() == 0);
    if (json) {
        const s = util.jsonStr(cx.gpa, r) catch return 1;
        defer cx.gpa.free(s);
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
    } else util.print(cx.io, "sync {s}: pages {d} · calls {d} · added {d} · dup {d} · dead {d} · limited {d} · failed {d}\n", .{ cust, r.pages, r.calls, r.added, r.dup, r.dead, r.limited, r.failed });
    return r.code();
}
