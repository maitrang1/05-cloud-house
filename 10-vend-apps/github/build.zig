// =====================================================================
// Des: Build script for the github setup app - one exe plus its offline unit test binary
// Flo: options > exe (ReleaseSafe) > install > run step > test step (Debug)
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none - `zig build` / `zig build test` / -Doptimize= / -Dtarget= / -Dstrip=true
// Out: zig-out/bin/github(.exe)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github && zig build
// Exe: /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/github/zig-out/bin/github
// =====================================================================
const std = @import("std");
const zon = @import("build.zig.zon");

fn rootModule(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, mock: bool, strip: ?bool) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "mock", mock);
    opts.addOption([]const u8, "version", zon.version);
    const m = b.createModule(.{ .root_source_file = b.path("root-main.zig"), .target = target, .optimize = opt, .link_libc = true, .strip = strip });
    m.addImport("build_options", opts.createModule());
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const user_opt = b.option(std.builtin.OptimizeMode, "optimize", "Debug | ReleaseSafe (exe default) | ReleaseFast | ReleaseSmall");
    const strip = b.option(bool, "strip", "drop debug info from the exe");

    const exe = b.addExecutable(.{ .name = "github", .root_module = rootModule(b, target, user_opt orelse .ReleaseSafe, false, strip) });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run github").dependOn(&run_cmd.step);

    // one test binary rooted at root-main.zig; its `test {}` block imports every file ----
    const filters = b.option([]const []const u8, "test-filter", "only run tests whose name contains this text") orelse &.{};
    const tests = b.addTest(.{ .root_module = rootModule(b, target, user_opt orelse .Debug, true, null), .filters = filters });
    b.step("test", "Run all unit tests (offline)").dependOn(&b.addRunArtifact(tests).step);
}
// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
