const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
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
    const datetime = b.dependency("datetime", .{
        .target = target,
        .optimize = optimize,
    });

    // Add the tofu module
    const tofuMod = b.addModule("tofu", .{
        .root_source_file = b.path("src/tofu.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    tofuMod.addImport("Appendable", nats.module("Appendable"));
    tofuMod.addImport("Formatter", nats.module("Formatter"));
    tofuMod.addImport("mailbox", mailbox.module("mailbox"));
    tofuMod.addImport("temp", temp.module("temp"));
    tofuMod.addImport("datetime", datetime.module("datetime"));

    // Create the library module
    const libMod = b.createModule(.{
        .root_source_file = b.path("src/ampe.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    libMod.addImport("tofu", tofuMod);
    libMod.addImport("Appendable", nats.module("Appendable"));
    libMod.addImport("Formatter", nats.module("Formatter"));
    libMod.addImport("mailbox", mailbox.module("mailbox"));
    libMod.addImport("temp", temp.module("temp"));
    libMod.addImport("datetime", datetime.module("datetime"));

    // Need libc for windows sockets
    if (target.result.os.tag == .windows) {
        libMod.link_libc = true;
        libMod.linkSystemLibrary("ws2_32", .{});
        libMod.linkSystemLibrary("ntdll", .{});
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tofu",
        .root_module = libMod,
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(lib);

    // Create recipes module
    const recipesMod = b.createModule(.{
        .root_source_file = b.path("recipes/recipes.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    recipesMod.addImport("tofu", tofuMod);
    recipesMod.addImport("mailbox", mailbox.module("mailbox"));

    // Create test module
    const testMod = b.createModule(.{
        .root_source_file = b.path("tests/tofu_tests.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    testMod.addImport("tofu", tofuMod);
    testMod.addImport("recipes", recipesMod);
    testMod.addImport("Appendable", nats.module("Appendable"));
    testMod.addImport("Formatter", nats.module("Formatter"));
    testMod.addImport("mailbox", mailbox.module("mailbox"));
    testMod.addImport("temp", temp.module("temp"));
    testMod.addImport("datetime", datetime.module("datetime"));

    // Create Windows POC module (Windows only)
    if (target.result.os.tag == .windows) {
        const winPocMod = b.createModule(.{
            .root_source_file = b.path("os/windows/poc/poc.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = false,
        });
        winPocMod.addImport("tofu", tofuMod); // Make tofu module available to win_poc
        testMod.addImport("win_poc", winPocMod);
    }

    // Creates unit testing artifact
    const lib_unit_tests = b.addTest(.{
        .root_module = testMod,
        .use_llvm = true,
        .use_lld = true,
    });

    // Link libraries for Windows tests
    if (target.result.os.tag == .windows) {
        lib_unit_tests.linkSystemLibrary("ws2_32");
        lib_unit_tests.linkSystemLibrary("ntdll");
        lib_unit_tests.linkSystemLibrary("kernel32"); // Link kernel32 for event functions
    }

    b.installArtifact(lib_unit_tests);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Documentation generation step
    const docs_step = b.step("docs", "Generate API documentation");

    const tofu_docs_lib = b.addObject(.{
        .name = "tofu",
        .root_module = tofuMod,
        .use_llvm = true,
        .use_lld = true,
    });

    const install_tofu_docs = b.addInstallDirectory(.{
        .source_dir = tofu_docs_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "../docs_site/docs" },
        .install_subdir = "apidocs",
    });

    // Create cookbook module
    const cookbookMod = b.createModule(.{
        .root_source_file = b.path("recipes/cookbook.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });
    cookbookMod.addImport("tofu", tofuMod);
    cookbookMod.addImport("mailbox", mailbox.module("mailbox"));

    const cookbook_docs_lib = b.addObject(.{
        .name = "cookbook",
        .root_module = cookbookMod,
        .use_llvm = true,
        .use_lld = true,
    });

    const install_cookbook_docs = b.addInstallDirectory(.{
        .source_dir = cookbook_docs_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "../docs_site/docs" },
        .install_subdir = "recipes",
    });

    docs_step.dependOn(&install_tofu_docs.step);
    docs_step.dependOn(&install_cookbook_docs.step);
}
