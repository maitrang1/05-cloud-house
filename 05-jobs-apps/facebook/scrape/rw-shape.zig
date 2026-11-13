// Row, Cust, Vendor shapes + hash. Schemas in defs/*.json; these types are the strict validator.
const std = @import("std");
const util = @import("co-util.zig");
const ctx_mod = @import("co-ctx.zig");

pub const Source = enum { public, private };

pub const Row = struct {
    cust_id: []const u8,
    source: Source,
    key: []const u8,
    kind: []const u8,
    fetch: i64,
    hash: []const u8,
    data: std.json.Value,
    expires: i64 = 0, // unix ms; 0 = none. Own-Page rows carry one (terms). Not part of the hash.
    personal: bool = false, // holds names, messages or comments
};

pub const Target = struct { kind: []const u8, url: []const u8 };

pub const Cust = struct {
    cust_id: []const u8,
    consent: bool = false,
    consent_at: i64 = 0,
    retention_days: u32 = 0,
    targets: []const Target = &.{}, // market lane: what to read (kind + public url)
    pages: []const []const u8 = &.{}, // own lane: connected Page ids
    webhook_url: []const u8 = "",
    daily_cap: u32 = 0,
    vendors_allowed: bool = true,
    own_enabled: bool = false,
};

pub const Auth = enum { query, header, bearer, basic, body };

pub const VendorDef = struct {
    id: []const u8,
    name: []const u8 = "",
    base: []const u8,
    method: []const u8 = "GET",
    auth: Auth,
    auth_name: []const u8 = "",
    key_env: []const u8,
    url_param: []const u8 = "url",
    extra: []const u8 = "",
    reply: []const u8 = "raw",
    credit_header: []const u8 = "",
    cost_default: u32 = 1,
    budget: u32 = 0,
    on: bool = true,
    verified: bool = false,
    kinds: std.json.ArrayHashMap([]const u8) = .{}, // kind -> base url override (one vendor, many endpoints)
};

pub const VendorFile = struct { note: []const u8 = "", vendors: []const VendorDef = &.{} };

pub const ShapeErr = error{ BadJson, BadRow, OutOfMemory };

const strict: std.json.ParseOptions = .{ .ignore_unknown_fields = false };

pub fn parseRow(arena: std.mem.Allocator, text: []const u8) ShapeErr!Row {
    const r = std.json.parseFromSliceLeaky(Row, arena, text, strict) catch return ShapeErr.BadJson;
    if (!ctx_mod.validId(r.cust_id) or r.key.len == 0 or r.key.len > 512 or r.kind.len == 0 or r.kind.len > 40 or r.hash.len != 64) return ShapeErr.BadRow;
    for (r.hash) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return ShapeErr.BadRow;
    if (r.data != .object) return ShapeErr.BadRow;
    return r;
}

pub fn parseCust(arena: std.mem.Allocator, text: []const u8) ShapeErr!Cust {
    const c = std.json.parseFromSliceLeaky(Cust, arena, text, strict) catch return ShapeErr.BadJson;
    if (!ctx_mod.validId(c.cust_id)) return ShapeErr.BadRow;
    return c;
}

pub fn parseVendors(arena: std.mem.Allocator, text: []const u8, mock: bool) ShapeErr!VendorFile {
    const v = std.json.parseFromSliceLeaky(VendorFile, arena, text, strict) catch return ShapeErr.BadJson;
    for (v.vendors) |d| {
        if (d.id.len == 0 or d.key_env.len == 0) return ShapeErr.BadRow;
        if (!std.mem.startsWith(u8, d.base, "https://") and !(mock and std.mem.startsWith(u8, d.base, "http://127.0.0.1"))) return ShapeErr.BadRow;
    }
    return v;
}

// copy only the named keys of a JSON object into a new object Value (whitelist: unknown fields never reach a row)
pub fn pick(a: std.mem.Allocator, obj: std.json.Value, keys: []const []const u8) !std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(a);
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try jw.beginObject();
    if (obj == .object) for (keys) |k| if (obj.object.get(k)) |v| {
        try jw.objectField(k);
        try jw.write(v);
    };
    try jw.endObject();
    return std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{ .allocate = .alloc_always });
}

pub fn strOf(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const x = v.object.get(key) orelse return "";
    return if (x == .string) x.string else "";
}

// hash of the data text (canonical = our own stringify of the Value)
pub fn dataHash(alloc: std.mem.Allocator, data: std.json.Value) ![64]u8 {
    const t = try std.json.Stringify.valueAlloc(alloc, data, .{});
    defer alloc.free(t);
    return util.sha256Hex(t);
}

pub fn withTerms(r: Row, expires: i64, personal: bool) Row {
    var x = r;
    x.expires = expires;
    x.personal = personal;
    return x;
}

pub fn rowLine(alloc: std.mem.Allocator, r: Row) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, r, .{});
}

// build a row from parts; hash computed here, so a row can never carry a wrong hash
pub fn makeRow(alloc: std.mem.Allocator, cust: []const u8, src: Source, key: []const u8, kind: []const u8, fetch: i64, data: std.json.Value) !Row {
    const h = try dataHash(alloc, data);
    return .{ .cust_id = cust, .source = src, .key = key, .kind = kind, .fetch = fetch, .hash = try alloc.dupe(u8, &h), .data = data };
}

// ---- tests: every doc example validates against the strict types ----
fn exampleOf(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const t = try util.readAll(arena, std.testing.io, path, 64 * 1024);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{});
    const ex = v.object.get("examples").?.array.items[0];
    return std.json.Stringify.valueAlloc(arena, ex, .{});
}

test "schema examples validate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseRow(a, try exampleOf(a, "df-scrape-row.json"));
    try std.testing.expectEqualStrings("page", r.kind);
    const c = try parseCust(a, try exampleOf(a, "df-scrape-cust.json"));
    try std.testing.expect(c.consent);
    const vt = try util.readAll(a, std.testing.io, "df-scrape-vendors.json", 64 * 1024);
    const vf = try parseVendors(a, vt, false);
    try std.testing.expectError(ShapeErr.BadRow, parseVendors(a, "{\"vendors\":[{\"id\":\"x\",\"base\":\"http://evil/\",\"auth\":\"query\",\"key_env\":\"K\"}]}", false));
    try std.testing.expectEqual(@as(usize, 3), vf.vendors.len);
}

test "bad rows are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = "0" ** 64;
    try std.testing.expectError(ShapeErr.BadJson, parseRow(a, "{\"cust_id\":\"a\",\"extra\":1}"));
    try std.testing.expectError(ShapeErr.BadRow, parseRow(a, "{\"cust_id\":\"../x\",\"source\":\"public\",\"key\":\"k\",\"kind\":\"k\",\"fetch\":1,\"hash\":\"" ++ h ++ "\",\"data\":{}}"));
    try std.testing.expectError(ShapeErr.BadRow, parseRow(a, "{\"cust_id\":\"a\",\"source\":\"public\",\"key\":\"k\",\"kind\":\"k\",\"fetch\":1,\"hash\":\"abc\",\"data\":{}}"));
    try std.testing.expectError(ShapeErr.BadRow, parseRow(a, "{\"cust_id\":\"a\",\"source\":\"public\",\"key\":\"k\",\"kind\":\"k\",\"fetch\":1,\"hash\":\"" ++ h ++ "\",\"data\":[]}"));
    try std.testing.expectError(ShapeErr.BadJson, parseRow(a, "{\"cust_id\":\"a\",\"source\":\"other\",\"key\":\"k\",\"kind\":\"k\",\"fetch\":1,\"hash\":\"" ++ h ++ "\",\"data\":{}}"));
}

test "same data same hash; row roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"t\":\"x\",\"n\":1}", .{});
    const r1 = try makeRow(a, "demo", .public, "k", "page", 5, d);
    const r2 = try makeRow(a, "demo", .public, "k", "page", 99, d);
    try std.testing.expectEqualStrings(r1.hash, r2.hash);
    const line = try rowLine(a, r1);
    const back = try parseRow(a, line);
    try std.testing.expectEqualStrings(r1.hash, back.hash);
}
