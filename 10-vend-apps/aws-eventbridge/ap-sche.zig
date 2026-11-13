// =====================================================================
// Des: Typed calls to EventBridge Scheduler: the schedule group and the one tick schedule (read, create, replace). Replace is how pause and resume work. Nothing here deletes.
// Flo: REST JSON call > parse the JSON answer > typed result or ApiFail
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Aws client, group and schedule names, tick settings
// Out: arns and the schedule as AWS holds it
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const awsz = @import("ap-aws.zig");

const Aws = awsz.Aws;

const CF = .{ .pathGrup = "/schedule-groups/", .pathSche = "/schedules/", .qureGrup = "?groupName=", .winMode = "OFF" };

// what the app asks a schedule to be
pub const Want = struct { grup: []const u8, expr: []const u8, enab: bool, bus: []const u8, role: []const u8, input: []const u8, srcz: []const u8, dtyp: []const u8, ages: u32, retr: u32 };

// what AWS holds
pub const Have = struct { arn: []const u8, state: []const u8, expr: []const u8, bus: []const u8, role: []const u8, input: []const u8, srcz: []const u8, dtyp: []const u8 };

const GetR = struct {
    Arn: []const u8 = "",
    State: []const u8 = "",
    ScheduleExpression: []const u8 = "",
    Target: struct { Arn: []const u8 = "", RoleArn: []const u8 = "", Input: []const u8 = "", EventBridgeParameters: struct { DetailType: []const u8 = "", Source: []const u8 = "" } = .{} } = .{},
};

fn path(aws: *Aws, base: []const u8, name: []const u8, quer: []const u8) ![]u8 {
    return std.fmt.allocPrint(aws.gpa, "{s}{s}{s}", .{ base, name, quer });
}

// true when the group exists
pub fn grupGet(aws: *Aws, name: []const u8) !bool {
    const rep = try aws.rest(.GET, try path(aws, CF.pathGrup, name, ""), "");
    if (rep.okay()) return true;
    if (rep.code == 404) return false;
    return error.ApiFail;
}

pub fn grupMake(aws: *Aws, name: []const u8) !void {
    const rep = try aws.rest(.POST, try path(aws, CF.pathGrup, name, ""), "{}");
    if (!rep.okay() and rep.code != 409) return error.ApiFail;
}

// the schedule as AWS holds it, null when absent
pub fn scheGet(aws: *Aws, grup: []const u8, name: []const u8) !?Have {
    const quer = try std.mem.concat(aws.gpa, u8, &.{ CF.qureGrup, grup });
    const rep = try aws.rest(.GET, try path(aws, CF.pathSche, name, quer), "");
    if (rep.code == 404) return null;
    if (!rep.okay()) return error.ApiFail;
    const res = std.json.parseFromSliceLeaky(GetR, aws.gpa, rep.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        aws.last = "schedule answer is not the JSON we expect";
        return error.ApiFail;
    };
    return .{ .arn = res.Arn, .state = res.State, .expr = res.ScheduleExpression, .bus = res.Target.Arn, .role = res.Target.RoleArn, .input = res.Target.Input, .srcz = res.Target.EventBridgeParameters.Source, .dtyp = res.Target.EventBridgeParameters.DetailType };
}

// the request body, shared by create and replace
fn bodyOf(aws: *Aws, want: Want) ![]u8 {
    return std.json.Stringify.valueAlloc(aws.gpa, .{
        .GroupName = want.grup,
        .ScheduleExpression = want.expr,
        .FlexibleTimeWindow = .{ .Mode = CF.winMode },
        .State = if (want.enab) "ENABLED" else "DISABLED",
        .Target = .{ .Arn = want.bus, .RoleArn = want.role, .Input = want.input, .EventBridgeParameters = .{ .DetailType = want.dtyp, .Source = want.srcz }, .RetryPolicy = .{ .MaximumEventAgeInSeconds = want.ages, .MaximumRetryAttempts = want.retr } },
    }, .{});
}

// create the schedule
pub fn scheMake(aws: *Aws, name: []const u8, want: Want) !void {
    const rep = try aws.rest(.POST, try path(aws, CF.pathSche, name, ""), try bodyOf(aws, want));
    if (!rep.okay()) return error.ApiFail;
}

// replace the schedule (UpdateSchedule overwrites every field, so send them all)
pub fn scheSet(aws: *Aws, name: []const u8, want: Want) !void {
    const rep = try aws.rest(.PUT, try path(aws, CF.pathSche, name, ""), try bodyOf(aws, want));
    if (!rep.okay()) return error.ApiFail;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
