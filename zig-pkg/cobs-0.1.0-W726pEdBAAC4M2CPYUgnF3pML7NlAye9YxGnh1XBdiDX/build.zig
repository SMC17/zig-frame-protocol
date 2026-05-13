const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("cobs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Examples
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_mod.addImport("cobs", mod);
    const example_exe = b.addExecutable(.{
        .name = "example-roundtrip",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example-roundtrip", "Run the roundtrip example");
    example_step.dependOn(&run_example.step);

}
