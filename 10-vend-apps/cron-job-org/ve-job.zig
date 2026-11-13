// =====================================================================
// Des: Step actions for the tick job: find the tick URL and make the secret, create or repair the one job, verify it from its history, write the handoff file. Each action checks first and only changes what differs. No action can delete anything.
// Flo: tick: url + vaulted secret > sync: job by id or title > create / patch drift > verify: history > final: handoff file
// Inp: Ctx
// Out: Outc per action
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cron-job-org && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const ctxm = @import("co-ctx.zig");
const engi = @import("co-engine.zig");
const conf = @import("co-cfg.zig");
const date = @import("co-date.zig");
const cron = @import("ap-cron.zig");
const rwha = @import("rw-hand.zig");
const fail = @import("ve-fail.zig");

const Ctx = ctxm.Ctx;
const Outc = engi.Outc;

const CF = .{ .keyJob = "jobid", .keyHash = "tick_sha", .keyLast = "last_tick", .hashLen = 16, .msecSecs = 1000, .typeHead = "Content-Type", .schedTxt = "every minute (settings jobz)" };

// lowercase hex of bytes
fn hexzMake(gpa: std.mem.Allocator, byte: []const u8) ![]u8 {
    const outp = try gpa.alloc(u8, byte.len * 2);
    for (byte, 0..) |item, indx| _ = std.fmt.bufPrint(outp[indx * 2 ..][0..2], "{x:0>2}", .{item}) catch unreachable; // 2 bytes always fit
    return outp;
}

// first 16 hex chars of the secret's sha256: tells a changed secret without keeping the secret
fn secHash(ctx: *Ctx) ![]u8 {
    var dige: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ctx.tickSec, &dige, .{});
    const full = try hexzMake(ctx.a, &dige);
    return full[0..CF.hashLen];
}

// tick URL (settings, else the Trigger layer's handoff file) and the tick secret (vault, made once)
pub fn tickReso(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    var urlz: []const u8 = cfg.tick.urlz;
    if (urlz.len == 0) {
        const path = try std.fs.path.join(ctx.a, &.{ ctx.root, cfg.tick.from });
        urlz = rwha.tickRead(ctx.io, ctx.a, path, cfg.tick.fiel) catch return .{ .fail = .{ .what = "no tick URL", .why = try std.fmt.allocPrint(ctx.a, "tick.urlz is empty and {s} has no usable '{s}'", .{ path, cfg.tick.fiel }), .fix = "run the Trigger layer app first (ggc-run), or set tick.urlz" } };
    }
    if (!conf.baseOkay(urlz)) return .{ .fail = .{ .what = "tick URL is not https", .why = "the secret header would travel in clear text", .fix = "use an https:// tick URL" } };
    const vlt = try ctx.vault();
    var fresh = false;
    if (vlt.getz(cfg.vaul.keyt) == null) {
        const raw = try ctx.a.alloc(u8, cfg.tick.seca);
        ctx.io.random(raw);
        try vlt.putz(cfg.vaul.keyt, try hexzMake(ctx.a, raw));
        fresh = true;
    }
    ctx.tickUrl = urlz;
    ctx.tickSec = vlt.getz(cfg.vaul.keyt).?;
    ctx.au.hideAdd(ctx.a, ctx.tickSec);
    return .{ .done = try std.fmt.allocPrint(ctx.a, "tick url {s}; secret {s} in the vault", .{ urlz, if (fresh) "made" else "kept" }) };
}

// the job the settings ask for
fn wantBuild(ctx: *Ctx) !cron.Want {
    const cfg = ctx.conf;
    const jobz = cfg.jobz;
    var heads: std.ArrayList(cron.Head) = .empty;
    if (jobz.body.len != 0) try heads.append(ctx.a, .{ .name = CF.typeHead, .valu = jobz.ctyp });
    try heads.append(ctx.a, .{ .name = cfg.tick.head, .valu = ctx.tickSec, .secr = true });
    return .{ .url = ctx.tickUrl, .title = jobz.titl, .enabled = jobz.enab, .save = jobz.save, .tmoz = jobz.tmoz, .redi = jobz.redi, .meth = jobz.meth, .tzon = jobz.tzon, .mins = jobz.mins, .hour = jobz.hour, .mday = jobz.mday, .mont = jobz.mont, .wday = jobz.wday, .nfail = cfg.noti.fail, .nfcnt = cfg.noti.fcnt, .nsucc = cfg.noti.succ, .ndisa = cfg.noti.disa, .nmode = cfg.noti.mode, .heads = try heads.toOwnedSlice(ctx.a), .body = jobz.body };
}

// group names for the done line
fn groupText(ctx: *Ctx, grup: []const cron.Group) ![]u8 {
    var outp: std.ArrayList(u8) = .empty;
    for (grup, 0..) |item, indx| {
        if (indx != 0) try outp.appendSlice(ctx.a, ", ");
        try outp.appendSlice(ctx.a, @tagName(item));
    }
    return outp.toOwnedSlice(ctx.a);
}

// create the job if missing, repair it if it differs
pub fn jobSync(ctx: *Ctx) anyerror!Outc {
    if (!try ctx.keyLoad()) return .{ .fail = .{ .what = "no API key", .why = "the key step has not run", .fix = "re-run from the start", .code = 4 } };
    if (ctx.tickUrl.len == 0) return .{ .fail = .{ .what = "no tick URL", .why = "the tick step has not run", .fix = "re-run from the start" } };
    const want = try wantBuild(ctx);
    const hash = try secHash(ctx);
    var iden = ctx.st.valu(CF.keyJob);
    var det: std.json.Value = .null;
    if (iden.len != 0) {
        const rep = ctx.cron.get(iden) catch |erro| return fail.callFail(ctx, erro, "read the tick job");
        if (rep.code == 404) {
            iden = "";
            try ctx.st.putz(CF.keyJob, "");
        } else if (!rep.okay()) return fail.replFail(ctx, rep, "read the tick job") else det = cron.detail(rep);
    }
    if (iden.len == 0) {
        const lst = ctx.cron.list() catch |erro| return fail.callFail(ctx, erro, "list the jobs");
        if (!lst.okay()) return fail.replFail(ctx, lst, "list the jobs");
        const fnd = try cron.titleFind(ctx.a, lst, want.title);
        if (fnd.coun > 1) return .{ .fail = .{ .what = "more than one job has the tick title", .why = try std.fmt.allocPrint(ctx.a, "{d} jobs are called '{s}' and the app never deletes", .{ fnd.coun, want.title }), .fix = "remove the extra ones in the Console, or change jobz.titl" } };
        if (fnd.coun == 0) {
            const body = try cron.jobJson(ctx.a, want, null);
            const made = ctx.cron.create(body) catch |erro| return fail.callFail(ctx, erro, "create the tick job");
            if (!made.rep.okay() or made.iden.len == 0) return fail.replFail(ctx, made.rep, "create the tick job");
            try ctx.st.putz(CF.keyJob, made.iden);
            try ctx.st.putz(CF.keyHash, hash);
            try ctx.st.save(ctx.io);
            return .{ .done = try std.fmt.allocPrint(ctx.a, "created job {s}", .{made.iden}) };
        }
        iden = fnd.iden;
        try ctx.st.putz(CF.keyJob, iden);
        const rep = ctx.cron.get(iden) catch |erro| return fail.callFail(ctx, erro, "read the tick job");
        if (!rep.okay()) return fail.replFail(ctx, rep, "read the tick job");
        det = cron.detail(rep);
    }
    const same = std.mem.eql(u8, ctx.st.valu(CF.keyHash), hash);
    const grup = try cron.drift(ctx.a, want, det, same);
    if (grup.len == 0) {
        try ctx.st.save(ctx.io);
        return .{ .done = try std.fmt.allocPrint(ctx.a, "job {s} matches the settings", .{iden}) };
    }
    const rep = ctx.cron.patch(iden, try cron.jobJson(ctx.a, want, grup)) catch |erro| return fail.callFail(ctx, erro, "repair the tick job");
    if (!rep.okay()) return fail.replFail(ctx, rep, "repair the tick job");
    try ctx.st.putz(CF.keyHash, hash);
    try ctx.st.save(ctx.io);
    return .{ .done = try std.fmt.allocPrint(ctx.a, "job {s} repaired ({s})", .{ iden, try groupText(ctx, grup) }) };
}

// true when a status code is in veri.okay
fn codeOkay(ctx: *Ctx, code: i64) bool {
    for (ctx.conf.veri.okay) |item| if (item == code) return true;
    return false;
}

// time text from seconds
fn timeText(ctx: *Ctx, secs: i64) []const u8 {
    return date.rfc3339(ctx.a, secs) catch "?";
}

// read the job history: a good tick, a bad tick, or the next one due
pub fn jobVeri(ctx: *Ctx) anyerror!Outc {
    const iden = ctx.st.valu(CF.keyJob);
    if (iden.len == 0) return .{ .fail = .{ .what = "no job id", .why = "the job step did not finish", .fix = "re-run" } };
    if (!ctx.conf.jobz.enab) return .{ .skip = "settings keep the job disabled (jobz.enab=false)" };
    var tryz: u32 = 0;
    while (true) {
        const rep = ctx.cron.history(iden) catch |erro| return fail.callFail(ctx, erro, "read the job history");
        if (!rep.okay()) return fail.replFail(ctx, rep, "read the job history");
        const hl = cron.historyLast(rep);
        if (hl.last.seen) {
            const stamp = timeText(ctx, hl.last.date);
            try ctx.st.putz(CF.keyLast, stamp);
            if (hl.last.stat == cron.status_okay and codeOkay(ctx, hl.last.code)) return .{ .done = try std.fmt.allocPrint(ctx.a, "last tick OK (HTTP {d}) at {s}", .{ hl.last.code, stamp }) };
            return .{ .skip = try std.fmt.allocPrint(ctx.a, "last tick at {s} was not OK (HTTP {d}, {s}): check the tick URL and secret on the Trigger side", .{ stamp, hl.last.code, hl.last.text }) };
        }
        tryz += 1;
        if (tryz >= ctx.conf.veri.tries) {
            const nxt: []const u8 = if (hl.next != 0) timeText(ctx, hl.next) else "soon";
            return .{ .skip = try std.fmt.allocPrint(ctx.a, "no tick seen yet; the first is due {s}; run status in a few minutes", .{nxt}) };
        }
        ctx.say("   no tick yet, looking again in {d}s\n", .{ctx.conf.veri.gap});
        std.Io.sleep(ctx.io, .fromMilliseconds(@as(i64, ctx.conf.veri.gap) * CF.msecSecs), .awake) catch return error.Canceled;
    }
}

// write the handoff file; the report line comes from the engine
pub fn finaChec(ctx: *Ctx) anyerror!Outc {
    const cfg = ctx.conf;
    const iden = ctx.st.valu(CF.keyJob);
    if (iden.len == 0) return .{ .fail = .{ .what = "no job id", .why = "the job step did not finish", .fix = "re-run" } };
    const path = try std.fs.path.join(ctx.a, &.{ ctx.root, cfg.data.hand });
    const row: rwha.Row = .{ .job_id = iden, .title = cfg.jobz.titl, .tick_url = ctx.tickUrl, .schedule = CF.schedTxt, .secret_head = cfg.tick.head, .secret_key = cfg.vaul.keyt };
    const changed = try rwha.write(ctx.io, ctx.a, path, row);
    return .{ .done = try std.fmt.allocPrint(ctx.a, "job {s}; handoff file {s}", .{ iden, if (changed) "written" else "unchanged" }) };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
