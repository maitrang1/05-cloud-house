// =====================================================================
// Des: Build file for the GitLab setup app. Makes the program and runs the unit, contract, and full-flow end-to-end tests (acts-flow-contract.zig) via zig build test.
// Flo: read target > build exe > wire run step > wire test step > done
// Cre: 2026-11-12                          - | Mod: 2026-11-12 (aaa audit: dropped dead `e2e` step, e2e-run.zig was never written; coverage lives in acts-flow-contract.zig under `test`)
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: zig build [run|test] [-Doptimize=..] [-Dtarget=..]
// Out: zig-out/bin/gitlab-setup, test results
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab && zig build test
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/gitlab/zig-out/bin/gitlab-setup
// =====================================================================
const std = @import("std");

const CF = .{ .exeName = "gitlab-setup", .rootFile = "main.zig" };

// build graph: exe, run, test
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the app
    const rootModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const exeArti = b.addExecutable(.{ .name = CF.exeName, .root_module = rootModu });
    b.installArtifact(exeArti);

    // zig build run -- <args>
    const runArti = b.addRunArtifact(exeArti);
    if (b.args) |args| runArti.addArgs(args);
    b.step("run", "Run the app").dependOn(&runArti.step);

    // unit + contract tests (in-process mock)
    const testModu = b.createModule(.{ .root_source_file = b.path(CF.rootFile), .target = target, .optimize = optimize, .link_libc = true });
    const testArti = b.addTest(.{ .root_module = testModu });
    b.step("test", "Unit, contract, and full-flow end-to-end tests").dependOn(&b.addRunArtifact(testArti).step);
}

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
