// =====================================================================
// Des: Typed calls to EventBridge (bus, connection, API destination, rule, targets) and to Budgets. Every make is preceded by a find, and puts are replace-style so a rerun changes nothing. Nothing here deletes.
// Flo: JSON 1.1 call with a target header > parse the JSON answer > typed result or ApiFail
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Aws client, names, arns, tick settings
// Out: arns and states
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const awsz = @import("ap-aws.zig");

const Aws = awsz.Aws;

const CF = .{ .tgtEven = "AWSEvents.", .tgtBudg = "AWSBudgetServiceGateway.", .servEven = "events", .servBudg = "budgets", .targId = "tick", .authKey = "API_KEY", .budgType = "COST", .budgTime = "MONTHLY", .notiType = "ACTUAL", .notiOper = "GREATER_THAN", .subsType = "EMAIL", .threPct = "PERCENTAGE" };

// small answer shapes (unknown fields ignored)
const Arnz = struct { Arn: []const u8 = "" };
const ConnR = struct { ConnectionArn: []const u8 = "", ConnectionState: []const u8 = "" };
const DestR = struct { ApiDestinationArn: []const u8 = "", ApiDestinationState: []const u8 = "", InvocationEndpoint: []const u8 = "", HttpMethod: []const u8 = "" };
const RuleR = struct { Arn: []const u8 = "", State: []const u8 = "", EventPattern: []const u8 = "" };
const Targ = struct { Id: []const u8 = "", Arn: []const u8 = "", RoleArn: []const u8 = "", InputPath: []const u8 = "" };
const TargL = struct { Targets: []const Targ = &.{} };
const FailR = struct { FailedEntryCount: u32 = 0 };

pub const Conn = struct { arn: []const u8, state: []const u8 };
pub const Dest = struct { arn: []const u8, state: []const u8, urlz: []const u8, meth: []const u8 };
pub const Rule = struct { arn: []const u8, state: []const u8, patt: []const u8 };

// one Events call with a JSON body
fn evCall(aws: *Aws, name: []const u8, body: []const u8) !awsz.Reply {
    const targ = try std.mem.concat(aws.gpa, u8, &.{ CF.tgtEven, name });
    return aws.jsn(aws.even, CF.servEven, aws.regi, targ, body);
}

fn jsonOf(aws: *Aws, comptime T: type, body: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, aws.gpa, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        aws.last = "answer is not the JSON we expect";
        return error.ApiFail;
    };
}

fn bodyOf(aws: *Aws, valu: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(aws.gpa, valu, .{});
}

// arn of the bus, null when it does not exist
pub fn busGet(aws: *Aws, name: []const u8) !?[]const u8 {
    const rep = try evCall(aws, "DescribeEventBus", try bodyOf(aws, .{ .Name = name }));
    if (rep.okay()) return (try jsonOf(aws, Arnz, rep.body)).Arn;
    if (awsz.isKind(rep, "ResourceNotFoundException")) return null;
    return error.ApiFail;
}

pub fn connGet(aws: *Aws, name: []const u8) !?Conn {
    const rep = try evCall(aws, "DescribeConnection", try bodyOf(aws, .{ .Name = name }));
    if (rep.okay()) {
        const res = try jsonOf(aws, ConnR, rep.body);
        return .{ .arn = res.ConnectionArn, .state = res.ConnectionState };
    }
    if (awsz.isKind(rep, "ResourceNotFoundException")) return null;
    return error.ApiFail;
}

// make the API-key connection; the secret is only sent here and never stored by us in the clear
pub fn connMake(aws: *Aws, name: []const u8, keyn: []const u8, keyv: []const u8) !Conn {
    const body = try bodyOf(aws, .{ .Name = name, .AuthorizationType = CF.authKey, .AuthParameters = .{ .ApiKeyAuthParameters = .{ .ApiKeyName = keyn, .ApiKeyValue = keyv } } });
    const rep = try evCall(aws, "CreateConnection", body);
    if (!rep.okay()) return error.ApiFail;
    const res = try jsonOf(aws, ConnR, rep.body);
    return .{ .arn = res.ConnectionArn, .state = res.ConnectionState };
}

pub fn destGet(aws: *Aws, name: []const u8) !?Dest {
    const rep = try evCall(aws, "DescribeApiDestination", try bodyOf(aws, .{ .Name = name }));
    if (rep.okay()) {
        const res = try jsonOf(aws, DestR, rep.body);
        return .{ .arn = res.ApiDestinationArn, .state = res.ApiDestinationState, .urlz = res.InvocationEndpoint, .meth = res.HttpMethod };
    }
    if (awsz.isKind(rep, "ResourceNotFoundException")) return null;
    return error.ApiFail;
}

pub fn destMake(aws: *Aws, name: []const u8, conn: []const u8, meth: []const u8, urlz: []const u8, rlim: u32) !Dest {
    const body = try bodyOf(aws, .{ .Name = name, .ConnectionArn = conn, .HttpMethod = meth, .InvocationEndpoint = urlz, .InvocationRateLimitPerSecond = rlim });
    const rep = try evCall(aws, "CreateApiDestination", body);
    if (!rep.okay()) return error.ApiFail;
    const res = try jsonOf(aws, DestR, rep.body);
    return .{ .arn = res.ApiDestinationArn, .state = res.ApiDestinationState, .urlz = urlz, .meth = meth };
}

// replace the API destination's endpoint, method and rate (UpdateApiDestination overwrites those fields)
pub fn destSet(aws: *Aws, name: []const u8, conn: []const u8, meth: []const u8, urlz: []const u8, rlim: u32) !void {
    const body = try bodyOf(aws, .{ .Name = name, .ConnectionArn = conn, .HttpMethod = meth, .InvocationEndpoint = urlz, .InvocationRateLimitPerSecond = rlim });
    const rep = try evCall(aws, "UpdateApiDestination", body);
    if (!rep.okay()) return error.ApiFail;
}

pub fn ruleGet(aws: *Aws, name: []const u8, bus: []const u8) !?Rule {
    const rep = try evCall(aws, "DescribeRule", try bodyOf(aws, .{ .Name = name, .EventBusName = bus }));
    if (rep.okay()) {
        const res = try jsonOf(aws, RuleR, rep.body);
        return .{ .arn = res.Arn, .state = res.State, .patt = res.EventPattern };
    }
    if (awsz.isKind(rep, "ResourceNotFoundException")) return null;
    return error.ApiFail;
}

// create or replace the rule (PutRule is replace-style)
pub fn rulePut(aws: *Aws, name: []const u8, bus: []const u8, patt: []const u8, enab: bool) ![]const u8 {
    const rep = try evCall(aws, "PutRule", try bodyOf(aws, .{ .Name = name, .EventBusName = bus, .EventPattern = patt, .State = if (enab) "ENABLED" else "DISABLED" }));
    if (!rep.okay()) return error.ApiFail;
    const res = try jsonOf(aws, struct { RuleArn: []const u8 = "" }, rep.body);
    return res.RuleArn;
}

// the targets of a rule (id, arn, role)
pub fn targList(aws: *Aws, name: []const u8, bus: []const u8) ![]const Targ {
    const rep = try evCall(aws, "ListTargetsByRule", try bodyOf(aws, .{ .Rule = name, .EventBusName = bus }));
    if (!rep.okay()) return error.ApiFail;
    return (try jsonOf(aws, TargL, rep.body)).Targets;
}

// set the one target: destination arn + role, the event detail as the payload, retry policy
pub fn targPut(aws: *Aws, name: []const u8, bus: []const u8, dest: []const u8, role: []const u8, ages: u32, retr: u32) !void {
    const body = try bodyOf(aws, .{ .Rule = name, .EventBusName = bus, .Targets = .{.{ .Id = CF.targId, .Arn = dest, .RoleArn = role, .InputPath = "$.detail", .RetryPolicy = .{ .MaximumEventAgeInSeconds = ages, .MaximumRetryAttempts = retr } }} });
    const rep = try evCall(aws, "PutTargets", body);
    if (!rep.okay()) return error.ApiFail;
    if ((try jsonOf(aws, FailR, rep.body)).FailedEntryCount > 0) {
        aws.last = "PutTargets reported a failed entry";
        return error.ApiFail;
    }
}

// the target id the app owns
pub fn targId() []const u8 {
    return CF.targId;
}

// ---- Budgets ----

fn buCall(aws: *Aws, name: []const u8, body: []const u8) !awsz.Reply {
    const targ = try std.mem.concat(aws.gpa, u8, &.{ CF.tgtBudg, name });
    return aws.jsn(aws.budg, CF.servBudg, aws.budr, targ, body);
}

// true when the budget exists
pub fn budgGet(aws: *Aws, acct: []const u8, name: []const u8) !bool {
    const rep = try buCall(aws, "DescribeBudget", try bodyOf(aws, .{ .AccountId = acct, .BudgetName = name }));
    if (rep.okay()) return true;
    if (awsz.isKind(rep, "NotFoundException")) return false;
    return error.ApiFail;
}

// monthly cost budget with one email alert at a percent of the limit
pub fn budgMake(aws: *Aws, acct: []const u8, name: []const u8, limi: []const u8, unit: []const u8, warn: u32, mail: []const u8) !void {
    const body = try bodyOf(aws, .{
        .AccountId = acct,
        .Budget = .{ .BudgetName = name, .BudgetType = CF.budgType, .TimeUnit = CF.budgTime, .BudgetLimit = .{ .Amount = limi, .Unit = unit } },
        .NotificationsWithSubscribers = .{.{ .Notification = .{ .NotificationType = CF.notiType, .ComparisonOperator = CF.notiOper, .Threshold = warn, .ThresholdType = CF.threPct }, .Subscribers = .{.{ .SubscriptionType = CF.subsType, .Address = mail }} }},
    });
    const rep = try buCall(aws, "CreateBudget", body);
    if (!rep.okay() and !awsz.isKind(rep, "DuplicateRecordException")) return error.ApiFail;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
