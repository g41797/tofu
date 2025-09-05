// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const nats = b.dependency("nats", .{
        .target = target,
        .optimize = optimize,
    });

    const mailbox = b.dependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    });

    const temp = b.dependency("temp", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "yaaamp",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    // need libc for windows sockets
    if (target.result.os.tag == .windows) {
        lib.linkLibC();
        lib.linkSystemLibrary("ws2_32");
    }

    _ = b.addModule("yaaamp", .{
        .root_source_file = b.path("src/engine.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    lib.root_module.addImport("nats", nats.module("nats"));
    lib.root_module.addImport("mailbox", mailbox.module("mailbox"));
    lib.root_module.addImport("temp", temp.module("temp"));

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/ampe_tests.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
        .error_tracing = true,
        .test_runner = .{ .path = b.path("testRunner.zig"), .mode = .simple },
    });

    lib_unit_tests.root_module.addImport("nats", nats.module("nats"));
    lib_unit_tests.root_module.addImport("mailbox", mailbox.module("mailbox"));
    lib_unit_tests.root_module.addImport("temp", temp.module("temp"));

    // need libc for windows sockets
    if (target.result.os.tag == .windows) {
        lib_unit_tests.linkLibC();
        lib_unit_tests.linkSystemLibrary("ws2_32");
    }

    b.installArtifact(lib_unit_tests);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/ampe_tests.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = true,
        .test_runner = .{ .path = b.path("testRunner.zig"), .mode = .simple },
    });

    // need libc for windows sockets
    if (target.result.os.tag == .windows) {
        exe_unit_tests.linkLibC();
        exe_unit_tests.linkSystemLibrary("ws2_32");
    }

    _ = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

const std = @import("std");
const builtin = @import("builtin");
