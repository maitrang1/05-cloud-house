// =====================================================================
// Des: A pretend Oracle Cloud on a loopback port, for tests only. It checks every request signature for real (RSA-SHA256, headers, body hash, clock), keeps compartments, networks and VMs in memory, and counts what it saw. It also rejects DELETE and can fake rate limits and "no capacity".
// Flo: accept > read head + body > verify signature > route by path > answer JSON > count
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: HTTP requests from the app under test
// Out: Oracle-shaped JSON answers; counters for the tests
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (test file)
// =====================================================================
const std = @import("std");
const rsak = @import("pv-rsak.zig");

const Sha = std.crypto.hash.sha2.Sha256;
const Val = std.json.Value;

const CF = .{ .host = "127.0.0.1", .bodyMaxz = 1 << 20, .skewSecs = 300, .tena = "ocid1.tenancy.oc1..mocktena", .user = "ocid1.user.oc1..mockuser", .region = "mock-region-1", .adNamez = "Uocm:MOCK-AD-1", .imgIden = "ocid1.image.oc1..mockimg", .shapFree = "VM.Standard.E2.1.Micro" };

const Answ = struct { code: u16 = 200, body: []const u8 = "{}", retr: bool = false };

const Comp = struct { iden: []const u8, name: []const u8, polls: u32 };
const Vcn = struct { iden: []const u8, name: []const u8, comp: []const u8, rout: []const u8, secl: []const u8 };
const Igw = struct { iden: []const u8, name: []const u8, vcn: []const u8 };
const Subn = struct { iden: []const u8, name: []const u8, vcn: []const u8 };
const Inst = struct { iden: []const u8, name: []const u8, comp: []const u8, shap: []const u8, polls: u32, data: []const u8, ssh: []const u8, boot: i64, numb: u32 };

pub const Mock = struct {
    io: std.Io,
    aren: std.heap.ArenaAllocator,
    serv: std.Io.net.Server,
    port: u16,
    thre: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    mute: std.Io.Mutex = .init,

    // identity the mock knows
    pubKey: ?rsak.Held = null,
    fing: []const u8 = "",
    // things the "tenant" owns
    comps: std.ArrayList(Comp) = .empty,
    vcns: std.ArrayList(Vcn) = .empty,
    igws: std.ArrayList(Igw) = .empty,
    subns: std.ArrayList(Subn) = .empty,
    insts: std.ArrayList(Inst) = .empty,
    routRules: Val = .null,
    secIngr: Val = .null,
    secEgre: Val = .null,
    nextIden: u32 = 100,

    // knobs
    launchFail: u32 = 0,
    rateLimi: u32 = 0,
    compPolls: u32 = 1,
    instPolls: u32 = 1,
    noShape: bool = false,
    extraRule: bool = false,
    clockOff: i64 = 0,

    // counters
    seen: u32 = 0,
    sigBad: u32 = 0,
    delSeen: u32 = 0,
    launches: u32 = 0,
    logz: std.ArrayList([]const u8) = .empty,

    // listen on a system-chosen port and serve from a thread
    pub fn star(io: std.Io) !*Mock {
        const self = try std.heap.smp_allocator.create(Mock);
        errdefer std.heap.smp_allocator.destroy(self);
        var addr = try std.Io.net.IpAddress.parse(CF.host, 0);
        var serv = try addr.listen(io, .{ .reuse_address = true });
        errdefer serv.deinit(io);
        self.* = .{ .io = io, .aren = std.heap.ArenaAllocator.init(std.heap.smp_allocator), .serv = serv, .port = serv.socket.address.getPort() };
        try self.reset();
        self.thre = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    // stop the thread, free everything
    pub fn halt(self: *Mock) void {
        self.stop.store(true, .release);
        var addr = std.Io.net.IpAddress.parse(CF.host, self.port) catch unreachable; // literal ip always parses
        if (addr.connect(self.io, .{ .mode = .stream })) |conn| conn.close(self.io) else |_| {}
        if (self.thre) |thre| thre.join();
        self.serv.deinit(self.io);
        self.aren.deinit();
        std.heap.smp_allocator.destroy(self);
    }

    // fresh network rule lists, as a new VCN comes with
    fn reset(self: *Mock) !void {
        const gpa = self.aren.allocator();
        self.routRules = try std.json.parseFromSliceLeaky(Val, gpa, "[]", .{});
        self.secIngr = try std.json.parseFromSliceLeaky(Val, gpa, "[{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"isStateless\":false,\"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}},{\"protocol\":\"1\",\"source\":\"0.0.0.0/0\",\"icmpOptions\":{\"type\":3,\"code\":4}}]", .{});
        self.secEgre = try std.json.parseFromSliceLeaky(Val, gpa, "[{\"protocol\":\"all\",\"destination\":\"0.0.0.0/0\",\"isStateless\":false}]", .{});
    }

    // base url (identity or iaas flavour) for the config templates; caller frees
    pub fn base(self: *Mock, gpa: std.mem.Allocator, kind: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "http://{s}:{d}/{s}/{{regi}}", .{ CF.host, self.port, kind });
    }

    pub fn tena() []const u8 {
        return CF.tena;
    }

    pub fn user() []const u8 {
        return CF.user;
    }

    pub fn region() []const u8 {
        return CF.region;
    }

    // the "console" step: the human pastes the public key; from now on signatures are checked against it
    pub fn keyAdd(self: *Mock, pem: []const u8, fing: []const u8) !void {
        self.lock();
        defer self.unlo();
        const gpa = self.aren.allocator();
        self.pubKey = try rsak.publicPars(gpa, pem);
        self.fing = try gpa.dupe(u8, fing);
    }

    pub fn lock(self: *Mock) void {
        self.mute.lockUncancelable(self.io);
    }

    pub fn unlo(self: *Mock) void {
        self.mute.unlock(self.io);
    }

    // how many requests matched "METHOD path-prefix"
    pub fn seenCoun(self: *Mock, need: []const u8) u32 {
        self.lock();
        defer self.unlo();
        var coun: u32 = 0;
        for (self.logz.items) |item| if (std.mem.startsWith(u8, item, need)) {
            coun += 1;
        };
        return coun;
    }

    // accept loop: one request per connection
    fn loop(self: *Mock) void {
        while (true) {
            const conn = self.serv.accept(self.io) catch break;
            if (self.stop.load(.acquire)) {
                conn.close(self.io);
                break;
            }
            self.serv1(conn) catch {};
            conn.close(self.io);
        }
    }

    const Head = struct { name: []const u8, valu: []const u8 };

    // read one request, check it, route it, answer
    fn serv1(self: *Mock, conn: std.Io.net.Stream) !void {
        var rbuf: [16384]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var read = conn.reader(self.io, &rbuf);
        var writ = conn.writer(self.io, &wbuf);
        var http = std.http.Server.init(&read.interface, &writ.interface);
        var requ = try http.receiveHead();
        self.lock();
        defer self.unlo();
        const gpa = self.aren.allocator();

        // copy what we need before the body read invalidates the head
        const meth = requ.head.method;
        const targ = try gpa.dupe(u8, requ.head.target);
        var heads: std.ArrayList(Head) = .empty;
        var iter = requ.iterateHeaders();
        while (iter.next()) |head| try heads.append(gpa, .{ .name = try std.ascii.allocLowerString(gpa, head.name), .valu = try gpa.dupe(u8, head.value) });
        var bbuf: [4096]u8 = undefined;
        const body = if (meth.requestHasBody()) try (try requ.readerExpectContinue(&bbuf)).allocRemaining(gpa, .limited(CF.bodyMaxz)) else "";

        self.seen += 1;
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse targ.len;
        try self.logz.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ @tagName(meth), targ[0..ques] }));
        const answ = self.rout(gpa, meth, targ, heads.items, body) catch Answ{ .code = 500, .body = "{\"code\":\"InternalServerError\",\"message\":\"mock crashed\"}" };
        const retr = [_]std.http.Header{ .{ .name = "Retry-After", .value = "0" }, .{ .name = "Content-Type", .value = "application/json" } };
        const norm = [_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }};
        try requ.respond(answ.body, .{ .status = @enumFromInt(answ.code), .keep_alive = false, .extra_headers = if (answ.retr) &retr else &norm });
    }

    fn hget(heads: []const Head, name: []const u8) ?[]const u8 {
        for (heads) |item| if (std.mem.eql(u8, item.name, name)) return item.valu;
        return null;
    }

    // value of ?key= in a target, raw
    fn qget(targ: []const u8, key: []const u8) ?[]const u8 {
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse return null;
        var part = std.mem.splitScalar(u8, targ[ques + 1 ..], '&');
        while (part.next()) |item| {
            const eqzz = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            if (std.mem.eql(u8, item[0..eqzz], key)) return item[eqzz + 1 ..];
        }
        return null;
    }

    fn unauth(self: *Mock, why: []const u8) Answ {
        self.sigBad += 1;
        _ = why;
        return .{ .code = 401, .body = "{\"code\":\"NotAuthenticated\",\"message\":\"The required information to complete authentication was not provided or was incorrect.\"}" };
    }

    // verify the Oracle signature the way Oracle does; null = accepted
    fn authChec(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, targ: []const u8, heads: []const Head, body: []const u8) !?Answ {
        const held = self.pubKey orelse return self.unauth("no key uploaded");
        const auth = hget(heads, "authorization") orelse return self.unauth("no authorization");
        if (!std.mem.startsWith(u8, auth, "Signature ")) return self.unauth("scheme");
        var keyi: []const u8 = "";
        var algo: []const u8 = "";
        var hlst: []const u8 = "";
        var sigb: []const u8 = "";
        var rest = auth["Signature ".len..];
        while (rest.len > 0) {
            const eqzz = std.mem.indexOfScalar(u8, rest, '=') orelse break;
            const name = std.mem.trim(u8, rest[0..eqzz], " ,");
            if (eqzz + 1 >= rest.len or rest[eqzz + 1] != '"') break;
            const endq = std.mem.indexOfScalarPos(u8, rest, eqzz + 2, '"') orelse break;
            const valu = rest[eqzz + 2 .. endq];
            if (std.mem.eql(u8, name, "keyId")) keyi = valu;
            if (std.mem.eql(u8, name, "algorithm")) algo = valu;
            if (std.mem.eql(u8, name, "headers")) hlst = valu;
            if (std.mem.eql(u8, name, "signature")) sigb = valu;
            rest = rest[endq + 1 ..];
        }
        const want = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ CF.tena, CF.user, self.fing });
        if (!std.mem.eql(u8, keyi, want) or !std.mem.eql(u8, algo, "rsa-sha256")) return self.unauth("keyId or algorithm");

        // the signed list must hold at least what Oracle demands for this method
        const need: []const []const u8 = if (meth.requestHasBody()) &.{ "(request-target)", "host", "date", "x-content-sha256", "content-type", "content-length" } else &.{ "(request-target)", "host", "date" };
        var text: std.ArrayList(u8) = .empty;
        for (need) |item| {
            var found = false;
            var part = std.mem.tokenizeScalar(u8, hlst, ' ');
            while (part.next()) |one| if (std.mem.eql(u8, one, item)) {
                found = true;
            };
            if (!found) return self.unauth("missing signed header");
        }
        var part = std.mem.tokenizeScalar(u8, hlst, ' ');
        var firs = true;
        while (part.next()) |one| {
            if (!firs) try text.append(gpa, '\n');
            firs = false;
            if (std.mem.eql(u8, one, "(request-target)")) {
                try text.print(gpa, "(request-target): {s} {s}", .{ try std.ascii.allocLowerString(gpa, @tagName(meth)), targ });
            } else {
                const valu = hget(heads, one) orelse return self.unauth("signed header absent");
                try text.print(gpa, "{s}: {s}", .{ one, valu });
            }
        }
        const dec = std.base64.standard.Decoder;
        const size = dec.calcSizeForSlice(sigb) catch return self.unauth("signature base64");
        const sigz = try gpa.alloc(u8, size);
        dec.decode(sigz, sigb) catch return self.unauth("signature base64");
        if (!rsak.verify(gpa, held.key, text.items, sigz)) return self.unauth("signature does not verify");

        // body hash + length must match what was signed
        if (meth.requestHasBody()) {
            var dige: [Sha.digest_length]u8 = undefined;
            Sha.hash(body, &dige, .{});
            const enc = std.base64.standard.Encoder;
            const b64 = try gpa.alloc(u8, enc.calcSize(dige.len));
            _ = enc.encode(b64, &dige);
            if (!std.mem.eql(u8, hget(heads, "x-content-sha256") orelse "", b64)) return self.unauth("body hash");
            const clen = std.fmt.parseInt(usize, hget(heads, "content-length") orelse "x", 10) catch return self.unauth("content-length");
            if (clen != body.len) return self.unauth("content-length");
        }
        // clock: within 5 minutes
        const dstr = hget(heads, "date") orelse return self.unauth("date");
        const now = @divFloor(std.Io.Clock.real.now(self.io).toMilliseconds(), 1000) + self.clockOff;
        const stamp = dateSecs(dstr) orelse return self.unauth("date form");
        if (@abs(now - stamp) > CF.skewSecs) return self.unauth("clock skew");
        return null;
    }

    // "Sun, 05 Jan 2014 21:31:40 GMT" to unix seconds
    fn dateSecs(text: []const u8) ?i64 {
        if (text.len != 29) return null;
        const mons = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        const dayz = std.fmt.parseInt(u32, text[5..7], 10) catch return null;
        const year = std.fmt.parseInt(u16, text[12..16], 10) catch return null;
        const hour = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
        const minu = std.fmt.parseInt(i64, text[20..22], 10) catch return null;
        const secz = std.fmt.parseInt(i64, text[23..25], 10) catch return null;
        var mont: u32 = 0;
        for (mons, 0..) |item, indx| if (std.mem.eql(u8, item, text[8..11])) {
            mont = @intCast(indx + 1);
        };
        if (mont == 0) return null;
        // days from civil (Hinnant)
        const yadj: i64 = if (mont <= 2) @as(i64, year) - 1 else year;
        const eraz = @divFloor(yadj, 400);
        const yoez = yadj - eraz * 400;
        const madj: i64 = if (mont > 2) @as(i64, mont) - 3 else @as(i64, mont) + 9;
        const doyz = @divFloor(153 * madj + 2, 5) + dayz - 1;
        const doez = yoez * 365 + @divFloor(yoez, 4) - @divFloor(yoez, 100) + doyz;
        const days = eraz * 146097 + doez - 719468;
        return days * 86400 + hour * 3600 + minu * 60 + secz;
    }

    fn newId(self: *Mock, gpa: std.mem.Allocator, kind: []const u8) ![]const u8 {
        self.nextIden += 1;
        return std.fmt.allocPrint(gpa, "ocid1.{s}.oc1..m{d}", .{ kind, self.nextIden });
    }

    fn json(gpa: std.mem.Allocator, valu: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(gpa, valu, .{});
    }

    // pick the handler by path
    fn rout(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, targ: []const u8, heads: []const Head, body: []const u8) !Answ {
        if (meth == .DELETE) {
            self.delSeen += 1;
            return .{ .code = 405, .body = "{\"code\":\"MethodNotAllowed\",\"message\":\"mock refuses delete\"}" };
        }
        if (self.rateLimi > 0) {
            self.rateLimi -= 1;
            return .{ .code = 429, .body = "{\"code\":\"TooManyRequests\",\"message\":\"slow down\"}", .retr = true };
        }
        if (try self.authChec(gpa, meth, targ, heads, body)) |refu| return refu;
        const ques = std.mem.indexOfScalar(u8, targ, '?') orelse targ.len;
        const path = targ[0..ques];
        const jbody: Val = if (body.len > 0) std.json.parseFromSliceLeaky(Val, gpa, body, .{}) catch return .{ .code = 400, .body = "{\"code\":\"InvalidParameter\",\"message\":\"body is not JSON\"}" } else .null;
        if (std.mem.startsWith(u8, path, "/idn/")) {
            const rest = std.mem.trimStart(u8, path["/idn/".len..], "/");
            const cut = std.mem.indexOfScalar(u8, rest, '/') orelse return notf();
            return self.routIden(gpa, meth, rest[cut..], targ, jbody);
        }
        if (std.mem.startsWith(u8, path, "/iaa/")) {
            const rest = std.mem.trimStart(u8, path["/iaa/".len..], "/");
            const cut = std.mem.indexOfScalar(u8, rest, '/') orelse return notf();
            return self.routIaas(gpa, meth, rest[cut..], targ, jbody);
        }
        return notf();
    }

    fn notf() Answ {
        return .{ .code = 404, .body = "{\"code\":\"NotAuthorizedOrNotFound\",\"message\":\"not found\"}" };
    }

    fn str(valu: Val, key: []const u8) ?[]const u8 {
        if (valu != .object) return null;
        const item = valu.object.get(key) orelse return null;
        return if (item == .string) item.string else null;
    }

    // identity service: /20160918/...
    fn routIden(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, targ: []const u8, jbody: Val) !Answ {
        const pre = "/20160918";
        if (!std.mem.startsWith(u8, path, pre)) return notf();
        const rest = path[pre.len..];
        if (std.mem.startsWith(u8, rest, "/users/") and meth == .GET) {
            if (!std.mem.eql(u8, rest["/users/".len..], CF.user)) return notf();
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"name\":\"mock-user\",\"lifecycleState\":\"ACTIVE\"}}", .{CF.user}) };
        }
        if (std.mem.eql(u8, rest, "/availabilityDomains") and meth == .GET) return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"name\":\"{s}\"}}]", .{CF.adNamez}) };
        if (std.mem.eql(u8, rest, "/compartments")) {
            if (meth == .GET) {
                const want = qget(targ, "name") orelse "";
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.comps.items) |item| if (std.mem.eql(u8, item.name, want)) {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"lifecycleState\":\"ACTIVE\"}}", .{ item.iden, item.name });
                };
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                const name = str(jbody, "name") orelse return bad();
                const pare = str(jbody, "compartmentId") orelse return bad();
                if (!std.mem.eql(u8, pare, CF.tena)) return bad();
                for (self.comps.items) |item| if (std.mem.eql(u8, item.name, name)) return .{ .code = 409, .body = "{\"code\":\"CompartmentAlreadyExists\",\"message\":\"exists\"}" };
                const iden = try self.newId(gpa, "compartment");
                try self.comps.append(gpa, .{ .iden = iden, .name = try gpa.dupe(u8, name), .polls = self.compPolls });
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"lifecycleState\":\"CREATING\"}}", .{ iden, name }) };
            }
        }
        if (std.mem.startsWith(u8, rest, "/compartments/") and meth == .GET) {
            for (self.comps.items) |*item| if (std.mem.eql(u8, item.iden, rest["/compartments/".len..])) {
                const stat: []const u8 = if (item.polls > 0) "CREATING" else "ACTIVE";
                if (item.polls > 0) item.polls -= 1;
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"lifecycleState\":\"{s}\"}}", .{ item.iden, item.name, stat }) };
            };
            return notf();
        }
        return notf();
    }

    fn bad() Answ {
        return .{ .code = 400, .body = "{\"code\":\"InvalidParameter\",\"message\":\"bad request\"}" };
    }

    // true when this id is a compartment the mock holds
    fn compHave(self: *Mock, iden: []const u8) bool {
        for (self.comps.items) |item| if (std.mem.eql(u8, item.iden, iden)) return true;
        return false;
    }

    // compute + network: /20160918/...
    fn routIaas(self: *Mock, gpa: std.mem.Allocator, meth: std.http.Method, path: []const u8, targ: []const u8, jbody: Val) !Answ {
        const pre = "/20160918";
        if (!std.mem.startsWith(u8, path, pre)) return notf();
        const rest = path[pre.len..];

        if (std.mem.eql(u8, rest, "/vcns")) {
            if (meth == .GET) {
                const want = qget(targ, "displayName") orelse "";
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.vcns.items) |item| if (std.mem.eql(u8, item.name, want)) {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\",\"defaultRouteTableId\":\"{s}\",\"defaultSecurityListId\":\"{s}\"}}", .{ item.iden, item.name, item.rout, item.secl });
                };
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                const name = str(jbody, "displayName") orelse return bad();
                const comp = str(jbody, "compartmentId") orelse return bad();
                if (!self.compHave(comp) or str(jbody, "cidrBlock") == null) return bad();
                const item = Vcn{ .iden = try self.newId(gpa, "vcn"), .name = try gpa.dupe(u8, name), .comp = comp, .rout = try self.newId(gpa, "routetable"), .secl = try self.newId(gpa, "securitylist") };
                try self.vcns.append(gpa, item);
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\",\"defaultRouteTableId\":\"{s}\",\"defaultSecurityListId\":\"{s}\"}}", .{ item.iden, item.name, item.rout, item.secl }) };
            }
        }
        if (std.mem.eql(u8, rest, "/internetGateways")) {
            if (meth == .GET) {
                const want = qget(targ, "displayName") orelse "";
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.igws.items) |item| if (std.mem.eql(u8, item.name, want)) {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\"}}", .{ item.iden, item.name });
                };
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                const name = str(jbody, "displayName") orelse return bad();
                const vcn = str(jbody, "vcnId") orelse return bad();
                const item = Igw{ .iden = try self.newId(gpa, "internetgateway"), .name = try gpa.dupe(u8, name), .vcn = vcn };
                try self.igws.append(gpa, item);
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\"}}", .{ item.iden, item.name }) };
            }
        }
        if (std.mem.startsWith(u8, rest, "/routeTables/")) {
            if (meth == .GET) return .{ .body = try json(gpa, .{ .id = rest["/routeTables/".len..], .routeRules = self.routRules }) };
            if (meth == .PUT) {
                const rules = if (jbody == .object) jbody.object.get("routeRules") else null;
                if (rules == null or rules.? != .array) return bad();
                self.routRules = rules.?;
                return .{ .body = try json(gpa, .{ .id = rest["/routeTables/".len..], .routeRules = self.routRules }) };
            }
        }
        if (std.mem.startsWith(u8, rest, "/securityLists/")) {
            if (meth == .GET) {
                if (self.extraRule and self.secIngr == .array) {
                    self.extraRule = false;
                    try self.secIngr.array.append(try std.json.parseFromSliceLeaky(Val, gpa, "{\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"tcpOptions\":{\"destinationPortRange\":{\"min\":3306,\"max\":3306}}}", .{}));
                }
                return .{ .body = try json(gpa, .{ .id = rest["/securityLists/".len..], .ingressSecurityRules = self.secIngr, .egressSecurityRules = self.secEgre }) };
            }
            if (meth == .PUT) {
                const ing = if (jbody == .object) jbody.object.get("ingressSecurityRules") else null;
                const egr = if (jbody == .object) jbody.object.get("egressSecurityRules") else null;
                if (ing == null or egr == null or ing.? != .array or egr.? != .array) return bad();
                self.secIngr = ing.?;
                self.secEgre = egr.?;
                return .{ .body = try json(gpa, .{ .id = rest["/securityLists/".len..], .ingressSecurityRules = self.secIngr, .egressSecurityRules = self.secEgre }) };
            }
        }
        if (std.mem.eql(u8, rest, "/subnets")) {
            if (meth == .GET) {
                const want = qget(targ, "displayName") orelse "";
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.subns.items) |item| if (std.mem.eql(u8, item.name, want)) {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\"}}", .{ item.iden, item.name });
                };
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                const name = str(jbody, "displayName") orelse return bad();
                const vcn = str(jbody, "vcnId") orelse return bad();
                if (str(jbody, "routeTableId") == null) return bad();
                const item = Subn{ .iden = try self.newId(gpa, "subnet"), .name = try gpa.dupe(u8, name), .vcn = vcn };
                try self.subns.append(gpa, item);
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\"}}", .{ item.iden, item.name }) };
            }
        }
        if (std.mem.eql(u8, rest, "/shapes") and meth == .GET) {
            if (self.noShape) return .{ .body = "[]" };
            return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"shape\":\"{s}\"}},{{\"shape\":\"VM.Standard.A1.Flex\"}}]", .{CF.shapFree}) };
        }
        if (std.mem.eql(u8, rest, "/images") and meth == .GET) {
            const opsy = qget(targ, "operatingSystem") orelse "";
            if (!std.mem.eql(u8, opsy, "Canonical%20Ubuntu")) return .{ .body = "[]" };
            return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"id\":\"{s}\",\"displayName\":\"Canonical-Ubuntu-24.04\"}}]", .{CF.imgIden}) };
        }
        if (std.mem.eql(u8, rest, "/instances")) {
            if (meth == .GET) {
                var outp: std.ArrayList(u8) = .empty;
                try outp.append(gpa, '[');
                for (self.insts.items) |item| {
                    if (outp.items.len > 1) try outp.append(gpa, ',');
                    try outp.print(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\",\"shape\":\"{s}\",\"lifecycleState\":\"{s}\"}}", .{ item.iden, item.name, item.shap, if (item.polls > 0) "PROVISIONING" else "RUNNING" });
                }
                try outp.append(gpa, ']');
                return .{ .body = outp.items };
            }
            if (meth == .POST) {
                self.launches += 1;
                if (self.launchFail > 0) {
                    self.launchFail -= 1;
                    return .{ .code = 500, .body = "{\"code\":\"InternalError\",\"message\":\"Out of host capacity.\"}" };
                }
                const name = str(jbody, "displayName") orelse return bad();
                const shap = str(jbody, "shape") orelse return bad();
                const comp = str(jbody, "compartmentId") orelse return bad();
                // a Flex shape must carry its size, a fixed shape must not
                const scfg = if (jbody == .object) jbody.object.get("shapeConfig") else null;
                const isFlex = std.mem.endsWith(u8, shap, ".Flex");
                if (isFlex and (scfg == null or scfg.? != .object or scfg.?.object.get("ocpus") == null or scfg.?.object.get("memoryInGBs") == null)) return bad();
                if (!isFlex and scfg != null and scfg.? != .null) return bad();
                const meta = if (jbody == .object) jbody.object.get("metadata") else null;
                const sdet = if (jbody == .object) jbody.object.get("sourceDetails") else null;
                if (meta == null or sdet == null or str(sdet.?, "imageId") == null) return bad();
                const ssh = str(meta.?, "ssh_authorized_keys") orelse return bad();
                const dat6 = str(meta.?, "user_data") orelse return bad();
                const dec = std.base64.standard.Decoder;
                const size = dec.calcSizeForSlice(dat6) catch return bad();
                const dtxt = try gpa.alloc(u8, size);
                dec.decode(dtxt, dat6) catch return bad();
                const boot: i64 = if (sdet.? == .object) (if (sdet.?.object.get("bootVolumeSizeInGBs")) |bv| (if (bv == .integer) bv.integer else 0) else 0) else 0;
                if (!self.compHave(comp)) return bad();
                self.nextIden += 1;
                const item = Inst{ .iden = try self.newId(gpa, "instance"), .name = try gpa.dupe(u8, name), .comp = comp, .shap = try gpa.dupe(u8, shap), .polls = self.instPolls, .data = dtxt, .ssh = try gpa.dupe(u8, ssh), .boot = boot, .numb = self.nextIden };
                try self.insts.append(gpa, item);
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\",\"lifecycleState\":\"PROVISIONING\"}}", .{ item.iden, item.name }) };
            }
        }
        if (std.mem.startsWith(u8, rest, "/instances/") and meth == .GET) {
            for (self.insts.items) |*item| if (std.mem.eql(u8, item.iden, rest["/instances/".len..])) {
                const stat: []const u8 = if (item.polls > 0) "PROVISIONING" else "RUNNING";
                if (item.polls > 0) item.polls -= 1;
                return .{ .body = try std.fmt.allocPrint(gpa, "{{\"id\":\"{s}\",\"displayName\":\"{s}\",\"lifecycleState\":\"{s}\"}}", .{ item.iden, item.name, stat }) };
            };
            return notf();
        }
        if (std.mem.eql(u8, rest, "/vnicAttachments") and meth == .GET) {
            const want = qget(targ, "instanceId") orelse "";
            for (self.insts.items) |item| if (std.mem.eql(u8, item.iden, want)) return .{ .body = try std.fmt.allocPrint(gpa, "[{{\"vnicId\":\"ocid1.vnic.oc1..v{d}\"}}]", .{item.numb}) };
            return .{ .body = "[]" };
        }
        if (std.mem.startsWith(u8, rest, "/vnics/") and meth == .GET) {
            const tail = rest["/vnics/ocid1.vnic.oc1..v".len..];
            return .{ .body = try std.fmt.allocPrint(gpa, "{{\"publicIp\":\"203.0.113.{s}\"}}", .{tail}) };
        }
        return notf();
    }

    // the instance the app launched, for the tests to inspect
    pub fn instOne(self: *Mock) ?Inst {
        self.lock();
        defer self.unlo();
        return if (self.insts.items.len > 0) self.insts.items[0] else null;
    }
};

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
