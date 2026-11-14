// =====================================================================
// Des: Build file for the Render setup app. Makes the program, a loopback mock Render (zig build mock), and runs all tests with zig build test.
// Flo: read target > build exe > wire run, mock and test steps
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: zig build [run|test|mock] [-Doptimize=..] [-Dtarget=..]
// Out: zig-out/bin/render-setup, zig-out/bin/render-mock, test results
// Run: cd /home/mai_trang/05-cloud-house/10-vend-apps/render && zig build test
// Exe: /home/mai_trang/05-cloud-house/10-vend-apps/render/zig-out/bin/render-setup
// =====================================================================
const std = @import("std");

const CF = .{ .exeName = "render-setup", .mockName = "render-mock", .rootFile = "main.zig", .mockFile = "te-serve.zig" };

// build graph: exe, run, mock, test
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rootModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const exeArti = b.addExecutable(.{ .name = CF.exeName, .root_module = rootModu });
    b.installArtifact(exeArti);

    const runArti = b.addRunArtifact(exeArti);
    if (b.args) |args| runArti.addArgs(args);
    b.step("run", "Run the app").dependOn(&runArti.step);

    // loopback mock Render, only built on request
    const mockModu = b.createModule(.{ .root_source_file = b.path(CF.mockFile), .target = target, .optimize = optimize, .link_libc = true });
    const mockArti = b.addExecutable(.{ .name = CF.mockName, .root_module = mockModu });
    b.step("mock", "Build the loopback mock Render").dependOn(&b.addInstallArtifact(mockArti, .{}).step);

    const testModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const testArti = b.addTest(.{ .root_module = testModu });
    b.step("test", "Unit, contract and full-flow tests").dependOn(&b.addRunArtifact(testArti).step);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
