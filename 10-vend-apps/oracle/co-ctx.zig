// =====================================================================
// Des: The shared run context every step body receives: settings, state, vault, the Oracle client, the human's typed lines. Also turns a plain step function into an engine row, taking its name and hand-job flag from 10-steps.json.
// Flo: main builds one Ctx > each step gets a pointer > ociUp() builds the signed client once the key and ids exist
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: loaded config, steps, state, vault
// Out: Ctx struct, engine rows
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("co-conf.zig");
const stat = @import("co-state.zig");
const vaul = @import("pv-vault.zig");
const audi = @import("co-audit.zig");
const line = @import("co-line.zig");
const tool = @import("co-tool.zig");
const engi = @import("co-engine.zig");
const http = @import("ap-http.zig");
const oci = @import("ap-oci.zig");
const rsak = @import("pv-rsak.zig");
const osyz = @import("co-os.zig");

pub const CF = .{ .vaulKeyz = "oci.key", .vaulSshk = "ssh.priv", .tmplRegi = "{regi}" };

pub const Ctx = struct {
    gpa: std.mem.Allocator, // arena: nothing is freed one by one
    io: std.Io,
    conf: *const conf.Conf,
    steps: conf.Steps,
    stat: *stat.Stat,
    vaul: *vaul.Vaul,
    logz: *audi.Audi,
    http: *http.Http,
    oci: *oci.Oci,
    tool: *tool.Tool,
    inpu: *line.Inpu,
    root: []const u8, // data folder
    paid: bool = false, // --paid typed
    drift: bool = false, // a check found something foreign
    confPath: []const u8 = "00-config.json", // the settings file in use (the backup copies it)

    // sleep n seconds (steps that poll)
    pub fn sleepSecs(self: *Ctx, secs: u32) void {
        std.Io.sleep(self.io, .fromSeconds(secs), .awake) catch {};
    }

    // now in unix seconds
    pub fn nowSecs(self: *Ctx) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
    }

    // build the signed client from the vaulted key and the saved ids; false when something is still missing
    pub fn ociUp(self: *Ctx) !bool {
        const idsz = self.stat.data.idsz;
        const pem = self.vaul.getz(CF.vaulKeyz) orelse return false;
        if (idsz.tena.len == 0 or idsz.user.len == 0 or idsz.regi.len == 0 or idsz.fing.len == 0) return false;
        const held = try rsak.pemPars(self.gpa, pem);
        self.http.creds = .{ .tena = idsz.tena, .user = idsz.user, .fing = idsz.fing, .key = held.key };
        self.oci.iden = try std.mem.replaceOwned(u8, self.gpa, self.conf.apis.iden, CF.tmplRegi, idsz.regi);
        self.oci.iaas = try std.mem.replaceOwned(u8, self.gpa, self.conf.apis.iaas, CF.tmplRegi, idsz.regi);
        self.oci.vers = self.conf.apis.vers;
        return true;
    }

    // the row of 10-steps.json for an id
    pub fn stepOf(self: *Ctx, iden: []const u8) conf.Step {
        for (self.steps.step) |item| if (std.mem.eql(u8, item.iden, iden)) return item;
        return .{ .numb = 0, .iden = iden, .kind = "auto", .hand = 0, .name = iden, .need = "", .done = "" }; // cm-cmds refuses to run when code and file disagree
    }

    // print a line to the human
    pub fn say(self: *Ctx, comptime fmtz: []const u8, args: anytype) void {
        osyz.outz(self.io, fmtz, args);
    }
};

pub const Func = *const fn (ctx: *Ctx) anyerror!engi.Done;

// one engine row from a step function; name and hand flag come from 10-steps.json
pub fn row(ctx: *Ctx, comptime iden: []const u8, comptime func: Func) engi.Row {
    const wrap = struct {
        fn run(raw: *anyopaque, gpa: std.mem.Allocator) anyerror!engi.Done {
            _ = gpa;
            const self: *Ctx = @ptrCast(@alignCast(raw));
            return func(self);
        }
    };
    const item = ctx.stepOf(iden);
    return .{ .iden = iden, .name = item.name, .hand = item.hand > 0, .runz = wrap.run, .ctx = ctx };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
