// login --cust ID [--code CODE] [--status]. No code: prints the consent link (hand step: the cust opens it and approves).
// With the code: connects the cust's Pages (tokens go to the vault, never to screen or logs). --status: alive/dead per Page.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const oauth = @import("pv-oauth.zig");
const vault_mod = @import("pv-vault.zig");

fn fail(cx: *ctx_mod.Ctx, e: anyerror) u8 {
    switch (e) {
        error.NoSecret => util.eprint(cx.io, "error: app id or secret missing\nwhy: env {s} / {s} are empty\nfix: export both (never put them in a file)\n", .{ cx.cfg.graph.app_id_env, cx.cfg.graph.app_secret_env }),
        error.NoRedirect => util.eprint(cx.io, "error: no redirect address\nwhy: config graph.redirect_uri is empty\nfix: set your https callback in 00-config.json\n", .{}),
        error.WriteScope => util.eprint(cx.io, "error: a write scope is in config\nwhy: this app is read-only\nfix: remove it from graph.scopes\n", .{}),
        error.PageTaken => util.eprint(cx.io, "error: that Page belongs to another cust\nwhy: one Page, one cust\nfix: purge the other cust first, or use the right id\n", .{}),
        error.NoPages => util.eprint(cx.io, "error: no Pages on this account\nwhy: the login has no Page role, or the Page scopes were not ticked\nfix: log in as a Page admin and tick every Page\n", .{}),
        error.NoMasterKey, error.BadMasterKey => util.eprint(cx.io, "error: master key missing or bad\nwhy: tokens are sealed with it\nfix: export {s}=$(openssl rand -hex 32)\n", .{cx.cfg.secrets.master_env}),
        error.Api, error.DeadToken => util.eprint(cx.io, "error: Facebook refused the code\nwhy: wrong, used or expired code\nfix: run login again for a fresh link\n", .{}),
        else => util.eprint(cx.io, "error: login failed ({s})\nwhy: network or Facebook is down\nfix: retry later\n", .{@errorName(e)}),
    }
    return 2;
}

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    _ = json;
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: a login belongs to one cust\nfix: scrape login --cust ID [--code CODE]\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (args.has(av, "--status")) {
        const c = st.getCust(a, cust) catch {
            util.eprint(cx.io, "error: no such cust\nwhy: no cust file for {s}\nfix: connect a Page first\n", .{cust});
            return 2;
        };
        const v = vault_mod.Vault.open(cx) catch |e| return fail(cx, e);
        var code: u8 = 0;
        for (c.pages) |p| {
            const dead = oauth.isDead(&v, a, cust, p);
            util.print(cx.io, "{s} page {s}: token {s}\n", .{ cust, p, if (dead) "DEAD (reconnect)" else "ok" });
            if (dead) code = 3;
        }
        if (c.pages.len == 0) util.print(cx.io, "{s}: no Page connected\n", .{cust});
        return code;
    }
    if (args.value(av, "--code")) |code| {
        const pages = oauth.connect(cx, &st, a, cust, code) catch |e| return fail(cx, e);
        for (pages) |p| util.print(cx.io, "{s}: connected Page {s} ({s})\n", .{ cust, p.id, p.name });
        util.print(cx.io, "next: scrape consent --cust {s} --grant, then scrape sync --cust {s}\n", .{ cust, cust });
        return 0;
    }
    var rnd: [8]u8 = undefined;
    cx.io.random(&rnd);
    const state = std.fmt.bytesToHex(rnd, .lower);
    const url = oauth.authUrl(cx, a, &state) catch |e| return fail(cx, e);
    util.print(cx.io, "Open this link, log in, approve the Page(s):\n{s}\nThen copy the code= value from the address you land on and run:\nscrape login --cust {s} --code CODE\n", .{ url, cust });
    return 0;
}
