// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.*.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.*.standardOptimizeOption(.{});

    const nats = b.*.dependency("nats", .{
        .target = target,
        .optimize = optimize,
    });

    const mailbox = b.*.dependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    });

    const temp = b.*.dependency("temp", .{
        .target = target,
        .optimize = optimize,
    });

    const datetime = b.*.dependency("datetime", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the tofu module first
    const tofuMod = b.*.createModule(.{
        .root_source_file = b.*.path("src/tofu.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    tofuMod.*.addImport("Appendable", nats.*.module("Appendable"));
    tofuMod.*.addImport("Formatter", nats.*.module("Formatter"));
    tofuMod.*.addImport("mailbox", mailbox.*.module("mailbox"));
    tofuMod.*.addImport("temp", temp.*.module("temp"));
    tofuMod.*.addImport("datetime", datetime.*.module("datetime"));

    // Create the library module
    const libMod = b.*.createModule(.{
        .root_source_file = b.*.path("src/ampe.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    libMod.*.addImport("tofu", tofuMod);
    libMod.*.addImport("Appendable", nats.*.module("Appendable"));
    libMod.*.addImport("Formatter", nats.*.module("Formatter"));
    libMod.*.addImport("mailbox", mailbox.*.module("mailbox"));
    libMod.*.addImport("temp", temp.*.module("temp"));
    libMod.*.addImport("datetime", datetime.*.module("datetime"));

    // need libc for windows sockets
    if (target.result.os.tag == .windows) {
        libMod.*.link_libc = true;
        libMod.*.linkSystemLibrary("ws2_32", .{});
    }

    const lib = b.*.addLibrary(.{
        .linkage = .static,
        .name = "tofu",
        .root_module = libMod,
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.*.installArtifact(lib);

    // Create recipes module
    const recipesMod = b.*.createModule(.{
        .root_source_file = b.*.path("recipes/cookbook.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    recipesMod.*.addImport("tofu", tofuMod);
    recipesMod.*.addImport("mailbox", mailbox.*.module("mailbox"));

    // Create test module
    const testMod = b.*.createModule(.{
        .root_source_file = b.*.path("tests/tofu_tests.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    testMod.*.addImport("tofu", tofuMod);
    testMod.*.addImport("recipes", recipesMod);
    testMod.*.addImport("Appendable", nats.*.module("Appendable"));
    testMod.*.addImport("Formatter", nats.*.module("Formatter"));
    testMod.*.addImport("mailbox", mailbox.*.module("mailbox"));
    testMod.*.addImport("temp", temp.*.module("temp"));
    testMod.*.addImport("datetime", datetime.*.module("datetime"));

    // need libc for windows sockets
    if (target.result.os.tag == .windows) {
        testMod.*.link_libc = true;
        testMod.*.linkSystemLibrary("ws2_32", .{});
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.*.addTest(.{
        .root_module = testMod,
        .test_runner = .{ .path = b.*.path("testRunner.zig"), .mode = .simple },
    });

    b.*.installArtifact(lib_unit_tests);

    const run_lib_unit_tests = b.*.addRunArtifact(lib_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.*.step("test", "Run unit tests");
    test_step.*.dependOn(&run_lib_unit_tests.step);
}

const std = @import("std");
const builtin = @import("builtin");
