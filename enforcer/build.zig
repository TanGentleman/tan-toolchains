const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const exe = b.addExecutable(.{
        .name = "enforcer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const opts = b.addOptions();
    opts.addOptionPath("exe_path", exe.getEmittedBin());

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cli_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_tests.root_module.addOptions("build_options", opts);
    cli_tests.step.dependOn(&exe.step);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run unit and CLI tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    const check = b.step("check", "Run fmt and tests");
    const fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src", "test", "build.zig" });
    check.dependOn(&fmt.step);
    check.dependOn(test_step);
}
