// =====================================================================
// Des: Build file for the Cloudflare setup app. Makes the program, a loopback mock Cloudflare (zig build mock), and runs all tests with zig build test.
// Flo: read target > build exe > wire run, mock and test steps
// Cre: 2026-11-13                          - | Mod: 2026-11-13
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: zig build [run|test|mock] [-Doptimize=..] [-Dtarget=..]
// Out: zig-out/bin/cf-cron-setup, zig-out/bin/cf-cron-mock, test results
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron && zig build test
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/cf-cron/zig-out/bin/cf-cron-setup
// =====================================================================
const std = @import("std");

const CF = .{ .exeName = "cf-cron-setup", .mockName = "cf-cron-mock", .rootFile = "main.zig", .mockFile = "te-serve.zig" };

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

    // loopback mock Cloudflare, only built on request
    const mockModu = b.createModule(.{ .root_source_file = b.path(CF.mockFile), .target = target, .optimize = optimize, .link_libc = true });
    const mockArti = b.addExecutable(.{ .name = CF.mockName, .root_module = mockModu });
    b.step("mock", "Build the loopback mock Cloudflare").dependOn(&b.addInstallArtifact(mockArti, .{}).step);

    const testModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const testArti = b.addTest(.{ .root_module = testModu });
    b.step("test", "Unit, contract and full-flow tests").dependOn(&b.addRunArtifact(testArti).step);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
