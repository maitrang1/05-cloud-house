// =====================================================================
// Des: Typed calls to STS and IAM: who am I, find or make the scoped user, set its policy, mint its access key, find or make the two roles. Every make is preceded by a find. Nothing here deletes.
// Flo: form post > read the XML answer > typed result or ApiFail
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: Aws client, names, policy documents
// Out: account id, key pair, role arns
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const awsz = @import("ap-aws.zig");
const xmlz = @import("ap-xml.zig");

const Aws = awsz.Aws;

const CF = .{ .verIam = "2010-05-08", .verSts = "2011-06-15", .servIam = "iam", .servSts = "sts" };

pub const KeyPair = struct { akid: []const u8, secr: []const u8 };

// one IAM call: Action + Version + extra pairs
fn iamCall(aws: *Aws, action: []const u8, extra: []const [2][]const u8) !awsz.Reply {
    var list: std.ArrayList([2][]const u8) = .empty;
    try list.append(aws.gpa, .{ "Action", action });
    try list.append(aws.gpa, .{ "Version", CF.verIam });
    try list.appendSlice(aws.gpa, extra);
    return aws.form(aws.iam, CF.servIam, aws.iamr, list.items);
}

// the text of a tag, or ApiFail with a clear reason
fn need(aws: *Aws, body: []const u8, tag: []const u8) ![]const u8 {
    return (try xmlz.tagFirst(aws.gpa, body, tag)) orelse {
        aws.last = try std.fmt.allocPrint(aws.gpa, "answer has no <{s}>", .{tag});
        return error.ApiFail;
    };
}

// STS: the account id behind the signing key, null when AWS refuses the key
pub fn stsWho(aws: *Aws) !?[]const u8 {
    const rep = try aws.form(aws.sts, CF.servSts, aws.regi, &.{ .{ "Action", "GetCallerIdentity" }, .{ "Version", CF.verSts } });
    if (!rep.okay()) return null;
    return try need(aws, rep.body, "Account");
}

// true when the IAM user exists
pub fn userGet(aws: *Aws, name: []const u8) !bool {
    const rep = try iamCall(aws, "GetUser", &.{.{ "UserName", name }});
    if (rep.okay()) return true;
    if (awsz.isKind(rep, "NoSuchEntity")) return false;
    return error.ApiFail;
}

// make the user (a conflict means a parallel run made it: fine)
pub fn userMake(aws: *Aws, name: []const u8) !void {
    const rep = try iamCall(aws, "CreateUser", &.{.{ "UserName", name }});
    if (!rep.okay() and !awsz.isKind(rep, "EntityAlreadyExists")) return error.ApiFail;
}

// set (replace) one inline policy on the user
pub fn userPolicy(aws: *Aws, name: []const u8, poli: []const u8, doc: []const u8) !void {
    const rep = try iamCall(aws, "PutUserPolicy", &.{ .{ "UserName", name }, .{ "PolicyName", poli }, .{ "PolicyDocument", doc } });
    if (!rep.okay()) return error.ApiFail;
}

// ids of the user's access keys (never secrets)
pub fn keysList(aws: *Aws, name: []const u8) ![][]u8 {
    const rep = try iamCall(aws, "ListAccessKeys", &.{.{ "UserName", name }});
    if (!rep.okay()) return error.ApiFail;
    return xmlz.tagAll(aws.gpa, rep.body, "AccessKeyId");
}

// mint a key; AWS shows the secret exactly once, the caller must vault it at once
pub fn keyMake(aws: *Aws, name: []const u8) !KeyPair {
    const rep = try iamCall(aws, "CreateAccessKey", &.{.{ "UserName", name }});
    if (!rep.okay()) return error.ApiFail;
    return .{ .akid = try need(aws, rep.body, "AccessKeyId"), .secr = try need(aws, rep.body, "SecretAccessKey") };
}

// arn of the role, null when it does not exist
pub fn roleGet(aws: *Aws, name: []const u8) !?[]const u8 {
    const rep = try iamCall(aws, "GetRole", &.{.{ "RoleName", name }});
    if (rep.okay()) return try need(aws, rep.body, "Arn");
    if (awsz.isKind(rep, "NoSuchEntity")) return null;
    return error.ApiFail;
}

// make the role with its trust document; returns the arn
pub fn roleMake(aws: *Aws, name: []const u8, trust: []const u8) ![]const u8 {
    const rep = try iamCall(aws, "CreateRole", &.{ .{ "RoleName", name }, .{ "AssumeRolePolicyDocument", trust } });
    if (!rep.okay()) return error.ApiFail;
    return need(aws, rep.body, "Arn");
}

// set (replace) one inline policy on the role
pub fn rolePolicy(aws: *Aws, name: []const u8, poli: []const u8, doc: []const u8) !void {
    const rep = try iamCall(aws, "PutRolePolicy", &.{ .{ "RoleName", name }, .{ "PolicyName", poli }, .{ "PolicyDocument", doc } });
    if (!rep.okay()) return error.ApiFail;
}

// the stored inline policy document of a role (url-encoded by AWS), for drift checks
pub fn rolePolicyGet(aws: *Aws, name: []const u8, poli: []const u8) !?[]const u8 {
    const rep = try iamCall(aws, "GetRolePolicy", &.{ .{ "RoleName", name }, .{ "PolicyName", poli } });
    if (rep.okay()) return try need(aws, rep.body, "PolicyDocument");
    if (awsz.isKind(rep, "NoSuchEntity")) return null;
    return error.ApiFail;
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
