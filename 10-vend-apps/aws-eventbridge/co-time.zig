// =====================================================================
// Des: Time text the cloud needs: the HTTP date header (RFC 7231) used when signing a request, and an ISO day for the backup name.
// Flo: unix seconds > calendar fields > fixed-width text
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: unix seconds
// Out: "Thu, 05 Jan 2014 21:31:40 GMT" or "2014-01-05"
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .daysName = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" }, .monsName = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }, .httpSize = 29, .isoSize = 10, .amzSize = 16 };

pub const AmzDate = [CF.amzSize]u8;

pub const HttpDate = [CF.httpSize]u8;
pub const IsoDay = [CF.isoSize]u8;

// seconds since 1970 as an HTTP date (always GMT, fixed width)
pub fn httpDate(secs: i64) HttpDate {
    const epos = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const dayz = epos.getEpochDay();
    const yman = dayz.calculateYearDay();
    const mand = yman.calculateMonthDay();
    const dsec = epos.getDaySeconds();
    var outp: HttpDate = undefined;
    _ = std.fmt.bufPrint(&outp, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ CF.daysName[@intCast(dayz.day % 7)], mand.day_index + 1, CF.monsName[mand.month.numeric() - 1], yman.year, dsec.getHoursIntoDay(), dsec.getMinutesIntoHour(), dsec.getSecondsIntoMinute() }) catch unreachable; // 29 bytes always fit
    return outp;
}

// seconds since 1970 as 20150830T123600Z (the SigV4 date)
pub fn amzDate(secs: i64) AmzDate {
    const epos = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yman = epos.getEpochDay().calculateYearDay();
    const mand = yman.calculateMonthDay();
    const dsec = epos.getDaySeconds();
    var outp: AmzDate = undefined;
    _ = std.fmt.bufPrint(&outp, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{ yman.year, mand.month.numeric(), mand.day_index + 1, dsec.getHoursIntoDay(), dsec.getMinutesIntoHour(), dsec.getSecondsIntoMinute() }) catch unreachable; // 16 bytes always fit
    return outp;
}

// seconds since 1970 as YYYY-MM-DD (UTC)
pub fn isoDay(secs: i64) IsoDay {
    const epos = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(secs, 0)) };
    const yman = epos.getEpochDay().calculateYearDay();
    const mand = yman.calculateMonthDay();
    var outp: IsoDay = undefined;
    _ = std.fmt.bufPrint(&outp, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yman.year, mand.month.numeric(), mand.day_index + 1 }) catch unreachable; // 10 bytes always fit
    return outp;
}

test "dates match the known examples" {
    try std.testing.expectEqualStrings("20140105T213140Z", &amzDate(1388957500));
    // 2014-01-05 21:31:40 UTC = 1388957500
    try std.testing.expectEqualStrings("Sun, 05 Jan 2014 21:31:40 GMT", &httpDate(1388957500));
    try std.testing.expectEqualStrings("2014-01-05", &isoDay(1388957500));
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &httpDate(0));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
