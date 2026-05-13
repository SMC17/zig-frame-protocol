const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cobs = b.dependency("cobs", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("frame_protocol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("cobs", cobs.module("cobs"));

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/echo.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("frame_protocol", mod);
    const example_exe = b.addExecutable(.{
        .name = "example-echo",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example-echo", "Run the echo example");
    example_step.dependOn(&run_example.step);
}
