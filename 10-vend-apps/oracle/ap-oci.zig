// =====================================================================
// Des: The Oracle calls the setup needs, as small typed functions: check the user, find or make a compartment, network parts, a VM, and read back its address. Every make is find-first, so a second run changes nothing. No call here ever deletes.
// Flo: build path + JSON > signed call (ap-http) > read the answer into plain values > one error message on failure
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: ids and names from config and state
// Out: ids (ocid text), small structs, or error.OciCall with the reason in Oci.last
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const http = @import("ap-http.zig");

const CF = .{ .lastMaxz = 400, .stateOkay = "ACTIVE", .stateRunn = "RUNNING", .protTcpz = "6", .protIcmp = "1", .destAnyz = "0.0.0.0/0" };

pub const Erro = error{ OciCall, OciShape, OutOfMemory };

pub const Val = std.json.Value;

// ids of a VCN and the default parts it comes with
pub const Vcn = struct { iden: []const u8, rout: []const u8, secl: []const u8 };

// one TCP ingress rule as config states it
pub const Rule = struct { port: u32, cidr: []const u8, desc: []const u8 };

pub const Oci = struct {
    gpa: std.mem.Allocator, // arena expected: answers are not freed one by one
    http: *http.Http,
    iden: []const u8, // identity base url, region filled in
    iaas: []const u8, // compute + network base url, region filled in
    vers: []const u8,
    last: []const u8 = "", // reason of the latest failed call

    fn url(self: *Oci, base: []const u8, rest: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}{s}", .{ base, self.vers, rest });
    }

    // one call; 2xx returns the parsed JSON, anything else keeps the reason in `last`
    fn call(self: *Oci, meth: std.http.Method, base: []const u8, rest: []const u8, body: ?[]const u8) Erro!Val {
        const resp = self.http.call(.{ .meth = meth, .urlz = try self.url(base, rest), .body = body }) catch |erro| {
            self.last = std.fmt.allocPrint(self.gpa, "{s} {s}: {s}", .{ @tagName(meth), rest, @errorName(erro) }) catch "call failed";
            return error.OciCall;
        };
        if (!resp.okay()) {
            self.last = self.reason(resp, meth, rest);
            return error.OciCall;
        }
        if (resp.body.len == 0) return .null;
        return std.json.parseFromSliceLeaky(Val, self.gpa, resp.body, .{}) catch {
            self.last = "answer is not JSON";
            return error.OciShape;
        };
    }

    // "HTTP 404 NotAuthorizedOrNotFound: message" from Oracle's error body
    fn reason(self: *Oci, resp: http.Resp, meth: std.http.Method, rest: []const u8) []const u8 {
        var code: []const u8 = "";
        var mess: []const u8 = "";
        if (std.json.parseFromSliceLeaky(Val, self.gpa, resp.body, .{})) |val| {
            if (val == .object) {
                code = strOf(val, "code") orelse "";
                mess = strOf(val, "message") orelse "";
            }
        } else |_| {}
        const cut = mess[0..@min(mess.len, CF.lastMaxz)];
        return std.fmt.allocPrint(self.gpa, "{s} {s}: HTTP {d} {s} {s}", .{ @tagName(meth), rest, resp.code, code, cut }) catch "call failed";
    }

    fn get(self: *Oci, base: []const u8, rest: []const u8) Erro!Val {
        return self.call(.GET, base, rest, null);
    }

    fn post(self: *Oci, base: []const u8, rest: []const u8, bodyVal: anytype) Erro!Val {
        const body = try std.json.Stringify.valueAlloc(self.gpa, bodyVal, .{});
        return self.call(.POST, base, rest, body);
    }

    fn put(self: *Oci, base: []const u8, rest: []const u8, bodyVal: anytype) Erro!Val {
        const body = try std.json.Stringify.valueAlloc(self.gpa, bodyVal, .{});
        return self.call(.PUT, base, rest, body);
    }

    // query part: ?k=v&k=v with percent-encoded values
    fn query(self: *Oci, path: []const u8, pair: []const [2][]const u8) ![]u8 {
        var outp: std.ArrayList(u8) = .empty;
        try outp.appendSlice(self.gpa, path);
        for (pair, 0..) |item, indx| {
            try outp.append(self.gpa, if (indx == 0) '?' else '&');
            try outp.appendSlice(self.gpa, item[0]);
            try outp.append(self.gpa, '=');
            try outp.appendSlice(self.gpa, try http.urlzEnco(self.gpa, item[1]));
        }
        return outp.items;
    }

    // ---- identity ----

    // true when the signed call to our own user works (the "key is live" check)
    pub fn userLive(self: *Oci, user: []const u8) bool {
        const rest = std.fmt.allocPrint(self.gpa, "/users/{s}", .{user}) catch return false;
        _ = self.get(self.iden, rest) catch return false;
        return true;
    }

    // ocid of an ACTIVE compartment with this name under the tenancy, or null
    pub fn compFind(self: *Oci, tena: []const u8, name: []const u8) Erro!?[]const u8 {
        const val = try self.get(self.iden, try self.query("/compartments", &.{ .{ "compartmentId", tena }, .{ "name", name }, .{ "lifecycleState", CF.stateOkay } }));
        return firstId(val, "name", name);
    }

    // create a compartment and return its ocid (caller found none first)
    pub fn compMake(self: *Oci, tena: []const u8, name: []const u8, desc: []const u8) Erro![]const u8 {
        const val = try self.post(self.iden, "/compartments", .{ .compartmentId = tena, .name = name, .description = desc });
        return strOf(val, "id") orelse error.OciShape;
    }

    // state text of a compartment (CREATING, ACTIVE, ...)
    pub fn compState(self: *Oci, iden: []const u8) Erro![]const u8 {
        const val = try self.get(self.iden, try std.fmt.allocPrint(self.gpa, "/compartments/{s}", .{iden}));
        return strOf(val, "lifecycleState") orelse error.OciShape;
    }

    // names of the availability domains
    pub fn adList(self: *Oci, comp: []const u8) Erro![]const []const u8 {
        const val = try self.get(self.iden, try self.query("/availabilityDomains", &.{.{ "compartmentId", comp }}));
        if (val != .array) return error.OciShape;
        var outp: std.ArrayList([]const u8) = .empty;
        for (val.array.items) |item| try outp.append(self.gpa, strOf(item, "name") orelse return error.OciShape);
        return outp.items;
    }

    // ---- network ----

    pub fn vcnFind(self: *Oci, comp: []const u8, name: []const u8) Erro!?Vcn {
        const val = try self.get(self.iaas, try self.query("/vcns", &.{ .{ "compartmentId", comp }, .{ "displayName", name } }));
        const item = firstItem(val, "displayName", name) orelse return null;
        return vcnOf(item);
    }

    pub fn vcnMake(self: *Oci, comp: []const u8, name: []const u8, cidr: []const u8) Erro!Vcn {
        const val = try self.post(self.iaas, "/vcns", .{ .cidrBlock = cidr, .compartmentId = comp, .displayName = name });
        return vcnOf(val) orelse error.OciShape;
    }

    pub fn igwFind(self: *Oci, comp: []const u8, vcn: []const u8, name: []const u8) Erro!?[]const u8 {
        const val = try self.get(self.iaas, try self.query("/internetGateways", &.{ .{ "compartmentId", comp }, .{ "vcnId", vcn }, .{ "displayName", name } }));
        return firstId(val, "displayName", name);
    }

    pub fn igwMake(self: *Oci, comp: []const u8, vcn: []const u8, name: []const u8) Erro![]const u8 {
        const val = try self.post(self.iaas, "/internetGateways", .{ .compartmentId = comp, .vcnId = vcn, .isEnabled = true, .displayName = name });
        return strOf(val, "id") orelse error.OciShape;
    }

    // make sure the route table sends 0.0.0.0/0 to the gateway; existing rules stay. Returns true when it changed something
    pub fn routeEnsure(self: *Oci, rout: []const u8, igw: []const u8) Erro!bool {
        const path = try std.fmt.allocPrint(self.gpa, "/routeTables/{s}", .{rout});
        const val = try self.get(self.iaas, path);
        const rules = (if (val == .object) val.object.get("routeRules") else null) orelse return error.OciShape;
        if (rules != .array) return error.OciShape;
        for (rules.array.items) |item| if (std.mem.eql(u8, strOf(item, "networkEntityId") orelse "", igw) and std.mem.eql(u8, strOf(item, "destination") orelse "", CF.destAnyz)) return false;
        var list: std.ArrayList(Val) = .empty;
        try list.appendSlice(self.gpa, rules.array.items);
        var one = std.json.ObjectMap.empty;
        try one.put(self.gpa, "destination", .{ .string = CF.destAnyz });
        try one.put(self.gpa, "destinationType", .{ .string = "CIDR_BLOCK" });
        try one.put(self.gpa, "networkEntityId", .{ .string = igw });
        try list.append(self.gpa, .{ .object = one });
        _ = try self.put(self.iaas, path, .{ .routeRules = list.items });
        return true;
    }

    // list the tcp ingress rules of a security list as config-style rules; extra counts every other rule that is not Oracle's default ICMP
    pub fn secRead(self: *Oci, secl: []const u8) Erro!struct { tcp: []const Rule, other: u32 } {
        const val = try self.get(self.iaas, try std.fmt.allocPrint(self.gpa, "/securityLists/{s}", .{secl}));
        const ingr = (if (val == .object) val.object.get("ingressSecurityRules") else null) orelse return error.OciShape;
        if (ingr != .array) return error.OciShape;
        var tcp: std.ArrayList(Rule) = .empty;
        var other: u32 = 0;
        for (ingr.array.items) |item| {
            const prot = strOf(item, "protocol") orelse "";
            if (std.mem.eql(u8, prot, CF.protIcmp)) continue; // Oracle's default ICMP rules
            const opts = if (item == .object) item.object.get("tcpOptions") else null;
            const rang = if (opts) |o| (if (o == .object) o.object.get("destinationPortRange") else null) else null;
            if (std.mem.eql(u8, prot, CF.protTcpz) and rang != null and rang.? == .object) {
                const minn = intOf(rang.?, "min") orelse 0;
                const maxx = intOf(rang.?, "max") orelse 0;
                if (minn == maxx) {
                    try tcp.append(self.gpa, .{ .port = @intCast(minn), .cidr = strOf(item, "source") orelse "", .desc = strOf(item, "description") orelse "" });
                    continue;
                }
            }
            other += 1;
        }
        return .{ .tcp = tcp.items, .other = other };
    }

    // add the missing tcp ingress rules; existing rules and all egress rules stay. Returns how many it added
    pub fn secEnsure(self: *Oci, secl: []const u8, want: []const Rule) Erro!u32 {
        const path = try std.fmt.allocPrint(self.gpa, "/securityLists/{s}", .{secl});
        const val = try self.get(self.iaas, path);
        const ingr = (if (val == .object) val.object.get("ingressSecurityRules") else null) orelse return error.OciShape;
        const egre = (if (val == .object) val.object.get("egressSecurityRules") else null) orelse return error.OciShape;
        if (ingr != .array or egre != .array) return error.OciShape;
        const have = try self.secRead(secl);
        var list: std.ArrayList(Val) = .empty;
        try list.appendSlice(self.gpa, ingr.array.items);
        var added: u32 = 0;
        for (want) |rule| {
            var found = false;
            for (have.tcp) |item| if (item.port == rule.port and std.mem.eql(u8, item.cidr, rule.cidr)) {
                found = true;
            };
            if (found) continue;
            var rng = std.json.ObjectMap.empty;
            try rng.put(self.gpa, "min", .{ .integer = rule.port });
            try rng.put(self.gpa, "max", .{ .integer = rule.port });
            var tcpo = std.json.ObjectMap.empty;
            try tcpo.put(self.gpa, "destinationPortRange", .{ .object = rng });
            var one = std.json.ObjectMap.empty;
            try one.put(self.gpa, "protocol", .{ .string = CF.protTcpz });
            try one.put(self.gpa, "source", .{ .string = rule.cidr });
            try one.put(self.gpa, "isStateless", .{ .bool = false });
            try one.put(self.gpa, "description", .{ .string = rule.desc });
            try one.put(self.gpa, "tcpOptions", .{ .object = tcpo });
            try list.append(self.gpa, .{ .object = one });
            added += 1;
        }
        if (added == 0) return 0;
        _ = try self.put(self.iaas, path, .{ .ingressSecurityRules = list.items, .egressSecurityRules = egre.array.items });
        return added;
    }

    pub fn subnFind(self: *Oci, comp: []const u8, vcn: []const u8, name: []const u8) Erro!?[]const u8 {
        const val = try self.get(self.iaas, try self.query("/subnets", &.{ .{ "compartmentId", comp }, .{ "vcnId", vcn }, .{ "displayName", name } }));
        return firstId(val, "displayName", name);
    }

    pub fn subnMake(self: *Oci, comp: []const u8, vcn: []const u8, name: []const u8, cidr: []const u8, rout: []const u8, secl: []const u8) Erro![]const u8 {
        const val = try self.post(self.iaas, "/subnets", .{ .cidrBlock = cidr, .compartmentId = comp, .vcnId = vcn, .displayName = name, .routeTableId = rout, .securityListIds = &[_][]const u8{secl}, .prohibitPublicIpOnVnic = false });
        return strOf(val, "id") orelse error.OciShape;
    }

    // ---- compute ----

    // newest image of this OS + version for the shape, or null
    pub fn imgFind(self: *Oci, comp: []const u8, os: []const u8, ver: []const u8, shap: []const u8) Erro!?[]const u8 {
        const val = try self.get(self.iaas, try self.query("/images", &.{ .{ "compartmentId", comp }, .{ "operatingSystem", os }, .{ "operatingSystemVersion", ver }, .{ "shape", shap }, .{ "sortBy", "TIMECREATED" }, .{ "sortOrder", "DESC" } }));
        if (val != .array or val.array.items.len == 0) return null;
        return strOf(val.array.items[0], "id");
    }

    // true when the shape is offered in this availability domain
    pub fn shapOffer(self: *Oci, comp: []const u8, ad: []const u8, shap: []const u8) Erro!bool {
        const val = try self.get(self.iaas, try self.query("/shapes", &.{ .{ "compartmentId", comp }, .{ "availabilityDomain", ad } }));
        if (val != .array) return error.OciShape;
        for (val.array.items) |item| if (std.mem.eql(u8, strOf(item, "shape") orelse "", shap)) return true;
        return false;
    }

    // live (not TERMINATED) instances in the compartment
    pub fn instList(self: *Oci, comp: []const u8) Erro![]const Val {
        const val = try self.get(self.iaas, try self.query("/instances", &.{.{ "compartmentId", comp }}));
        if (val != .array) return error.OciShape;
        var outp: std.ArrayList(Val) = .empty;
        for (val.array.items) |item| if (!std.mem.eql(u8, strOf(item, "lifecycleState") orelse "", "TERMINATED")) try outp.append(self.gpa, item);
        return outp.items;
    }

    pub fn instFind(self: *Oci, comp: []const u8, name: []const u8) Erro!?[]const u8 {
        for (try self.instList(comp)) |item| if (std.mem.eql(u8, strOf(item, "displayName") orelse "", name)) return strOf(item, "id");
        return null;
    }

    // what LaunchInstance needs; ssh is the one-line public key, data the cloud-init script (plain text)
    pub const Launch = struct { comp: []const u8, ad: []const u8, shap: []const u8, name: []const u8, imag: []const u8, subn: []const u8, boot: u32, ssh: []const u8, data: []const u8, ocpu: u32 = 0, memg: u32 = 0 };

    pub fn instLaunch(self: *Oci, lau: Launch) Erro![]const u8 {
        const enc = std.base64.standard.Encoder;
        const b64 = try self.gpa.alloc(u8, enc.calcSize(lau.data.len));
        _ = enc.encode(b64, lau.data);
        const Spec = struct { ocpus: u32, memoryInGBs: u32 };
        const flex: ?Spec = if (lau.ocpu > 0) .{ .ocpus = lau.ocpu, .memoryInGBs = lau.memg } else null;
        const val = try self.post(self.iaas, "/instances", .{
            .availabilityDomain = lau.ad,
            .compartmentId = lau.comp,
            .shape = lau.shap,
            .shapeConfig = flex,
            .displayName = lau.name,
            .createVnicDetails = .{ .subnetId = lau.subn, .assignPublicIp = true },
            .metadata = .{ .ssh_authorized_keys = lau.ssh, .user_data = b64 },
            .sourceDetails = .{ .sourceType = "image", .imageId = lau.imag, .bootVolumeSizeInGBs = lau.boot },
        });
        return strOf(val, "id") orelse error.OciShape;
    }

    pub fn instState(self: *Oci, iden: []const u8) Erro![]const u8 {
        const val = try self.get(self.iaas, try std.fmt.allocPrint(self.gpa, "/instances/{s}", .{iden}));
        return strOf(val, "lifecycleState") orelse error.OciShape;
    }

    // public ip of the first vnic of the instance, or null when none yet
    pub fn instIp(self: *Oci, comp: []const u8, iden: []const u8) Erro!?[]const u8 {
        const att = try self.get(self.iaas, try self.query("/vnicAttachments", &.{ .{ "compartmentId", comp }, .{ "instanceId", iden } }));
        if (att != .array or att.array.items.len == 0) return null;
        const vnic = strOf(att.array.items[0], "vnicId") orelse return null;
        const val = try self.get(self.iaas, try std.fmt.allocPrint(self.gpa, "/vnics/{s}", .{vnic}));
        const ipzz = strOf(val, "publicIp") orelse return null;
        return if (ipzz.len == 0) null else ipzz;
    }
};

// ---- small JSON readers ----

pub fn strOf(val: Val, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const item = val.object.get(key) orelse return null;
    return if (item == .string) item.string else null;
}

pub fn intOf(val: Val, key: []const u8) ?i64 {
    if (val != .object) return null;
    const item = val.object.get(key) orelse return null;
    return if (item == .integer) item.integer else null;
}

// first array item whose `key` equals `want`
fn firstItem(val: Val, key: []const u8, want: []const u8) ?Val {
    if (val != .array) return null;
    for (val.array.items) |item| if (std.mem.eql(u8, strOf(item, key) orelse "", want)) return item;
    return null;
}

fn firstId(val: Val, key: []const u8, want: []const u8) ?[]const u8 {
    const item = firstItem(val, key, want) orelse return null;
    return strOf(item, "id");
}

fn vcnOf(val: Val) ?Vcn {
    return .{ .iden = strOf(val, "id") orelse return null, .rout = strOf(val, "defaultRouteTableId") orelse return null, .secl = strOf(val, "defaultSecurityListId") orelse return null };
}

test "json readers pick fields and skip the wrong ones" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const val = try std.json.parseFromSliceLeaky(Val, aren.allocator(), "[{\"id\":\"a\",\"displayName\":\"x\",\"n\":3},{\"id\":\"b\",\"displayName\":\"y\"}]", .{});
    try std.testing.expectEqualStrings("b", firstId(val, "displayName", "y").?);
    try std.testing.expect(firstId(val, "displayName", "z") == null);
    try std.testing.expectEqual(@as(i64, 3), intOf(val.array.items[0], "n").?);
    try std.testing.expect(strOf(val.array.items[0], "n") == null);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
