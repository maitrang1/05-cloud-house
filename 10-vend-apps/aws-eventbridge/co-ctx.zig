// =====================================================================
// Des: The shared run context every step body receives: settings, state, vault, the AWS client, the human's typed lines, and the one-time bootstrap key kept in memory only. Also turns a plain step function into an engine row, taking its name and hand-job flag from 10-steps.json.
// Flo: main builds one Ctx > each step gets a pointer > awsUp() fills the service addresses > useCreds() picks the key that signs
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: loaded config, steps, state, vault
// Out: Ctx struct, engine rows
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const conf = @import("co-conf.zig");
const stat = @import("co-state.zig");
const vaul = @import("pv-vault.zig");
const audi = @import("co-audit.zig");
const line = @import("co-line.zig");
const engi = @import("co-engine.zig");
const http = @import("ap-http.zig");
const signz = @import("ap-sign.zig");
const awsz = @import("ap-aws.zig");
const osyz = @import("co-os.zig");

pub const CF = .{ .vkAkid = "aws.akid", .vkSecr = "aws.secr", .vkTick = "tick.key", .vkMail = "aws.mail", .tmplRegi = "regi", .tickBytes = 32 };

pub const Ctx = struct {
    gpa: std.mem.Allocator, // arena: nothing is freed one by one
    io: std.Io,
    conf: *const conf.Conf,
    steps: conf.Steps,
    stat: *stat.Stat,
    vaul: *vaul.Vaul,
    logz: *audi.Audi,
    http: *http.Http,
    aws: *awsz.Aws,
    inpu: *line.Inpu,
    root: []const u8, // data folder
    paid: bool = false, // --paid typed
    drift: bool = false, // a check found something different
    confPath: []const u8 = "00-config.json", // the settings file in use (the backup copies it)
    boot: ?signz.Creds = null, // the pasted bootstrap key: memory only, never saved
    usedBoot: bool = false, // the bootstrap key signed something this run (the report says deactivate it)

    // sleep n seconds (steps that poll)
    pub fn sleepSecs(self: *Ctx, secs: u32) void {
        std.Io.sleep(self.io, .fromSeconds(secs), .awake) catch {};
    }

    // now in unix seconds
    pub fn nowSecs(self: *Ctx) i64 {
        return @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000);
    }

    // the region in use: the saved one, else the config one
    pub fn regiNow(self: *Ctx) []const u8 {
        const idsz = self.stat.data.idsz;
        return if (idsz.regi.len > 0) idsz.regi else self.conf.cred.regi;
    }

    // fill the five service addresses for the region; false while no region is known
    pub fn awsUp(self: *Ctx) !bool {
        const regi = self.regiNow();
        if (regi.len == 0) return false;
        const apis = self.conf.apis;
        self.aws.regi = regi;
        self.aws.iamr = apis.iamr;
        self.aws.budr = apis.budr;
        self.aws.sts = try conf.tmplFill(self.gpa, apis.sts, CF.tmplRegi, regi);
        self.aws.iam = try conf.tmplFill(self.gpa, apis.iam, CF.tmplRegi, regi);
        self.aws.budg = try conf.tmplFill(self.gpa, apis.budg, CF.tmplRegi, regi);
        self.aws.even = try conf.tmplFill(self.gpa, apis.even, CF.tmplRegi, regi);
        self.aws.sche = try conf.tmplFill(self.gpa, apis.sche, CF.tmplRegi, regi);
        return true;
    }

    // the scoped key from the vault, null when not made yet
    pub fn scoped(self: *Ctx) ?signz.Creds {
        const akid = self.vaul.getz(CF.vkAkid) orelse return null;
        const secr = self.vaul.getz(CF.vkSecr) orelse return null;
        return .{ .akid = akid, .secr = secr };
    }

    // pick the signing key: the bootstrap key while it is in memory, else the scoped one; false when neither exists
    pub fn useCreds(self: *Ctx) !bool {
        if (!try self.awsUp()) return false;
        if (self.boot) |cred| {
            self.http.creds = cred;
            self.usedBoot = true;
            return true;
        }
        if (self.scoped()) |cred| {
            self.http.creds = cred;
            return true;
        }
        return false;
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

    // a fresh random secret as lowercase hex
    pub fn randHex(self: *Ctx) ![]u8 {
        var raw: [CF.tickBytes]u8 = undefined;
        self.io.random(&raw);
        return std.fmt.allocPrint(self.gpa, "{x}", .{&raw});
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
