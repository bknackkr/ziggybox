const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main multicall executable
    const exe = b.addExecutable(.{
        .name = "ziggybox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ziggybox");
    run_step.dependOn(&run_cmd.step);

    // Tests step
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const echo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/commands/echo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_echo_tests = b.addRunArtifact(echo_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_echo_tests.step);
}
