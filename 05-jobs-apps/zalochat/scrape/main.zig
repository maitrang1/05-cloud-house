// scrape - zalochat scrape app. CLI only. Exit: 0 ok · 1 failed · 2 usage/config · 3 blocked/drift.
const std = @import("std");
const bo = @import("build_options");
const util = @import("co-util.zig");
const cfg_mod = @import("co-cfg.zig");
const ctx_mod = @import("co-ctx.zig");
const state_cmd = @import("cm-state.zig");
const scan_cmd = @import("cm-scan.zig");
const probe_cmd = @import("cm-probe.zig");
const rows_cmd = @import("cm-rows.zig");
const login_cmd = @import("cm-login.zig");
const sync_cmd = @import("cm-sync.zig");
const consent_cmd = @import("cm-consent.zig");
const purge_cmd = @import("cm-purge.zig");
const dump_cmd = @import("cm-dump.zig");
const risk_cmd = @import("cm-risk.zig");
const cust_cmd = @import("cm-cust.zig");
const chan_cmd = @import("cm-chan.zig");

pub const Ctx = ctx_mod.Ctx;

const Usage =
    \\scrape <cmd> [--config FILE] [--json]
    \\  state                              app + config + hub jobs
    \\  login --cust ID --tier oa [--code C]   connect an OA
    \\  sync --cust ID --tier oa|articles|mini [--file F]
    \\  chan status | proof --vendor V --url U... | scan --cust ID --url U...   channel pages (off until proof)
    \\  cust --cust ID [--add-url U] [--webhook URL] [--vendors on|off]   create/edit a cust
    \\  risk --cust ID [--reset]               personal-tier drill state
    \\  consent --cust ID --grant|--revoke
    \\  purge --cust ID [--old] [--yes]        offboard (dry run without --yes)
    \\  dump --cust ID [--out DIR]             export (no secrets)
    \\  rows --cust ID [--since N] [--push]   pull or push rows
    \\  probe <vendor> <url> [--dry-run]    one vendor call
    \\  scan --cust ID [--url U] [--dry-run]   public pages -> rows
    \\
;

fn die(io: std.Io, code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    util.eprint(io, fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    var list: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| try list.append(arena, a);
    const av = list.items;
    if (av.len == 0) {
        util.eprint(io, "{s}", .{Usage});
        std.process.exit(2);
    }
    var config_path: []const u8 = "00-config.json";
    var json = false;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < av.len) : (i += 1) {
        if (std.mem.eql(u8, av[i], "--config") and i + 1 < av.len) {
            i += 1;
            config_path = av[i];
        } else if (std.mem.eql(u8, av[i], "--json")) json = true else try rest.append(arena, av[i]);
    }
    if (init.environ_map.get("SCRAPE_CONFIG")) |p| if (p.len > 0 and std.mem.eql(u8, config_path, "00-config.json")) {
        config_path = p;
    };
    // default config: ./00-config.json, else the one next to the exe (release folder layout)
    var exe_dir: []const u8 = "";
    if (std.mem.eql(u8, config_path, "00-config.json") and !util.exists(io, config_path)) {
        if (std.process.executableDirPathAlloc(io, arena)) |d| {
            exe_dir = d;
            const alt = try std.fmt.allocPrint(arena, "{s}/00-config.json", .{d});
            const alt2 = try std.fmt.allocPrint(arena, "{s}/../00-config.json", .{d}); // release layout: bin/ next to the config
            if (util.exists(io, alt)) config_path = alt else if (util.exists(io, alt2)) config_path = alt2;
        } else |_| {}
    }
    var why: [160]u8 = undefined;
    var wl: usize = 0;
    const cfg = cfg_mod.load(arena, io, config_path, &why, &wl) catch die(io, 2, "error: {s}\nwhy: bad or missing config\nfix: edit {s} (unknown keys are refused)", .{ why[0..wl], config_path });
    const home = ctx_mod.resolveHome(arena, init.environ_map, cfg.home) catch die(io, 2, "error: no home dir\nwhy: HOME/USERPROFILE/SCRAPE_HOME unset\nfix: set SCRAPE_HOME", .{});
    const cfg_dir = std.fs.path.dirname(config_path) orelse ".";
    var cx = Ctx{ .cfg_dir = cfg_dir, .io = io, .gpa = init.gpa, .arena = arena, .env = init.environ_map, .cfg = cfg, .home = home, .mock = bo.mock };
    const code = dispatch(&cx, rest.items, json);
    std.process.exit(code);
}

pub fn dispatch(cx: *Ctx, av: []const []const u8, json: bool) u8 {
    if (av.len == 0) {
        util.eprint(cx.io, "{s}", .{Usage});
        return 2;
    }
    const cmd = av[0];
    if (std.mem.eql(u8, cmd, "chan")) return chan_cmd.run(cx, av[1..]);
    if (std.mem.eql(u8, cmd, "cust")) return cust_cmd.run(cx, av[1..]);
    if (std.mem.eql(u8, cmd, "risk")) return risk_cmd.run(cx, av[1..]);
    if (std.mem.eql(u8, cmd, "consent")) return consent_cmd.run(cx, av[1..]);
    if (std.mem.eql(u8, cmd, "purge")) return purge_cmd.run(cx, av[1..]);
    if (std.mem.eql(u8, cmd, "dump")) return dump_cmd.run(cx, av[1..]);
    if (std.mem.eql(u8, cmd, "login")) return login_cmd.run(cx, av[1..], json);
    if (std.mem.eql(u8, cmd, "sync")) return sync_cmd.run(cx, av[1..], json);
    if (std.mem.eql(u8, cmd, "rows")) return rows_cmd.run(cx, av[1..], json);
    if (std.mem.eql(u8, cmd, "probe")) return probe_cmd.run(cx, av[1..], json);
    if (std.mem.eql(u8, cmd, "scan")) return scan_cmd.run(cx, av[1..], json);
    if (std.mem.eql(u8, cmd, "state")) return state_cmd.run(cx, av[1..], json, bo.version, bo.mock);
    util.eprint(cx.io, "error: unknown command '{s}'\nwhy: not in the command list\nfix: run scrape with no args\n", .{cmd});
    return 2;
}

test {
    _ = @import("co-util.zig");
    _ = @import("co-cfg.zig");
    _ = @import("co-ctx.zig");
    _ = @import("cm-state.zig");
    _ = @import("ve-regis.zig");
    _ = @import("ve-quota.zig");
    _ = @import("ve-break.zig");
    _ = @import("ve-call.zig");
    _ = @import("ve-route.zig");
    _ = @import("ve-chan.zig");
    _ = @import("pv-vault.zig");
    _ = @import("pv-oapi.zig");
    _ = @import("pv-osync.zig");
    _ = @import("pv-oavid.zig");
    _ = @import("pv-mini.zig");
    _ = @import("cm-login.zig");
    _ = @import("cm-sync.zig");
    _ = @import("pv-legal.zig");
    _ = @import("pv-lease.zig");
    _ = @import("pv-risk.zig");
    _ = @import("pv-sidec.zig");
    _ = @import("pv-psync.zig");
    _ = @import("pv-plogin.zig");
    _ = @import("cm-risk.zig");
    _ = @import("cm-cust.zig");
    _ = @import("cm-chan.zig");
    _ = @import("pv-purge.zig");
    _ = @import("pv-dump.zig");
    _ = @import("cm-consent.zig");
    _ = @import("cm-purge.zig");
    _ = @import("cm-dump.zig");
    _ = @import("te-isol.zig");
    _ = @import("te-e2e.zig");
    _ = @import("co-args.zig");
    _ = @import("cm-scan.zig");
    _ = @import("cm-probe.zig");
    _ = @import("cm-rows.zig");
    _ = @import("rw-sche.zig");
    _ = @import("rw-watch.zig");
    _ = @import("rw-shape.zig");
    _ = @import("rw-dedup.zig");
    _ = @import("rw-store.zig");
    _ = @import("rw-meter.zig");
    _ = @import("rw-deliv.zig");
    _ = @import("pu-guard.zig");
    _ = @import("pu-net.zig");
    _ = @import("pu-robot.zig");
    _ = @import("pu-fetch.zig");
    _ = @import("pu-parse.zig");
}
