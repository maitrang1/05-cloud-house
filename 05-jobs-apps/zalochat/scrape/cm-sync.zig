// sync --cust ID --tier oa|articles|mini [--file F] [--refresh-profiles]. Read only. Exit 0 ok · 2 setup · 3 dead token / quota stop.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const osync = @import("pv-osync.zig");
const oavid = @import("pv-oavid.zig");
const mini = @import("pv-mini.zig");
const psync = @import("pv-psync.zig");
const sche = @import("rw-sche.zig");
const watch = @import("rw-watch.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    _ = json;
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: sync works per cust\nfix: scrape sync --cust ID --tier oa|articles|mini\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return 2;
    }
    const tier = args.value(av, "--tier") orelse "oa";
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    switch (sche.check(cx, &st, cust)) {
        .go => {},
        else => {
            util.eprint(cx.io, "error: runs are stopped\nwhy: kill switch or cust paused\nfix: scrape state --cust {s}\n", .{cust});
            return 3;
        },
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var code: u8 = 0;
    if (std.mem.eql(u8, tier, "oa")) {
        if (osync.syncOa(cx, &st, a, cust, args.has(av, "--refresh-profiles"))) |s| {
            util.print(cx.io, "sync oa {s}: followers {d} · messages {d} · added {d} · dup {d} · calls {d}{s}\n", .{ cust, s.followers, s.messages, s.added, s.dup, s.calls, if (s.quota_stop) " · QUOTA STOP" else "" });
            if (s.quota_stop) code = 3;
        } else |e| code = report(cx, e, cust);
    } else if (std.mem.eql(u8, tier, "articles")) {
        if (oavid.syncArticles(cx, &st, a, cust)) |n| util.print(cx.io, "sync articles {s}: added {d}\n", .{ cust, n }) else |e| code = report(cx, e, cust);
    } else if (std.mem.eql(u8, tier, "mini")) {
        const f = args.value(av, "--file") orelse {
            util.eprint(cx.io, "error: --file missing\nwhy: Mini App stats come from the cust's own export\nfix: scrape sync --cust {s} --tier mini --file export.csv\n", .{cust});
            return 2;
        };
        if (mini.importFile(cx, &st, a, cust, f)) |n| util.print(cx.io, "sync mini {s}: added {d}\n", .{ cust, n }) else |e| code = report(cx, e, cust);
    } else if (std.mem.eql(u8, tier, "personal")) {
        if (psync.syncPersonal(cx, &st, a, cust, args.value(av, "--fixture"))) |s| util.print(cx.io, "sync personal {s}: friends {d} · groups {d} · messages {d} · added {d} · calls {d}\n", .{ cust, s.friends, s.groups, s.messages, s.added, s.calls }) else |e| code = report(cx, e, cust);
    } else {
        util.eprint(cx.io, "error: unknown tier '{s}'\nwhy: oa, articles, mini, personal\nfix: pick one\n", .{tier});
        return 2;
    }
    sche.finish(cx, &st, cust, "sync", code);
    watch.record(cx, .{ .ts = cx.nowMs(), .cust = cust, .job = "sync", .code = code, .fetched = 0, .added = 0, .blocked = 0, .failed = if (code == 1) 1 else 0, .credits = 0, .ms = 0 });
    watch.ping(cx, code == 0);
    return code;
}

fn report(cx: *ctx_mod.Ctx, e: anyerror, cust: []const u8) u8 {
    switch (e) {
        error.ConsentRequired => util.eprint(cx.io, "error: no consent on file for {s}\nwhy: third-party chat data needs the cust's consent (PDPL)\nfix: record it in cust.json (consent:true) after the cust agrees\n", .{cust}),
        error.OaNotEnabled => util.eprint(cx.io, "error: OA tier is off for {s}\nwhy: cust has not connected an OA\nfix: scrape login --cust {s} --tier oa\n", .{ cust, cust }),
        error.PersonalTierOff => util.eprint(cx.io, "error: personal tier is off for {s}\nwhy: config side.enabled or cust.personal_enabled is false\nfix: scrape login --cust {s} --tier personal (throwaway account only)\n", .{ cust, cust }),
        error.TierCut, error.DeadSession, error.RateLimited => {
            util.eprint(cx.io, "error: personal tier stopped ({s})\nwhy: Zalo ended the session or limited it; the tier is cut to protect the account\nfix: scrape risk --cust {s}; log in again only after review\n", .{ @errorName(e), cust });
            return 3;
        },
        error.LeaseHeld => {
            util.eprint(cx.io, "error: another host holds the lease\nwhy: one web session per account\nfix: wait for it to expire or stop the other host\n", .{});
            return 3;
        },
        error.DailyCap => {
            util.eprint(cx.io, "error: daily call cap reached\nwhy: side.daily_cap protects the account\nfix: try tomorrow\n", .{});
            return 3;
        },
        error.TokenDead => {
            util.eprint(cx.io, "error: OA token is dead\nwhy: refresh failed (revoked or expired > 3 months)\nfix: scrape login --cust {s} --tier oa again\n", .{cust});
            return 3;
        },
        error.QuotaStop => {
            util.eprint(cx.io, "error: Zalo quota reached\nwhy: the OA's plan limit\nfix: wait for the reset\n", .{});
            return 3;
        },
        error.NoMasterKey, error.BadMasterKey, error.NoCreds, error.NoToken => util.eprint(cx.io, "error: secrets not ready ({s})\nwhy: master key, app credentials or tokens missing\nfix: see scrape login --cust {s}\n", .{ @errorName(e), cust }),
        error.EmptyExport, error.BadHeader, error.FileNotFound, error.FileTooBig, error.TooManyRows, error.TooManyColumns => util.eprint(cx.io, "error: export file refused ({s})\nwhy: empty, missing, too big, or bad header row\nfix: re-export a CSV with a header row (max 5 MB)\n", .{@errorName(e)}),
        else => {
            util.eprint(cx.io, "error: sync failed ({s})\nwhy: network, reply shape, or store busy\nfix: retry; see audit.jsonl\n", .{@errorName(e)});
            return 1;
        },
    }
    return 2;
}
