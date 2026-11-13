// =====================================================================
// Des: The shared AWS caller. Knows the five service addresses and builds the three request styles AWS uses here: form posts (IAM, STS), JSON 1.1 with a target header (Events, Budgets) and REST JSON (Scheduler). Reads the error kind out of any failed reply.
// Flo: pick base url + signing scope > build body > signed call through ap-http > reply with status, body and error kind
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: service addresses, region names, call parameters
// Out: Reply{ code, body, kind }; Aws.last holds the last failure text
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("ap-http.zig");
const xmlz = @import("ap-xml.zig");

pub const CF = .{ .ctypForm = "application/x-www-form-urlencoded; charset=utf-8", .ctypJ11 = "application/x-amz-json-1.1", .ctypJson = "application/json", .kindMaxz = 80, .messMaxz = 200 };

pub const Erro = error{ApiFail};

// one answer: status, raw body, and the AWS error kind ("" when the call worked)
pub const Reply = struct {
    code: u16,
    body: []const u8,
    kind: []const u8,

    pub fn okay(self: Reply) bool {
        return self.code >= 200 and self.code < 300;
    }
};

pub const Aws = struct {
    gpa: std.mem.Allocator, // arena
    http: *http.Http,
    sts: []const u8 = "",
    iam: []const u8 = "",
    budg: []const u8 = "",
    even: []const u8 = "",
    sche: []const u8 = "",
    regi: []const u8 = "",
    iamr: []const u8 = "",
    budr: []const u8 = "",
    last: []const u8 = "",

    // form post: IAM and STS (params already hold Action and Version)
    pub fn form(self: *Aws, base: []const u8, serv: []const u8, regi: []const u8, pair: []const [2][]const u8) !Reply {
        var bodz: std.ArrayList(u8) = .empty;
        for (pair, 0..) |item, indx| {
            if (indx > 0) try bodz.append(self.gpa, '&');
            const valu = try http.urlzEnco(self.gpa, item[1]);
            try bodz.print(self.gpa, "{s}={s}", .{ item[0], valu });
        }
        const urlz = try std.fmt.allocPrint(self.gpa, "{s}/", .{base});
        return self.send(.{ .meth = .POST, .urlz = urlz, .body = bodz.items, .serv = serv, .regi = regi, .ctyp = CF.ctypForm });
    }

    // JSON 1.1 call with a target header: Events and Budgets
    pub fn jsn(self: *Aws, base: []const u8, serv: []const u8, regi: []const u8, targ: []const u8, body: []const u8) !Reply {
        const urlz = try std.fmt.allocPrint(self.gpa, "{s}/", .{base});
        return self.send(.{ .meth = .POST, .urlz = urlz, .body = body, .serv = serv, .regi = regi, .ctyp = CF.ctypJ11, .amzt = targ });
    }

    // REST JSON call: Scheduler (path may carry a ?query that is already canonical)
    pub fn rest(self: *Aws, meth: std.http.Method, path: []const u8, body: []const u8) !Reply {
        const urlz = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ self.sche, path });
        const hasz = meth.requestHasBody();
        return self.send(.{ .meth = meth, .urlz = urlz, .body = if (hasz) body else "", .serv = "scheduler", .regi = self.regi, .ctyp = if (hasz) CF.ctypJson else "" });
    }

    fn send(self: *Aws, requ: http.Requ) !Reply {
        const resp = try self.http.call(requ);
        const kind: []const u8 = if (resp.okay()) "" else try self.errKind(resp.code, resp.body);
        if (!resp.okay()) self.last = try std.fmt.allocPrint(self.gpa, "{d} {s}: {s}", .{ resp.code, kind, self.errMess(resp.body) });
        return .{ .code = resp.code, .body = resp.body, .kind = kind };
    }

    // error kind from XML <Code>, JSON __type / code, or the status for REST
    fn errKind(self: *Aws, code: u16, body: []const u8) ![]const u8 {
        if (try xmlz.tagFirst(self.gpa, body, "Code")) |text| return text;
        if (std.mem.indexOf(u8, body, "\"__type\"")) |pos| {
            const tail = body[pos + "\"__type\"".len ..];
            const open = std.mem.indexOfScalar(u8, tail, '"') orelse return statKind(code);
            const clos = std.mem.indexOfScalarPos(u8, tail, open + 1, '"') orelse return statKind(code);
            const full = tail[open + 1 .. clos];
            const hash = std.mem.lastIndexOfScalar(u8, full, '#');
            return try self.gpa.dupe(u8, if (hash) |idx| full[idx + 1 ..] else full);
        }
        return statKind(code);
    }

    // short message for the failure line
    fn errMess(self: *Aws, body: []const u8) []const u8 {
        _ = self;
        const keys = [_][]const u8{ "<Message>", "\"message\":\"", "\"Message\":\"" };
        for (keys) |key| if (std.mem.indexOf(u8, body, key)) |pos| {
            const tail = body[pos + key.len ..];
            const stop = std.mem.indexOfAny(u8, tail, "<\"") orelse tail.len;
            return tail[0..@min(stop, CF.messMaxz)];
        };
        return body[0..@min(body.len, CF.messMaxz)];
    }
};

fn statKind(code: u16) []const u8 {
    return switch (code) {
        404 => "NotFound",
        409 => "Conflict",
        403 => "AccessDenied",
        401 => "Unauthorized",
        429 => "Throttled",
        else => "Error",
    };
}

// true when the reply is this AWS error kind
pub fn isKind(rep: Reply, kind: []const u8) bool {
    return std.mem.eql(u8, rep.kind, kind);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
