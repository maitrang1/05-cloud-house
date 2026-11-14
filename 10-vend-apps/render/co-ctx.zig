// =====================================================================
// Des: The shared run context every step reads, plus the helper that turns a step function into an engine row.
// Flo: build ctx once > each step gets a pointer > wrap into a Row
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: config, vault, state, Render client, input queue
// Out: Ctx struct and row()
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: none (library file)
// =====================================================================
const std = @import("std");
const cfg = @import("co-cfg.zig");
const vaul = @import("pv-vault.zig");
const stat = @import("co-state.zig");
const inpu = @import("co-input.zig");
const engi = @import("co-engine.zig");
const rend = @import("ap-render.zig");

// everything a step may touch
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    conf: *const cfg.Conf,
    vaul: *vaul.Vaul,
    stat: *stat.Stat,
    rend: *rend.Rend,
    inpu: *inpu.Inpu,
    root: []const u8,
};

pub const Act = *const fn (*Ctx, std.mem.Allocator) anyerror!engi.Done;

// wrap one step function as an engine row
pub fn row(ctx: *Ctx, comptime iden: []const u8, comptime name: []const u8, comptime hand: bool, comptime act: fn (*Ctx, std.mem.Allocator) anyerror!engi.Done) engi.Row {
    const Wrap = struct {
        fn runz(raw: *anyopaque, gpa: std.mem.Allocator) anyerror!engi.Done {
            const self: *Ctx = @ptrCast(@alignCast(raw));
            return act(self, gpa);
        }
    };
    return .{ .iden = iden, .name = name, .hand = hand, .runz = Wrap.runz, .ctx = ctx };
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
