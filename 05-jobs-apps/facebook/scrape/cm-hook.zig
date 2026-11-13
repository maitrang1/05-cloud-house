// hook <part>: what the host calls when Facebook calls us. The app itself opens no port.
//   verify --mode M --token T --challenge C      GET handshake: prints the challenge (exit 0) or refuses (exit 3)
//   event --file F --sig 'sha256=HEX'            POST events: verify on the RAW file bytes, store (replay-safe)
//   delete --signed-request S                    deletion callback: purge that user, print {url, confirmation_code}
//   status --code C                              deletion status: done (exit 0) or unknown (exit 2)
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const hook = @import("pv-hook.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8, json: bool) u8 {
    _ = json;
    if (av.len == 0) {
        util.eprint(cx.io, "error: usage\nwhy: hook needs a part\nfix: scrape hook verify|event|delete|status ...\n", .{});
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    const part = av[0];
    const rest = av[1..];
    if (std.mem.eql(u8, part, "verify")) {
        const c = hook.challenge(cx, args.value(rest, "--mode") orelse "", args.value(rest, "--token") orelse "", args.value(rest, "--challenge") orelse "") orelse {
            util.eprint(cx.io, "error: handshake refused\nwhy: wrong mode or verify token\nfix: the token must equal env {s}\n", .{cx.cfg.hook.verify_env});
            return 3;
        };
        util.printAll(cx.io, c);
        util.printAll(cx.io, "\n");
        return 0;
    }
    if (std.mem.eql(u8, part, "event")) {
        const f = args.value(rest, "--file") orelse {
            util.eprint(cx.io, "error: --file missing\nwhy: the raw request body is read from a file\nfix: scrape hook event --file F --sig 'sha256=HEX'\n", .{});
            return 2;
        };
        const body = util.readAll(a, cx.io, f, 8 * 1024 * 1024) catch {
            util.eprint(cx.io, "error: cannot read {s}\nwhy: missing file\nfix: save the raw body first\n", .{f});
            return 2;
        };
        const ev = hook.handleEvent(cx, &st, a, body, args.value(rest, "--sig") orelse "") catch |e| {
            switch (e) {
                error.BadSignature => util.eprint(cx.io, "error: bad signature\nwhy: not signed with our app secret (forged or changed)\nfix: answer 403 and ignore\n", .{}),
                error.NoSecret => util.eprint(cx.io, "error: app secret missing\nwhy: env {s} is empty\nfix: export it\n", .{cx.cfg.graph.app_secret_env}),
                else => util.eprint(cx.io, "error: event refused ({s})\nwhy: not a Page event body\nfix: answer 400\n", .{@errorName(e)}),
            }
            return if (e == error.BadSignature) 3 else 2;
        };
        util.print(cx.io, "event: stored {d} · dup {d} · unknown page {d}\n", .{ ev.stored, ev.dup, ev.unknown_page });
        return 0;
    }
    if (std.mem.eql(u8, part, "delete")) {
        const d = hook.deletion(cx, &st, a, args.value(rest, "--signed-request") orelse "") catch |e| {
            util.eprint(cx.io, "error: deletion refused ({s})\nwhy: bad signature, wrong algorithm or junk request\nfix: answer 400; nothing was removed\n", .{@errorName(e)});
            return if (e == error.BadSignature) 3 else 2;
        };
        const O = struct { url: []const u8, confirmation_code: []const u8 };
        const s = util.jsonStr(a, O{ .url = d.url, .confirmation_code = d.confirmation_code }) catch return 1;
        util.printAll(cx.io, s);
        util.printAll(cx.io, "\n");
        return 0;
    }
    if (std.mem.eql(u8, part, "status")) {
        const done = hook.deletionDone(cx, a, args.value(rest, "--code") orelse "");
        util.print(cx.io, "{s}\n", .{if (done) "done" else "unknown"});
        return if (done) 0 else 2;
    }
    util.eprint(cx.io, "error: unknown part '{s}'\nwhy: verify, event, delete or status\nfix: pick one\n", .{part});
    return 2;
}
