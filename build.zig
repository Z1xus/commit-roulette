const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const exe = executable(b, target, optimize);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run groll").dependOn(&run.step);
    const release = b.step("release", "cross-build all eight release targets");
    const targets = [_][]const u8{ "x86_64-linux-gnu.2.28", "aarch64-linux-gnu.2.28", "x86_64-linux-musl", "aarch64-linux-musl", "x86_64-macos", "aarch64-macos", "x86_64-windows-gnu", "aarch64-windows-gnu" };
    for (targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple, .cpu_features = "baseline" }) catch unreachable);
        const artifact = executable(b, resolved, .ReleaseFast);
        const install = b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = triple } } });
        release.dependOn(&install.step);
    }
}

fn executable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = optimize != .Debug });
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    module.addOptions("build_options", options);
    module.addCSourceFile(.{ .file = b.path("src/platform.c"), .flags = &.{ "-std=c11", "-O3" } });
    module.addCSourceFile(.{ .file = b.path("src/gpu.c"), .flags = &.{ "-std=c11", "-O3" } });
    if (target.result.os.tag == .linux) module.linkSystemLibrary("dl", .{});
    switch (target.result.cpu.arch) {
        .x86_64 => module.addCSourceFile(.{ .file = b.path("src/hash-x86.c"), .flags = &.{"-O3"} }),
        .aarch64 => module.addCSourceFile(.{ .file = b.path("src/hash-arm.c"), .flags = &.{"-O3"} }),
        else => {},
    }
    return b.addExecutable(.{ .name = "groll", .root_module = module, .version = std.SemanticVersion.parse(manifest.version) catch @panic("invalid package version") });
}
