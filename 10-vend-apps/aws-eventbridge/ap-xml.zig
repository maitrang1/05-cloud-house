// =====================================================================
// Des: Tiny XML reader for the flat answers IAM and STS send. Finds the text inside a tag, lists every match, and un-escapes the five basic entities. Not a general XML parser.
// Flo: find <tag> > find </tag> > copy the text between > un-escape
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: XML text, tag name
// Out: text inside the first tag, or all of them
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/aws-eventbridge && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");

const CF = .{ .ents = [_][2][]const u8{ .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" }, .{ "&amp;", "&" } } };

// raw text between <tag> and </tag> starting the search at `from`; end marks where the match stopped
fn tagRaw(text: []const u8, tag: []const u8, from: usize, end: *usize) ?[]const u8 {
    var buff: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&buff, "<{s}>", .{tag}) catch return null;
    const star = std.mem.indexOfPos(u8, text, from, open) orelse return null;
    var buf2: [64]u8 = undefined;
    const clos = std.fmt.bufPrint(&buf2, "</{s}>", .{tag}) catch return null;
    const stop = std.mem.indexOfPos(u8, text, star + open.len, clos) orelse return null;
    end.* = stop + clos.len;
    return text[star + open.len .. stop];
}

// un-escape the basic entities; the caller frees
fn unesc(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var cur = try gpa.dupe(u8, raw);
    for (CF.ents) |pair| {
        const nxt = try std.mem.replaceOwned(u8, gpa, cur, pair[0], pair[1]);
        gpa.free(cur);
        cur = nxt;
    }
    return cur;
}

// text inside the first <tag>, null when absent; the caller frees
pub fn tagFirst(gpa: std.mem.Allocator, text: []const u8, tag: []const u8) !?[]u8 {
    var end: usize = 0;
    const raw = tagRaw(text, tag, 0, &end) orelse return null;
    return try unesc(gpa, raw);
}

// text inside every <tag>, in order
pub fn tagAll(gpa: std.mem.Allocator, text: []const u8, tag: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    var from: usize = 0;
    while (tagRaw(text, tag, from, &from)) |raw| try list.append(gpa, try unesc(gpa, raw));
    return list.toOwnedSlice(gpa);
}

test "first tag, all tags, entities and missing" {
    const gpa = std.testing.allocator;
    const xml = "<R><Account>123456789012</Account><Arn>arn:a&amp;b</Arn><M>x</M><M>y</M></R>";
    const acct = (try tagFirst(gpa, xml, "Account")).?;
    defer gpa.free(acct);
    try std.testing.expectEqualStrings("123456789012", acct);
    const arnz = (try tagFirst(gpa, xml, "Arn")).?;
    defer gpa.free(arnz);
    try std.testing.expectEqualStrings("arn:a&b", arnz);
    try std.testing.expect((try tagFirst(gpa, xml, "Nope")) == null);
    const all = try tagAll(gpa, xml, "M");
    defer {
        for (all) |item| gpa.free(item);
        gpa.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("y", all[1]);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
