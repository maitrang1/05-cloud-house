// =====================================================================
// Des: Build file for the ggc-run setup app. Makes the program, the loopback mock Google (for the guide run), and runs all tests with zig build test.
// Flo: read target > build exe > build mock exe > wire run step > wire test step
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: zig build [run|mock|test] [-Doptimize=..] [-Dtarget=..]
// Out: zig-out/bin/ggc-run, zig-out/bin/ggc-run-mock, test results
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/ggc-run && zig build test
// Exe: none
// =====================================================================
const std = @import("std");

const CF = .{ .exeName = "ggc-run", .mockName = "ggc-run-mock", .rootFile = "main.zig", .mockFile = "te-mock-run.zig" };

// build graph: exe, mock exe, run, test
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the app
    const rootModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const exeArti = b.addExecutable(.{ .name = CF.exeName, .root_module = rootModu });
    b.installArtifact(exeArti);

    // the pretend Google, for the guide run and manual checks
    const mockModu = b.createModule(.{ .root_source_file = b.path(CF.mockFile), .target = target, .optimize = optimize, .link_libc = true });
    b.installArtifact(b.addExecutable(.{ .name = CF.mockName, .root_module = mockModu }));

    // zig build run -- <args>
    const runArti = b.addRunArtifact(exeArti);
    if (b.args) |args| runArti.addArgs(args);
    b.step("run", "Run the app").dependOn(&runArti.step);

    // unit + contract + flow tests (in-process mock)
    const testModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const testArti = b.addTest(.{ .root_module = testModu });
    b.step("test", "Unit, contract and full-flow tests").dependOn(&b.addRunArtifact(testArti).step);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
