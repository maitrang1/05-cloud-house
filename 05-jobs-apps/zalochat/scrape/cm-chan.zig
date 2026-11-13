// chan status | chan proof --vendor V --url U... | chan scan --cust ID --url U...
// Channel/Video pages of other creators: OFF until a written proof (config chan.proof_pages / pass_pct) passes. Links + metadata only.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");
const args = @import("co-args.zig");
const store_mod = @import("rw-store.zig");
const regis = @import("ve-regis.zig");
const chan = @import("ve-chan.zig");

pub fn run(cx: *ctx_mod.Ctx, av: []const []const u8) u8 {
    const sub = if (av.len > 0) av[0] else "status";
    if (std.mem.eql(u8, sub, "status")) {
        util.print(cx.io, "channel/video pages: {s}\n", .{if (chan.enabled(cx)) "ON (proof passed)" else "OFF (no passing proof yet)"});
        return 0;
    }
    var arena = std.heap.ArenaAllocator.init(cx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var st = store_mod.Store.init(cx.io, cx.gpa, cx.home);
    const reg = cx.vendor_reg orelse regis.load(a, cx.io, cx.rel(a, cx.cfg.vendor.file) catch return 1, cx.mock) catch {
        util.eprint(cx.io, "error: vendor file unreadable\nwhy: {s}\nfix: restore df-scrape-vendors.json\n", .{cx.cfg.vendor.file});
        return 2;
    };
    const urls = args.all(a, av, "--url") catch return 1;
    if (std.mem.eql(u8, sub, "proof")) {
        const v = args.value(av, "--vendor") orelse {
            util.eprint(cx.io, "error: --vendor missing\nwhy: the proof tests one helper\nfix: scrape chan proof --vendor zenrows --url U (20+ urls)\n", .{});
            return 2;
        };
        const p = chan.runProof(cx, &st, reg, v, urls) catch return 1;
        util.print(cx.io, "proof {s}: {d}/{d} ok · {s}\n", .{ v, p.ok, p.tried, if (p.pass) "PASS - channel pages ON" else "FAIL - stays OFF" });
        return if (p.pass) 0 else 3;
    }
    if (std.mem.eql(u8, sub, "scan")) {
        const cust = args.custArg(cx, av) orelse return 2;
        const n = chan.scanCust(cx, &st, cust, reg, urls) catch |e| {
            if (e == chan.ScanErr.ChanOff) {
                util.eprint(cx.io, "error: channel pages are off\nwhy: no passing {d}-page proof on file\nfix: scrape chan proof --vendor V --url ... first\n", .{cx.cfg.chan.proof_pages});
                return 3;
            }
            util.eprint(cx.io, "error: chan scan failed ({s})\nwhy: cust file missing or store busy\nfix: check the cust id\n", .{@errorName(e)});
            return 1;
        };
        util.print(cx.io, "chan scan {s}: added {d}\n", .{ cust, n });
        return 0;
    }
    util.eprint(cx.io, "error: unknown chan command\nwhy: status, proof, scan\nfix: scrape chan status\n", .{});
    return 2;
}
