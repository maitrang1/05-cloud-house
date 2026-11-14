// =====================================================================
// Des: Steps 0-4: preflight, the two sign-up hand jobs, making the API signing key, and the console hand job (add the public key, paste the preview block) until a signed call to your own user works.
// Flo: check tools > guide card sign-up > ask region > make key + vault it > guide console key upload > read ids > poll signed call
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx (config, state, vault, typed lines)
// Out: engine rows pref-chec, sign-card, sign-regi, keyz-make, cons-keyz
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxx = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const osyz = @import("co-os.zig");
const rsak = @import("pv-rsak.zig");

const Ctx = ctxx.Ctx;
const Done = engi.Done;

const CF = .{ .regiMinz = 5, .regiMaxz = 40, .keyUser = "user", .keyTena = "tenancy", .keyFing = "fingerprint", .keyRegi = "region" };

pub fn rows(ctx: *Ctx) [5]engi.Row {
    return .{
        ctxx.row(ctx, "pref-chec", &prefChec),
        ctxx.row(ctx, "sign-card", &signCard),
        ctxx.row(ctx, "sign-regi", &signRegi),
        ctxx.row(ctx, "keyz-make", &keyzMake),
        ctxx.row(ctx, "cons-keyz", &consKeyz),
    };
}

// step 0: the one tool the app may need
fn prefChec(ctx: *Ctx) anyerror!Done {
    if (ctx.conf.keyz.file.len == 0 and !ctx.tool.have(ctx.conf.keyz.tool)) {
        osyz.errz("{s} not found: it makes the signing key. Install it, or set keyz.file to an existing PEM key\n", .{ctx.conf.keyz.tool});
        return error.MissingTool;
    }
    return .{ .okay = "tools ok, config valid" };
}

fn neverPoll(raw: *anyopaque) anyerror!bool {
    _ = raw;
    return false; // not detectable: the human types g
}

// step 1: hand job 1
fn signCard(ctx: *Ctx) anyerror!Done {
    return .{ .wait = .{
        .urlz = ctx.conf.urls.sign,
        .line = .{ "Fill in name, email and country. Add a card: it is an identity hold, not a charge.", "Open the email from Oracle and click its link.", "When the sign-up says your account is ready, type g." },
        .poll = &neverPoll,
        .ctx = ctx,
    } };
}

// true for text like eu-frankfurt-1
pub fn regiOkay(text: []const u8) bool {
    if (text.len < CF.regiMinz or text.len > CF.regiMaxz) return false;
    for (text) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    return true;
}

// step 2: hand job 2. The region id is in the console top bar or sign-up mail
fn signRegi(ctx: *Ctx) anyerror!Done {
    const idsz = &ctx.stat.data.idsz;
    if (ctx.conf.cred.regi.len > 0) idsz.regi = ctx.conf.cred.regi;
    if (idsz.regi.len == 0) {
        ctx.say("  Your home region was chosen at sign-up and cannot change. Free VMs live only there.\n  Type its id (example: eu-frankfurt-1): ", .{});
        const got = ctx.inpu.wait(ctx.conf.guid.wait) orelse return error.GuidTime;
        if (std.mem.eql(u8, got, "x")) return engi.Stop.EngiStop;
        if (!regiOkay(got)) {
            osyz.errz("not a region id: use lowercase letters, digits and dashes, like eu-frankfurt-1\n", .{});
            return error.BadRegion;
        }
        idsz.regi = got;
    } else if (!regiOkay(idsz.regi)) return error.BadRegion;
    try ctx.stat.save();
    return .{ .okay = idsz.regi };
}

// step 3: make (or reuse) the RSA key and vault it
fn keyzMake(ctx: *Ctx) anyerror!Done {
    const idsz = &ctx.stat.data.idsz;
    var pem: []const u8 = ctx.vaul.getz(ctxx.CF.vaulKeyz) orelse "";
    var note: []const u8 = "key already in the vault";
    if (pem.len == 0) {
        if (ctx.conf.keyz.file.len > 0) {
            pem = try std.Io.Dir.cwd().readFileAlloc(ctx.io, ctx.conf.keyz.file, ctx.gpa, .limited(1 << 16));
            note = "key read from keyz.file and vaulted";
        } else {
            const bits = try std.fmt.allocPrint(ctx.gpa, "{d}", .{ctx.conf.keyz.bits});
            const outp = try ctx.tool.runz(&.{ ctx.conf.keyz.tool, "genrsa", bits }, null);
            if (!outp.okay()) {
                osyz.errz("{s} could not make a key: {s}\n", .{ ctx.conf.keyz.tool, outp.errz });
                return error.KeyGenFail;
            }
            pem = outp.outz;
            note = "key made and vaulted";
        }
        const held = try rsak.pemPars(ctx.gpa, pem); // refuse a weak or unreadable key before it is stored
        _ = held;
        try ctx.vaul.putz(ctxx.CF.vaulKeyz, pem);
    }
    const held = try rsak.pemPars(ctx.gpa, pem);
    idsz.fing = try rsak.fingerprint(ctx.gpa, held.key);
    try ctx.stat.save();
    return .{ .okay = note };
}

// "user=ocid1.user.oc1..x" -> .{ "user", "ocid1.user.oc1..x" }; null for other lines
pub fn kvLine(text: []const u8) ?[2][]const u8 {
    const eqzz = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const keyz = std.mem.trim(u8, text[0..eqzz], " \t");
    var valu = text[eqzz + 1 ..];
    if (std.mem.indexOfScalar(u8, valu, '#')) |hash| valu = valu[0..hash];
    valu = std.mem.trim(u8, valu, " \t\"'");
    if (keyz.len == 0 or valu.len == 0) return null;
    return .{ keyz, valu };
}

// step 4: hand job 3
fn consKeyz(ctx: *Ctx) anyerror!Done {
    const idsz = &ctx.stat.data.idsz;
    if (ctx.conf.cred.tena.len > 0) idsz.tena = ctx.conf.cred.tena;
    if (ctx.conf.cred.user.len > 0) idsz.user = ctx.conf.cred.user;

    // resumed run: the key may already be live
    if (try ctx.ociUp()) if (ctx.oci.userLive(idsz.user)) return .{ .okay = "signed call to your user works" };

    const pem = ctx.vaul.getz(ctxx.CF.vaulKeyz) orelse return error.NoKey;
    const held = try rsak.pemPars(ctx.gpa, pem);
    const pubp = try rsak.publicPem(ctx.gpa, held.key);
    if (ctx.conf.guid.open) _ = osyz.urlzOpen(ctx.io, ctx.gpa, ctx.conf.urls.keys);
    if (ctx.conf.guid.clip) _ = osyz.clipSetz(ctx.io, pubp);
    ctx.say("  open: {s}\n  1. Log in (approve MFA if asked).\n  2. Profile > API keys > Add API key > Paste a public key. Paste this (it is also on your clipboard), then Add:\n{s}  3. Oracle shows a configuration preview. Paste its lines here, one per line (user=, fingerprint=, tenancy=, region=).\n", .{ ctx.conf.urls.keys, pubp });

    var left: u64 = ctx.conf.guid.wait;
    var pfin: []const u8 = ""; // fingerprint the human pasted, if any
    while (true) {
        if (idsz.tena.len > 0 and idsz.user.len > 0) {
            // the pasted preview must be for OUR key; anything else starts over
            if (pfin.len == 0 or std.mem.eql(u8, pfin, idsz.fing)) break;
            ctx.say("  that fingerprint is not ours ({s}). Paste the preview of the key you just added.\n", .{idsz.fing});
            idsz.tena = "";
            idsz.user = "";
            pfin = "";
        }
        const got = ctx.inpu.wait(ctx.conf.guid.poll) orelse {
            if (left <= ctx.conf.guid.poll) return error.GuidTime;
            left -= ctx.conf.guid.poll;
            continue;
        };
        if (std.mem.eql(u8, got, "x")) return engi.Stop.EngiStop;
        const pair = kvLine(got) orelse continue;
        if (std.mem.eql(u8, pair[0], CF.keyUser)) idsz.user = pair[1];
        if (std.mem.eql(u8, pair[0], CF.keyTena)) idsz.tena = pair[1];
        if (std.mem.eql(u8, pair[0], CF.keyFing)) pfin = pair[1];
        if (std.mem.eql(u8, pair[0], CF.keyRegi) and regiOkay(pair[1])) idsz.regi = pair[1];
    }
    try ctx.stat.save();
    if (!try ctx.ociUp()) return error.NoCreds;

    // detect, don't ask: poll a signed call until Oracle accepts the new key
    var tail: u64 = ctx.conf.guid.wait;
    while (!ctx.oci.userLive(idsz.user)) {
        if (tail <= ctx.conf.guid.poll) {
            osyz.errz("Oracle still refuses the key: {s}\nfix: check the key was added to YOUR user and your PC clock is right (limit 5 minutes), then rerun\n", .{ctx.oci.last});
            return error.GuidTime;
        }
        tail -= ctx.conf.guid.poll;
        ctx.sleepSecs(ctx.conf.guid.poll);
    }
    return .{ .okay = "signed call to your user works" };
}

test "region ids and preview lines parse" {
    try std.testing.expect(regiOkay("eu-frankfurt-1"));
    try std.testing.expect(!regiOkay("EU-Frankfurt"));
    try std.testing.expect(!regiOkay("x"));
    const pair = kvLine("user=ocid1.user.oc1..aaa # note").?;
    try std.testing.expectEqualStrings("user", pair[0]);
    try std.testing.expectEqualStrings("ocid1.user.oc1..aaa", pair[1]);
    try std.testing.expect(kvLine("[DEFAULT]") == null);
    try std.testing.expect(kvLine("key_file=") == null);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
