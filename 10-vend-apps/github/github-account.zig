// =====================================================================
// Des: The account half of the GitHub setup - checks tools, prepares the sign-up, guides the four hand jobs, logs in by device code, and reads who you are
// Flo: tools > free username + vaulted password > sign-up page > email link > device-code login > email verified > 2FA with computed codes > identity
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Ctx, Mode (chec = read-only look, acts = do it)
// Out: Outc per step ; ids go to the state file, secrets to the vault
// Run: not run directly - listed in vendor-github.zig
// Exe: n/a
// =====================================================================
const std = @import("std");
const api = @import("github-api.zig");
const totp = @import("totp-code.zig");
const ctxm = @import("app-ctx.zig");
const Ctx = ctxm.Ctx;
const Mode = ctxm.Mode;
const Outc = ctxm.Outc;

const CF = .{ .pass_keyz = "acct.pass", .totp_keyz = "acct.totp", .reco_keyz = "acct.reco", .name_maxz = 30, .gran = "urn:ietf:params:oauth:grant-type:device_code", .slow_secs = 5, .reco_maxz = 32, .path_mail = "/settings/emails" };
const PASS_SETS = [_][]const u8{ "abcdefghijkmnopqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ", "23456789", "-_.+=" };

const User = struct { login: []const u8 = "", id: u64 = 0, two_factor_authentication: ?bool = null };
const Mail = struct { email: []const u8 = "", primary: bool = false, verified: bool = false };
const Devi = struct { device_code: []const u8 = "", user_code: []const u8 = "", verification_uri: []const u8 = "", expires_in: u32 = 0, interval: u32 = 5 };
const Toke = struct { access_token: []const u8 = "", @"error": []const u8 = "", interval: u32 = 0 };

fn hand(ctx: *Ctx, comptime numb: u8) !void {
    try ctx.stat.putz(std.fmt.comptimePrint("hand_{d}", .{numb}), "used");
}

// ---- step 0: tools ----
pub fn toolChec(ctx: *Ctx, mode: Mode) anyerror!Outc {
    _ = mode;
    const st = std.Io.Dir.cwd().statFile(ctx.io, ctx.root, .{}) catch return ctxm.failCode(2, "the repo folder cannot be opened", ctx.root, "pass an existing folder with --root");
    if (st.kind != .directory) return ctxm.failCode(2, "the repo path is not a folder", ctx.root, "pass a folder with --root");
    const ver = ctx.gitz("").tool(&.{ ctx.conf.tool.gitz, "--version" }) catch |e| return switch (e) {
        error.Missing => ctxm.fail("git is not installed", "the app pushes with git and found no git program", "install git from https://git-scm.com/downloads, then run the same command again"),
        else => ctxm.fail("git did not start", @errorName(e), "run `git --version` yourself and fix what it reports"),
    };
    if (!ver.okay()) return ctxm.fail("git did not start", ver.err, "run `git --version` yourself and fix what it reports");
    return .{ .done = try std.fmt.allocPrint(ctx.a, "{s} on {s}", .{ ver.text(), @import("os-layer.zig").osName() }) };
}

fn userSeen(ctx: *Ctx, name: []const u8) !?bool {
    if (name.len == 0) return false;
    const r = try api.call(ctx, .GET, try std.mem.concat(ctx.a, u8, &.{ "/users/", try api.enc(ctx.a, name) }), null, false);
    if (r.code == 200) return true;
    if (r.code == 404) return false;
    return null;
}

fn wanted(ctx: *Ctx) []const u8 {
    const saved = ctx.stat.valu("logi");
    return if (saved.len > 0) saved else ctx.conf.acct.logi;
}

// letters, digits and single dashes only, the shape GitHub accepts ----
fn nameClean(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (list.items.len == CF.name_maxz) break;
        if (std.ascii.isAlphanumeric(c)) {
            try list.append(a, std.ascii.toLower(c));
        } else if (list.items.len > 0 and list.items[list.items.len - 1] != '-') try list.append(a, '-');
    }
    return std.mem.trim(u8, list.items, "-");
}

// every character class appears at least once; picks are unbiased ----
fn passMake(ctx: *Ctx, size: u32) ![]u8 {
    const all = comptime PASS_SETS[0] ++ PASS_SETS[1] ++ PASS_SETS[2] ++ PASS_SETS[3];
    const buf = try ctx.a.alloc(u8, size);
    for (buf, 0..) |*c, i| {
        const set: []const u8 = if (i < PASS_SETS.len) PASS_SETS[i] else all;
        const top: u8 = @intCast(256 - (256 % set.len));
        var b: [1]u8 = undefined;
        while (true) {
            try ctx.io.randomSecure(&b);
            if (b[0] < top) break;
        }
        c.* = set[b[0] % set.len];
    }
    // the first four are one per class in order: shuffle so the shape is not fixed ----
    var i: usize = buf.len;
    while (i > 1) : (i -= 1) {
        var b: [1]u8 = undefined;
        const top: u8 = @intCast(256 - (256 % i));
        while (true) {
            try ctx.io.randomSecure(&b);
            if (b[0] < top) break;
        }
        std.mem.swap(u8, &buf[i - 1], &buf[b[0] % i]);
    }
    return buf;
}

fn mailOkay(text: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return false;
    return at > 0 and std.mem.indexOfScalarPos(u8, text, at, '.') != null and std.mem.indexOfAny(u8, text, " \t") == null and text.len <= 254;
}

// ---- step 1: prepare sign-up ----
pub fn signPrep(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const name = wanted(ctx);
    if (name.len > 0) {
        const seen = (try userSeen(ctx, name)) orelse return ctxm.fail("cannot look up the username", "GitHub did not answer 200 or 404", "run the same command again");
        if (seen) {
            try ctx.stat.putz("logi", name);
            return .{ .done = try std.fmt.allocPrint(ctx.a, "account exists: {s}", .{name}) };
        }
    }
    if (mode == .chec) return .{ .wait = "sign-up not prepared" };
    var mail = if (ctx.stat.valu("mail").len > 0) ctx.stat.valu("mail") else ctx.conf.acct.mail;
    while (!mailOkay(mail)) mail = ctx.ask("Your email address: ") orelse return .{ .wait = "email address needed" };
    try ctx.stat.putz("mail", mail);
    var pick = name;
    if (pick.len == 0) {
        const base = try nameClean(ctx.a, if (ctx.conf.sign.name_base.len > 0) ctx.conf.sign.name_base else mail[0..std.mem.indexOfScalar(u8, mail, '@').?]);
        if (base.len == 0) return ctxm.failCode(2, "no username can be built", "the email name has no letters or digits", "set sign.name_base in 00-config.json");
        var i: u32 = 0;
        while (i < ctx.conf.sign.name_trys) : (i += 1) {
            const cand = if (i == 0) base else try std.fmt.allocPrint(ctx.a, "{s}-{d}", .{ base, i });
            const seen = (try userSeen(ctx, cand)) orelse return ctxm.fail("cannot look up the username", "GitHub did not answer 200 or 404", "wait a few minutes (lookups are limited), then run again");
            if (!seen) {
                pick = cand;
                break;
            }
        }
        if (pick.len == 0) return ctxm.failCode(2, "no free username found", "every try was taken", "set sign.name_base in 00-config.json to another name");
    }
    try ctx.stat.putz("logi", pick);
    if ((try ctx.secret(CF.pass_keyz)) == null) try ctx.secretPut(CF.pass_keyz, try passMake(ctx, ctx.conf.sign.pass_size));
    return .{ .done = try std.fmt.allocPrint(ctx.a, "username {s} is free; password vaulted", .{pick}) };
}

fn signSeen(ctx: *Ctx) anyerror!bool {
    return (try userSeen(ctx, ctx.stat.valu("logi"))) orelse false;
}

fn handOver(ctx: *Ctx, label: []const u8, text: []const u8, hide: bool) bool {
    if (!ctx.clip(text, hide)) return false;
    _ = ctx.ask(std.fmt.allocPrint(ctx.a, "   {s} is on the clipboard. Paste it, then press Enter here. ", .{label}) catch return false);
    return true;
}

fn pollOutc(ctx: *Ctx, got: ctxm.Poll, done_note: []const u8, wait_note: []const u8) Outc {
    ctx.clipTick(true);
    return switch (got) {
        .done => .{ .done = done_note },
        .back => .back,
        .stop => .stop,
        .wait => .{ .wait = wait_note },
    };
}

// ---- step 2: sign-up form (hand job 1) ----
pub fn signForm(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (try signSeen(ctx)) return .{ .done = "account exists" };
    if (mode == .chec) return .{ .wait = "sign-up not done" };
    const pass = (try ctx.secret(CF.pass_keyz)) orelse return ctxm.fail("the sign-up password is missing", "step 1 did not finish", "run the same command again");
    try hand(ctx, 1);
    ctx.say("   1. The sign-up page opens. Paste the three values as they come.\n", .{});
    ctx.page(try std.mem.concat(ctx.a, u8, &.{ ctx.conf.http.webz_base, ctx.conf.sign.path_form }));
    const okay = handOver(ctx, "Your email", ctx.stat.valu("mail"), false) and handOver(ctx, "Your password", pass, true) and handOver(ctx, "Your username", ctx.stat.valu("logi"), false);
    if (!okay) {
        ctx.clipTick(true);
        return ctxm.fail("the clipboard is not available", "the password must never be shown on screen, so it travels by clipboard only", "install wl-clipboard or xclip (Linux), or set osiz.clip_copy to true, then run again");
    }
    ctx.say("   2. Press the sign-up button and solve the puzzle. Waiting for the account...\n", .{});
    const got = try ctx.poll(signSeen, "the account must use the username that was on the clipboard; if you chose another, stop (x), set acct.logi in 00-config.json and run again");
    return pollOutc(ctx, got, "account created", "sign-up form not submitted yet");
}

// ---- step 3: email link (hand job 2), proven at step 5 ----
pub fn signMail(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if (std.mem.eql(u8, ctx.stat.valu("mail_veri"), "yes")) return .{ .done = "email verified" };
    if (std.mem.eql(u8, ctx.stat.valu("mail_told"), "yes")) return .{ .done = "link clicked (checked at step 5)" };
    if ((try api.token(ctx)) != null) return .{ .done = "checked at step 5" };
    // an account that already existed (step 1 never asked for an email) has nothing to click; step 5 checks it through the API ----
    if (ctx.stat.valu("mail").len == 0 and ctx.stat.valu("logi").len > 0) return .{ .done = "existing account (email checked at step 5)" };
    if (mode == .chec) return .{ .wait = "email link not clicked" };
    try hand(ctx, 2);
    ctx.say("   1. Open your inbox for {s}.\n   2. Click the link (or type the code) GitHub sent.\n", .{ctx.stat.valu("mail")});
    _ = ctx.ask("   3. Press Enter here when the page says verified. ") orelse return .{ .wait = "email link not clicked" };
    try ctx.stat.putz("mail_told", "yes");
    return .{ .done = "link clicked (checked at step 5)" };
}

fn userRead(ctx: *Ctx) !?User {
    if ((try api.token(ctx)) == null) return null;
    const r = try api.getz(ctx, "/user");
    if (r.code == 401) {
        // a dead token must not block the next login ----
        try ctx.secretDrop(api.TOKE_KEYZ);
        return null;
    }
    if (!r.okay()) return null;
    return api.read(User, ctx, r.body);
}

fn tokeKeep(ctx: *Ctx, tok: []const u8) !Outc {
    try ctx.secretPut(api.TOKE_KEYZ, tok);
    if ((try userRead(ctx)) == null) return ctxm.fail("the new login does not work", "GitHub refused the fresh token", "run the same command again");
    return .{ .done = "token received" };
}

// ---- step 4: login by device code (hand job 3) ----
pub fn authDevi(ctx: *Ctx, mode: Mode) anyerror!Outc {
    if ((try userRead(ctx)) != null) return .{ .done = "logged in" };
    if (mode == .chec) return .{ .wait = "not logged in" };
    if (std.mem.eql(u8, ctx.conf.auth.mode, "gh")) {
        const got = ctx.gitz("").tool(&.{ ctx.conf.tool.ghcl, "auth", "token" }) catch return ctxm.failCode(2, "gh is not available", "auth.mode is gh but the gh program did not run", "install gh and run `gh auth login --web`, or set auth.mode to device");
        if (!got.okay() or got.text().len == 0) return ctxm.failCode(2, "gh is not logged in", "`gh auth token` gave no token", "run `gh auth login --web`, then run the same command again");
        return tokeKeep(ctx, got.text());
    }
    const clie = ctx.conf.auth.clie_iden;
    if (clie.len == 0) return ctxm.failCode(2, "no Client ID for the login", "auth.clie_iden is empty in 00-config.json", "paste the OAuth App's Client ID there (Device Flow enabled), or set auth.mode to gh");
    const r = try api.form(ctx, "/login/device/code", &.{ .{ "client_id", clie }, .{ "scope", ctx.conf.auth.scop } });
    if (!r.okay()) return api.refuse(ctx, r, "GitHub did not start the device login");
    const dev = api.read(Devi, ctx, r.body) orelse return ctxm.fail("GitHub's device login answer is unreadable", "unexpected JSON", "run the same command again");
    if (dev.device_code.len == 0 or dev.user_code.len == 0) return ctxm.fail("GitHub's device login answer is incomplete", "no code in the answer", "check that Device Flow is enabled for the OAuth App");
    ctx.audi.hideAdd(dev.device_code);
    try hand(ctx, 3);
    // never open a page the vendor answer points outside the vendor ----
    const page = try std.mem.concat(ctx.a, u8, &.{ ctx.conf.http.webz_base, ctx.conf.sign.path_devi });
    const copied = ctx.clip(dev.user_code, false);
    ctx.say("   1. Your code: {s}{s}\n", .{ dev.user_code, if (copied) " (on the clipboard)" else "" });
    ctx.page(page);
    ctx.say("   2. Type the code on the page and approve. Waiting...\n", .{});
    var gap: u32 = @max(dev.interval, 1);
    const until = ctx.nowSecs() + @min(if (dev.expires_in == 0) ctx.conf.auth.poll_maxz_secs else dev.expires_in, ctx.conf.auth.poll_maxz_secs);
    while (ctx.nowSecs() < until) {
        ctx.sleep(gap);
        const t = try api.form(ctx, "/login/oauth/access_token", &.{ .{ "client_id", clie }, .{ "device_code", dev.device_code }, .{ "grant_type", CF.gran } });
        const tok = api.read(Toke, ctx, t.body) orelse continue;
        if (tok.access_token.len > 0) return tokeKeep(ctx, tok.access_token);
        if (std.mem.eql(u8, tok.@"error", "authorization_pending")) continue;
        if (std.mem.eql(u8, tok.@"error", "slow_down")) {
            gap = if (tok.interval > 0) tok.interval else gap + CF.slow_secs;
            continue;
        }
        if (std.mem.eql(u8, tok.@"error", "access_denied")) return ctxm.fail("the login was cancelled", "the code page was answered with cancel", "run the same command again and approve");
        if (std.mem.eql(u8, tok.@"error", "expired_token")) break;
        return ctxm.fail("GitHub refused the device login", ctx.audi.redact(tok.@"error"), "check auth.clie_iden and that Device Flow is enabled, then run again");
    }
    return .{ .wait = "the code was not approved in time; run again for a new code" };
}

fn mailSeen(ctx: *Ctx) anyerror!bool {
    const r = try api.getz(ctx, "/user/emails");
    if (!r.okay()) return error.MailRefused;
    const list = api.read([]const Mail, ctx, r.body) orelse return false;
    for (list) |m| if (m.primary and m.verified) return true;
    return false;
}

// ---- step 5: email verified ----
pub fn mailChec(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const seen = mailSeen(ctx) catch |e| {
        if (e != error.MailRefused) return e;
        return api.refuse(ctx, try api.getz(ctx, "/user/emails"), "cannot read the email state (needs the user:email scope)");
    };
    if (seen) {
        try ctx.stat.putz("mail_veri", "yes");
        return .{ .done = "primary email verified" };
    }
    if (mode == .chec) return .{ .wait = "email not verified" };
    try hand(ctx, 2);
    ctx.say("   1. Your email is not verified yet. Click the link GitHub sent.\n", .{});
    ctx.page(try std.mem.concat(ctx.a, u8, &.{ ctx.conf.http.webz_base, CF.path_mail }));
    const got = try ctx.poll(mailSeen, "no mail? press 'Resend verification email' on the page that opened");
    if (got == .done) try ctx.stat.putz("mail_veri", "yes");
    return pollOutc(ctx, got, "primary email verified", "email not verified yet");
}

fn twofSeen(ctx: *Ctx) anyerror!bool {
    const u = (try userRead(ctx)) orelse return false;
    // keep a fresh code on the clipboard while the human is on the page ----
    if (u.two_factor_authentication != true) if (try ctx.secret(CF.totp_keyz)) |key| {
        const code = totp.code(key, ctx.nowSecs()) catch return false;
        if (!std.mem.eql(u8, ctx.stat.valu("totp_last"), &code)) {
            _ = ctx.clip(&code, false);
            try ctx.stat.putz("totp_last", &code);
        }
    };
    return u.two_factor_authentication == true;
}

// ---- step 6: 2FA (hand job 4) ----
pub fn twofSetz(ctx: *Ctx, mode: Mode) anyerror!Outc {
    const u = (try userRead(ctx)) orelse return ctxm.fail("cannot read the account", "no working login", "run the same command again");
    if (u.two_factor_authentication == true) return .{ .done = "2FA is on" };
    if (u.two_factor_authentication == null) return ctxm.fail("cannot see the 2FA state", "the login lacks the read:user scope", "add read:user to auth.scop in 00-config.json, then log in again");
    if (mode == .chec) return .{ .wait = "2FA is off" };
    try hand(ctx, 4);
    ctx.say("   1. On the page choose the authenticator app, then click 'setup key'.\n", .{});
    ctx.page(try std.mem.concat(ctx.a, u8, &.{ ctx.conf.http.webz_base, ctx.conf.sign.path_twof }));
    if ((try ctx.secret(CF.totp_keyz)) == null) {
        while (true) {
            const key = ctx.askHide("   2. Paste the setup key here (hidden), press Enter: ") orelse return .{ .wait = "2FA setup key needed" };
            if (totp.valid(key)) {
                try ctx.secretPut(CF.totp_keyz, key);
                break;
            }
            ctx.say("   that is not a setup key (letters A-Z and digits 2-7). Try again.\n", .{});
        }
    }
    const copied = twofSeen(ctx) catch false;
    _ = copied;
    ctx.say("   3. The 6-digit code is on the clipboard (it renews by itself). Paste it on the page.\n", .{});
    if ((try ctx.secret(CF.reco_keyz)) == null) {
        ctx.say("   4. Copy the recovery codes from the page. Paste them here (hidden), then press Enter on an empty line.\n", .{});
        var list: std.ArrayList(u8) = .empty;
        var n: u32 = 0;
        while (n < CF.reco_maxz) : (n += 1) {
            const line = ctx.askHide("") orelse break;
            if (line.len == 0) break;
            if (list.items.len > 0) try list.append(ctx.a, ' ');
            try list.appendSlice(ctx.a, line);
        }
        if (list.items.len == 0) return .{ .wait = "recovery codes needed" };
        try ctx.secretPut(CF.reco_keyz, list.items);
    }
    const got = try ctx.poll(twofSeen, "finish the page: paste the 6-digit code, save the recovery codes, press the last button");
    return pollOutc(ctx, got, "2FA is on; setup key and recovery codes vaulted", "2FA not turned on yet");
}

// ---- step 7: identity ----
pub fn idenRead(ctx: *Ctx, mode: Mode) anyerror!Outc {
    _ = mode;
    const u = (try userRead(ctx)) orelse return ctxm.fail("cannot read the account", "no working login", "run the same command again");
    if (u.login.len == 0 or u.id == 0) return ctxm.fail("the account answer has no id", "unexpected JSON from GET /user", "run the same command again");
    const nore = try std.fmt.allocPrint(ctx.a, "{d}+{s}@users.noreply.github.com", .{ u.id, u.login });
    try ctx.stat.putz("logi", u.login);
    try ctx.stat.putz("user_iden", try std.fmt.allocPrint(ctx.a, "{d}", .{u.id}));
    try ctx.stat.putz("mail_nore", nore);
    return .{ .done = nore };
}

test "nameClean and mailOkay follow GitHub's shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("cloud-house-dev", try nameClean(a, "Cloud.House__dev"));
    try std.testing.expectEqualStrings("a", try nameClean(a, "--a--"));
    try std.testing.expectEqualStrings("", try nameClean(a, "..."));
    try std.testing.expectEqual(@as(usize, 30), (try nameClean(a, "x" ** 80)).len);
    try std.testing.expect(mailOkay("a@b.co"));
    try std.testing.expect(!mailOkay("a@b"));
    try std.testing.expect(!mailOkay("@b.co"));
    try std.testing.expect(!mailOkay("a b@c.co"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
