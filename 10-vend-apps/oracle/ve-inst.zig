// =====================================================================
// Des: Steps 7 and 8: render the cloud-init script (app user, firewall port, app exe, systemd unit, optional heartbeat), make the SSH key, launch the free VM, wait until it runs and read its public address. Refuses non-free shapes unless paid is allowed and typed.
// Flo: quota check > pick AD + image > render cloud-init > launch (next AD on no capacity) > poll RUNNING > read IP > save
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, vault, signed client)
// Out: engine rows inst-make, keep-aliv
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const conf = @import("co-conf.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const sshk = @import("pv-sshk.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;

const CF = .{ .runnState = "RUNNING", .capaWord = "capacity", .sshPort = 22, .busyMinz = 1 };

pub fn rows(ctx: *Ctx) [2]engi.Row {
    return .{ ctxx.row(ctx, "inst-make", &instMake), ctxx.row(ctx, "keep-aliv", &keepAliv) };
}

// first non-ssh ingress port, else ssh: the port the app listens on
pub fn appPort(cfg: *const conf.Conf) u32 {
    for (cfg.ingr) |item| if (item.port != CF.sshPort) return item.port;
    return CF.sshPort;
}

// the cloud-init script, every value from config
pub fn cloudInit(gpa: std.mem.Allocator, cfg: *const conf.Conf) ![]u8 {
    const port = try std.fmt.allocPrint(gpa, "{d}", .{appPort(cfg)});
    const busy = try std.fmt.allocPrint(gpa, "{d}", .{@max(CF.busyMinz, cfg.keep.secs * cfg.keep.duty / 100)});
    const secs = try std.fmt.allocPrint(gpa, "{d}", .{cfg.keep.secs});
    const base = [_]conf.Pair{ .{ "svcu", cfg.boot.svcu }, .{ "svcn", cfg.boot.svcn }, .{ "bina", cfg.boot.bina }, .{ "args", cfg.boot.args }, .{ "urlz", cfg.boot.urlz }, .{ "sha2", cfg.boot.sha2 }, .{ "port", port }, .{ "busy", busy }, .{ "secs", secs } };
    const unit = try conf.linzFill(gpa, cfg.unit, &base);
    const keep: []const u8 = if (cfg.keep.on) try conf.linzFill(gpa, cfg.kunit, &base) else "";
    var all: [base.len + 2]conf.Pair = undefined;
    @memcpy(all[0..base.len], &base);
    all[base.len] = .{ "unit", std.mem.trimEnd(u8, unit, "\n") };
    all[base.len + 1] = .{ "keep", std.mem.trimEnd(u8, keep, "\n") };
    return conf.linzFill(gpa, cfg.cini, &all);
}

// true when the shape is Always Free
fn shapFree(cfg: *const conf.Conf) bool {
    for (cfg.inst.free) |item| if (std.mem.eql(u8, item, cfg.inst.shap)) return true;
    return false;
}

// step 7
fn instMake(ctx: *Ctx) anyerror!Done {
    if (!try ctx.ociUp()) return error.NoCreds;
    const cfg = ctx.conf;
    const idsz = &ctx.stat.data.idsz;
    if (idsz.comp.len == 0 or idsz.subn.len == 0) return error.NoNetwork;
    if (!shapFree(cfg) and !(cfg.paid.okay and ctx.paid)) {
        osyz.errz("shape {s} is not Always Free. Add it to inst.free, or set paid.okay and run with --paid\n", .{cfg.inst.shap});
        return error.PaidNeedsFlag;
    }

    // already launched (state or Oracle knows it): just wait and read the address
    var iden: []const u8 = idsz.inst;
    if (iden.len == 0) iden = (try ctx.oci.instFind(idsz.comp, cfg.inst.name)) orelse "";
    if (iden.len == 0) {
        const live = try ctx.oci.instList(idsz.comp);
        if (live.len >= cfg.quot.vmax) {
            osyz.errz("quota: {d} of {d} free VMs already exist in this compartment\n", .{ live.len, cfg.quot.vmax });
            return error.QuotaFull;
        }
        const sshp = try sshMake(ctx);
        const data = try cloudInit(ctx.gpa, cfg);
        const ads = try ctx.oci.adList(idsz.comp);
        var tried: u32 = 0;
        // primary shape first, then the fallback shape (Arm often sells out; the small x86 micro rarely does)
        const Try = struct { shap: []const u8, ocpu: u32, memg: u32 };
        const plan = [_]Try{ .{ .shap = cfg.inst.shap, .ocpu = cfg.inst.ocpu, .memg = cfg.inst.memg }, .{ .shap = cfg.inst.fall, .ocpu = cfg.inst.fcpu, .memg = cfg.inst.fmem } };
        shapes: for (plan) |one| {
            if (one.shap.len == 0) continue;
            for (ads) |ad| {
                if (!try ctx.oci.shapOffer(idsz.comp, ad, one.shap)) continue;
                const imag = (try ctx.oci.imgFind(idsz.comp, cfg.inst.imgo, cfg.inst.imgv, one.shap)) orelse {
                    osyz.errz("no image {s} {s} for shape {s}: change inst.imgo / inst.imgv\n", .{ cfg.inst.imgo, cfg.inst.imgv, one.shap });
                    return error.NoImage;
                };
                tried += 1;
                iden = ctx.oci.instLaunch(.{ .comp = idsz.comp, .ad = ad, .shap = one.shap, .name = cfg.inst.name, .imag = imag, .subn = idsz.subn, .boot = cfg.inst.boot, .ssh = sshp, .data = data, .ocpu = one.ocpu, .memg = one.memg }) catch |erro| {
                    // out of capacity in this AD: try the next one, anything else stops
                    if (std.ascii.indexOfIgnoreCase(ctx.oci.last, CF.capaWord) != null) continue;
                    return erro;
                };
                break :shapes;
            }
        }
        if (iden.len == 0) {
            osyz.errz("no free VM capacity right now ({d} availability domain(s) tried). Free shapes sell out; rerun later, it resumes here\n", .{tried});
            return error.NoCapacity;
        }
    }
    idsz.inst = iden;
    try ctx.stat.save();

    var left: u64 = cfg.inst.wait;
    while (true) {
        const stz = try ctx.oci.instState(iden);
        if (std.mem.eql(u8, stz, CF.runnState)) break;
        if (std.mem.startsWith(u8, stz, "TERMINAT")) {
            osyz.errz("the VM {s} was terminated outside this app. The app never recreates or deletes: review it in the console\n", .{iden});
            return error.VmGone;
        }
        if (left <= cfg.inst.poll) return error.WaitTime;
        left -= cfg.inst.poll;
        ctx.sleepSecs(cfg.inst.poll);
    }
    var ipzz: []const u8 = "";
    while (true) {
        if (try ctx.oci.instIp(idsz.comp, iden)) |got| {
            ipzz = got;
            break;
        }
        if (left <= cfg.inst.poll) return error.WaitTime;
        left -= cfg.inst.poll;
        ctx.sleepSecs(cfg.inst.poll);
    }
    idsz.pubi = ipzz;
    try ctx.stat.save();
    return .{ .okay = try std.fmt.allocPrint(ctx.gpa, "VM running at {s}", .{ipzz}) };
}

// the ssh public key line: made once, private half vaulted, public half written next to the data
fn sshMake(ctx: *Ctx) ![]const u8 {
    const have = ctx.vaul.getz(ctxx.CF.vaulSshk);
    const pubf = try std.fs.path.join(ctx.gpa, &.{ ctx.root, "oracle-ssh.pub" });
    if (have != null) {
        if (std.Io.Dir.cwd().readFileAlloc(ctx.io, pubf, ctx.gpa, .limited(1 << 12))) |text| return std.mem.trim(u8, text, " \r\n") else |_| {}
    }
    const pair = try sshk.make(ctx.gpa, ctx.io, ctx.conf.keyz.comm);
    try ctx.vaul.putz(ctxx.CF.vaulSshk, pair.priv);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = pubf, .data = pair.publ });
    ctx.stat.data.idsz.sshk = pubf;
    return std.mem.trim(u8, pair.publ, " \r\n");
}

// step 8: the heartbeat is part of cloud-init; this step only tells the truth about it
fn keepAliv(ctx: *Ctx) anyerror!Done {
    if (!ctx.conf.keep.on) return .{ .skip = "keep.on is false: no fake load (the VM may be reclaimed if truly idle for 7 days)" };
    return .{ .okay = try std.fmt.allocPrint(ctx.gpa, "heartbeat in cloud-init: {d}s busy every {d}s", .{ ctx.conf.keep.secs * ctx.conf.keep.duty / 100, ctx.conf.keep.secs }) };
}

test "cloud-init holds the app user, port and unit; the heartbeat only when on" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const gpa = aren.allocator();
    var diag = conf.Diag{};
    var cfg = try conf.confLoad(gpa, std.testing.io, "00-config.json", &diag);
    cfg.boot.urlz = "https://example.test/app";
    cfg.boot.sha2 = "abc123";
    const off = try cloudInit(gpa, &cfg);
    try std.testing.expect(std.mem.indexOf(u8, off, "useradd --system --create-home --shell /usr/sbin/nologin chouse") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "--dport 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "ExecStart=/usr/local/bin/cloud-house-app") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "abc123  /tmp/cloud-house-app.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, off, "keep.timer") == null);
    try std.testing.expect(std.mem.indexOf(u8, off, "{") == null or std.mem.indexOf(u8, off, "{unit}") == null);
    cfg.keep.on = true;
    const on = try cloudInit(gpa, &cfg);
    try std.testing.expect(std.mem.indexOf(u8, on, "cloud-house-app-keep.timer") != null);
    try std.testing.expect(std.mem.indexOf(u8, on, "timeout 15 ") != null); // 25% of 60 s
    try std.testing.expectEqual(@as(u32, 8080), appPort(&cfg));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
