// =====================================================================
// Des: Small date helper for the usage report. Turns a clock time into a YYYY-MM-DD day, finds the start of the month, and prints RFC 3339 times.
// Flo: seconds > day number > add or compare > YYYY-MM-DD text
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: unix seconds, a day count, or a YYYY-MM-DD text
// Out: YYYY-MM-DD text or a number of days
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .secsDayz = 86400, .dateSize = 10, .yearMinz = 1970, .yearMaxz = 9999 };

pub const Date = [CF.dateSize]u8;

// civil date to days since 1970-01-01 (Hinnant)
fn daysFrom(year: i64, mont: i64, dayz: i64) i64 {
    const yadj = if (mont <= 2) year - 1 else year;
    const eraz = @divFloor(yadj, 400);
    const yoez = yadj - eraz * 400;
    const madj = if (mont > 2) mont - 3 else mont + 9;
    const doyz = @divFloor(153 * madj + 2, 5) + dayz - 1;
    const doez = yoez * 365 + @divFloor(yoez, 4) - @divFloor(yoez, 100) + doyz;
    return eraz * 146097 + doez - 719468;
}

// days since 1970-01-01 to YYYY-MM-DD
fn dateFrom(days: i64) Date {
    const zday = days + 719468;
    const eraz = @divFloor(zday, 146097);
    const doez = zday - eraz * 146097;
    const yoez = @divFloor(doez - @divFloor(doez, 1460) + @divFloor(doez, 36524) - @divFloor(doez, 146096), 365);
    const doyz = doez - (365 * yoez + @divFloor(yoez, 4) - @divFloor(yoez, 100));
    const mpzz = @divFloor(5 * doyz + 2, 153);
    const dayz = doyz - @divFloor(153 * mpzz + 2, 5) + 1;
    const mont = if (mpzz < 10) mpzz + 3 else mpzz - 9;
    const year = yoez + eraz * 400 + @as(i64, if (mont <= 2) 1 else 0);
    var outp: Date = undefined;
    _ = std.fmt.bufPrint(&outp, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(std.math.clamp(year, 0, CF.yearMaxz))), @as(u64, @intCast(mont)), @as(u64, @intCast(dayz)) }) catch unreachable; // 10 bytes always fit
    return outp;
}

// today plus N days, as YYYY-MM-DD (UTC)
pub fn datePlus(secs: i64, plus: u32) Date {
    return dateFrom(@divFloor(secs, CF.secsDayz) + plus);
}

// civil year and month of a unix second (UTC)
pub fn yearMonth(secs: i64) struct { year: i64, mont: i64 } {
    const dtxt = dateFrom(@divFloor(secs, CF.secsDayz));
    return .{ .year = std.fmt.parseInt(i64, dtxt[0..4], 10) catch CF.yearMinz, .mont = std.fmt.parseInt(i64, dtxt[5..7], 10) catch 1 };
}

// unix second of the first day of the month that holds secs (UTC 00:00:00)
pub fn monthStart(secs: i64) i64 {
    const ym = yearMonth(secs);
    return daysFrom(ym.year, ym.mont, 1) * CF.secsDayz;
}

// RFC 3339 UTC text of a unix second, e.g. 2026-11-01T00:00:00Z
pub fn rfc3339(gpa: std.mem.Allocator, secs: i64) ![]u8 {
    const dtxt = dateFrom(@divFloor(secs, CF.secsDayz));
    const rest: u64 = @intCast(@mod(secs, CF.secsDayz));
    return std.fmt.allocPrint(gpa, "{s}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ dtxt, rest / 3600, (rest % 3600) / 60, rest % 60 });
}

// parse YYYY-MM-DD into a day number
pub fn datePars(text: []const u8) !i64 {
    if (text.len < CF.dateSize or text[4] != '-' or text[7] != '-') return error.DateForm;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return error.DateForm;
    const mont = std.fmt.parseInt(i64, text[5..7], 10) catch return error.DateForm;
    const dayz = std.fmt.parseInt(i64, text[8..10], 10) catch return error.DateForm;
    if (year < CF.yearMinz or mont < 1 or mont > 12 or dayz < 1 or dayz > 31) return error.DateForm;
    return daysFrom(year, mont, dayz);
}

// whole days from now until the expiry day (negative = expired)
pub fn daysLeft(expi: []const u8, secs: i64) !i64 {
    return (try datePars(expi)) - @divFloor(secs, CF.secsDayz);
}

// true when the token is inside the rotation window
pub fn rotaDuez(expi: []const u8, secs: i64, rota: u32) !bool {
    return (try daysLeft(expi, secs)) <= rota;
}

test "date round trip and leap years" {
    try std.testing.expectEqualStrings("1970-01-01", &datePlus(0, 0));
    try std.testing.expectEqualStrings("2026-11-12", &datePlus(1794441600, 0));
    try std.testing.expectEqualStrings("2027-02-10", &datePlus(1794441600, 90));
    try std.testing.expectEqualStrings("2028-02-29", &dateFrom(try datePars("2028-02-29")));
    try std.testing.expectEqual(@as(i64, 1), (try datePars("2028-03-01")) - (try datePars("2028-02-29")));
}

test "month start and rfc3339" {
    try std.testing.expectEqual(@as(i64, 1793491200), monthStart(1794441600 + 7 * 86400));
    const text = try rfc3339(std.testing.allocator, 1794441600 + 3661);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2026-11-12T01:01:01Z", text);
}

test "token expiry math" {
    const nowz: i64 = 1794441600 + 3600;
    try std.testing.expectEqual(@as(i64, 90), try daysLeft("2027-02-10", nowz));
    try std.testing.expectEqual(@as(i64, -1), try daysLeft("2026-11-11", nowz));
    try std.testing.expect(!try rotaDuez("2027-02-10", nowz, 14));
    try std.testing.expect(try rotaDuez("2026-11-26", nowz, 14));
    try std.testing.expect(!try rotaDuez("2026-11-27", nowz, 14));
    try std.testing.expectError(error.DateForm, datePars("2026/11/12"));
    try std.testing.expectError(error.DateForm, datePars("2026-13-01"));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
