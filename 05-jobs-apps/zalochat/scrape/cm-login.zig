// login --cust ID --tier oa [--code CODE] | --status. No code: prints the consent URL (PKCE saved in the vault). With the code: connects the OA.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const oapi = @import("pv-oapi.zig");
const plogin = @import("pv-plogin.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    _ = json;
    const cust = args.value(av, "--cust") orelse {
        util.eprint(cx.io, "error: --cust missing\nwhy: a login belongs to one cust\nfix: scrape login --cust ID --tier oa [--code CODE]\n", .{});
        return 2;
    };
    if (!ctx_mod.validId(cust)) {
        util.eprint(cx.io, "error: bad cust id\nwhy: only a-z 0-9 _ -\nfix: use a safe id\n", .{});
        return 2;
    }
    const tier = args.value(av, "--tier") orelse "oa";
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    if (std.mem.eql(u8, tier, "personal")) {
        plogin.qrLogin(cx, &st, a, cust, args.value(av, "--fixture")) catch |e| {
            switch (e) {
                error.PersonalTierOff => util.eprint(cx.io, "error: personal tier is off\nwhy: config side.enabled is false (unofficial, can lock the account)\nfix: turn it on only for a throwaway account, after reading the risk notes\n", .{}),
                error.NoNode => util.eprint(cx.io, "error: node not found\nwhy: the sidecar runs on Node\nfix: install Node 20+ or set side.node\n", .{}),
                error.NoMasterKey, error.BadMasterKey => util.eprint(cx.io, "error: master key missing or bad\nwhy: the session is sealed with it\nfix: export {s}=$(openssl rand -hex 32)\n", .{cx.cfg.secrets.master_env}),
                else => util.eprint(cx.io, "error: login failed ({s})\nwhy: QR declined, expired, or Zalo refused\nfix: retry with the secondary account\n", .{@errorName(e)}),
            }
            return 2;
        };
        util.print(cx.io, "{s}: personal session sealed in the vault\n", .{cust});
        return 0;
    }
    if (!std.mem.eql(u8, tier, "oa")) {
        util.eprint(cx.io, "error: unknown tier '{s}'\nwhy: oa or personal\nfix: use --tier oa|personal\n", .{tier});
        return 2;
    }
    var c = oapi.Client.init(cx, &st, a, cust) catch |e| return failMsg(cx, e);
    if (args.has(av, "--status")) {
        util.print(cx.io, "{s}: OA token {s}\n", .{ cust, c.status() });
        return if (std.mem.eql(u8, c.status(), "dead")) 3 else 0;
    }
    if (args.value(av, "--code")) |code| {
        c.exchangeCode(code) catch |e| return failMsg(cx, e);
        if (st.getCust(a, cust)) |cu| {
            var n = cu;
            n.oa_enabled = true;
            st.putCust(a, n) catch {};
        } else |_| {}
        util.print(cx.io, "{s}: connected (tokens saved encrypted)\n", .{cust});
        return 0;
    }
    const url = c.authorizeUrl() catch |e| return failMsg(cx, e);
    util.print(cx.io, "1. Open this link and allow access:\n{s}\n2. Copy the code from the address bar after you allow.\n3. Run: scrape login --cust {s} --tier oa --code <CODE>\n", .{ url, cust });
    return 0;
}

fn failMsg(cx: *ctx_mod.Ctx, e: anyerror) u8 {
    switch (e) {
        error.NoMasterKey, error.BadMasterKey => util.eprint(cx.io, "error: master key missing or bad\nwhy: secrets need a 64-hex key in env {s}\nfix: export {s}=$(openssl rand -hex 32) once, keep it safe\n", .{ cx.cfg.secrets.master_env, cx.cfg.secrets.master_env }),
        error.NoCreds => util.eprint(cx.io, "error: OA app credentials missing\nwhy: env {s}/{s} or oa.redirect_uri not set\nfix: export them (never in a file)\n", .{ cx.cfg.oa.app_id_env, cx.cfg.oa.app_secret_env }),
        error.Api => util.eprint(cx.io, "error: Zalo refused the code\nwhy: wrong, used, or expired code\nfix: run login again for a fresh link\n", .{}),
        else => util.eprint(cx.io, "error: login failed ({s})\nwhy: network or reply problem\nfix: retry; check oa.api_base in config\n", .{@errorName(e)}),
    }
    return if (e == error.Api) 3 else 2;
}
