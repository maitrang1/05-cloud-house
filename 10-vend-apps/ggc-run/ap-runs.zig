// =====================================================================
// Des: Talks to Cloud Run: reads the service, makes or patches it from one spec, tells if the live service drifted from the spec, and sets who may call it.
// Flo: GET service > compare with spec > POST (new) or PATCH (drift) > wait for the operation > read url and readiness
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: api base, project id, region, service name, Spec
// Out: service JSON, url, ready flag, drift flag
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const gcp = @import("ap-gcp.zig");
const pol = @import("ap-policy.zig");

pub const Erro = error{RunsHttp};

const CF = .{ .roleInvo = "roles/run.invoker", .memPubl = "allUsers", .condOkay = "CONDITION_SUCCEEDED" };

// what the service must look like (all values come from config)
pub const Spec = struct { image: []const u8, sacc: []const u8, mini: u32, maxi: u32, cpuz: []const u8, memo: []const u8, idle: bool, conc: u32, time: []const u8, ingr: []const u8, port: u32 };

// resource name: projects/P/locations/R/services/S
pub fn svcName(a: std.mem.Allocator, proj: []const u8, regi: []const u8, serv: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "projects/{s}/locations/{s}/services/{s}", .{ proj, regi, serv });
}

// the live service, or null when it does not exist
pub fn getz(g: *gcp.Gcp, base: []const u8, name: []const u8) !?gcp.Reply {
    const rep = try g.call(.GET, try std.fmt.allocPrint(g.a, "{s}/v2/{s}", .{ base, name }), null);
    if (rep.code == 404) return null;
    if (!rep.okay()) return error.RunsHttp;
    return rep;
}

// the first container of a service
fn cont0(val: std.json.Value) std.json.Value {
    const arr = gcp.obj(gcp.obj(val, "template"), "containers");
    return if (arr == .array and arr.array.items.len > 0) arr.array.items[0] else .null;
}

// true when the live service differs from the spec in any field we manage
pub fn drift(val: std.json.Value, spec: Spec) bool {
    const tmpl = gcp.obj(val, "template");
    const scal = gcp.obj(tmpl, "scaling");
    const cont = cont0(val);
    const idle = gcp.obj(gcp.obj(cont, "resources"), "cpuIdle");
    const limi = gcp.obj(gcp.obj(cont, "resources"), "limits");
    if (!std.mem.eql(u8, gcp.str(gcp.obj(cont, "image")), spec.image)) return true;
    if (!std.mem.eql(u8, gcp.str(gcp.obj(tmpl, "serviceAccount")), spec.sacc)) return true;
    if (gcp.int(gcp.obj(scal, "minInstanceCount")) != spec.mini or gcp.int(gcp.obj(scal, "maxInstanceCount")) != spec.maxi) return true;
    if (idle != .bool or idle.bool != spec.idle) return true;
    if (!std.mem.eql(u8, gcp.str(gcp.obj(limi, "cpu")), spec.cpuz) or !std.mem.eql(u8, gcp.str(gcp.obj(limi, "memory")), spec.memo)) return true;
    if (gcp.int(gcp.obj(tmpl, "maxInstanceRequestConcurrency")) != spec.conc) return true;
    if (!std.mem.eql(u8, gcp.str(gcp.obj(tmpl, "timeout")), spec.time)) return true;
    return !std.mem.eql(u8, gcp.str(gcp.obj(val, "ingress")), spec.ingr);
}

// create (exists false) or patch (exists true) the service and wait until the operation ends
pub fn deploy(g: *gcp.Gcp, base: []const u8, proj: []const u8, regi: []const u8, serv: []const u8, spec: Spec, exists: bool) !void {
    const Port = struct { containerPort: u32 };
    const Cont = struct { image: []const u8, ports: []const Port, resources: struct { limits: struct { cpu: []const u8, memory: []const u8 }, cpuIdle: bool } };
    const Body = struct { ingress: []const u8, template: struct { serviceAccount: []const u8, timeout: []const u8, maxInstanceRequestConcurrency: u32, scaling: struct { minInstanceCount: u32, maxInstanceCount: u32 }, containers: []const Cont } };
    const ports = [_]Port{.{ .containerPort = spec.port }};
    const conts = [_]Cont{.{ .image = spec.image, .ports = &ports, .resources = .{ .limits = .{ .cpu = spec.cpuz, .memory = spec.memo }, .cpuIdle = spec.idle } }};
    const body = try std.json.Stringify.valueAlloc(g.a, Body{ .ingress = spec.ingr, .template = .{ .serviceAccount = spec.sacc, .timeout = spec.time, .maxInstanceRequestConcurrency = spec.conc, .scaling = .{ .minInstanceCount = spec.mini, .maxInstanceCount = spec.maxi }, .containers = &conts } }, .{});
    const name = try svcName(g.a, proj, regi, serv);
    const rep = if (exists)
        try g.call(.PATCH, try std.fmt.allocPrint(g.a, "{s}/v2/{s}", .{ base, name }), body)
    else
        try g.call(.POST, try std.fmt.allocPrint(g.a, "{s}/v2/projects/{s}/locations/{s}/services?serviceId={s}", .{ base, proj, regi, serv }), body);
    if (!rep.okay()) return error.RunsHttp;
    try g.lroOf(try std.fmt.allocPrint(g.a, "{s}/v2", .{base}), rep);
}

// the public url of the service
pub fn uri(val: std.json.Value) []const u8 {
    return gcp.str(gcp.obj(val, "uri"));
}

// true when Cloud Run says the latest revision is serving
pub fn ready(val: std.json.Value) bool {
    return std.mem.eql(u8, gcp.str(gcp.obj(gcp.obj(val, "terminalCondition"), "state")), CF.condOkay);
}

// where the invoker policy of this service lives
fn wher(g: *gcp.Gcp, base: []const u8, name: []const u8) !pol.Where {
    return .{ .get_meth = .GET, .get_url = try std.fmt.allocPrint(g.a, "{s}/v2/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{ base, name }), .get_body = null, .set_url = try std.fmt.allocPrint(g.a, "{s}/v2/{s}:setIamPolicy", .{ base, name }) };
}

// let anyone call the service (the scheduler cannot sign requests); true when it changed
pub fn publSet(g: *gcp.Gcp, base: []const u8, name: []const u8) !bool {
    return pol.edit(g, try wher(g, base, name), CF.roleInvo, CF.memPubl, true);
}

// take public access away again; true when it changed
pub fn publDrop(g: *gcp.Gcp, base: []const u8, name: []const u8) !bool {
    return pol.edit(g, try wher(g, base, name), CF.roleInvo, CF.memPubl, false);
}

test "drift sees each managed field" {
    var aren = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aren.deinit();
    const text =
        \\{"ingress":"INGRESS_TRAFFIC_ALL","template":{"serviceAccount":"s@p.iam.gserviceaccount.com","timeout":"30s","maxInstanceRequestConcurrency":80,"scaling":{"minInstanceCount":0,"maxInstanceCount":1},"containers":[{"image":"img:1","resources":{"limits":{"cpu":"1","memory":"256Mi"},"cpuIdle":true}}]}}
    ;
    const val = try std.json.parseFromSliceLeaky(std.json.Value, aren.allocator(), text, .{});
    var spec = Spec{ .image = "img:1", .sacc = "s@p.iam.gserviceaccount.com", .mini = 0, .maxi = 1, .cpuz = "1", .memo = "256Mi", .idle = true, .conc = 80, .time = "30s", .ingr = "INGRESS_TRAFFIC_ALL", .port = 8080 };
    try std.testing.expect(!drift(val, spec));
    spec.image = "img:2";
    try std.testing.expect(drift(val, spec));
    spec.image = "img:1";
    spec.maxi = 2;
    try std.testing.expect(drift(val, spec));
    spec.maxi = 1;
    spec.idle = false;
    try std.testing.expect(drift(val, spec));
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
