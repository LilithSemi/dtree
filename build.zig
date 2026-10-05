const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const docs = b.option(bool, "docs", "install documentation") orelse true;

    const dtree = b.addModule("dtree", .{
        .root_source_file = b.path("dtree.zig"),
        .target = target,
        .optimize = optimize,
    });

    const step_test = b.step("test", "Run all unit tests");

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("dtree.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    step_test.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .name = "integration-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dtree", .module = dtree },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    step_test.dependOn(&run_integration_tests.step);

    if (docs) {
        const install_docs = b.addInstallDirectory(.{
            .source_dir = unit_tests.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        b.getInstallStep().dependOn(&install_docs.step);
    }

    const exe_example = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dtree", .module = dtree },
            },
        }),
    });

    b.installArtifact(exe_example);
}
