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

    // Adversarial fuzz / property tests — wired as a separate test module so
    // they can `@import("frame_protocol")` and exercise the public API.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_mod.addImport("frame_protocol", mod);
    fuzz_mod.addImport("cobs", cobs.module("cobs"));
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_mod,
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    test_step.dependOn(&run_fuzz_tests.step);

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
