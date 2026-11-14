// =====================================================================
// Des: Matches a path against a simple pattern list (`*` = any run of characters), so what to pick or skip is set in config, not in code
// Flo: walk pattern and text together > on `*` remember one backtrack point > accept at the end of both
// Cre: 2026-11-14                          - | Mod: 2026-11-14
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: pattern, text (both with `/` separators)
// Out: bool
// Run: not run directly - imported by bundle-pick.zig
// Exe: n/a
// =====================================================================
const std = @import("std");

// `*` matches any run of characters, even `/`; one backtrack point, never exponential ----
pub fn glob(pat: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var back: usize = 0;
    while (t < text.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            back = t;
        } else if (p < pat.len and pat[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |s| {
            p = s + 1;
            back += 1;
            t = back;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

pub fn hitAny(list: []const []const u8, text: []const u8) bool {
    for (list) |p| if (glob(p, text)) return true;
    return false;
}

test "star matches runs, also across folders; no star means exact" {
    try std.testing.expect(glob("*token.json", "a/b/gg-token.json"));
    try std.testing.expect(glob("*token.json", "token.json"));
    try std.testing.expect(!glob("*token.json", "a/token.json.old"));
    try std.testing.expect(glob("a/*/c", "a/b/b/c"));
    try std.testing.expect(glob("exact", "exact"));
    try std.testing.expect(!glob("exact", "exac"));
    try std.testing.expect(!glob("", "x"));
    try std.testing.expect(glob("", ""));
    try std.testing.expect(glob("**", ""));
    try std.testing.expect(hitAny(&.{ "x*", "*y" }, "ay"));
    try std.testing.expect(!hitAny(&.{}, "ay"));
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
