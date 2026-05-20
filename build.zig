const std = @import("std");

const NetworkBackend = enum { stdposix, posixnet };

pub fn build(b: *std.Build) void {
    const host_os = @import("builtin").os.tag;

    // Standard target options allows the person running `zig build` to choose
    // what target to build for.
    var target_query = b.standardTargetOptionsQueryOnly(.{});

    // Project Rule: Default ABI for Windows based on Host OS
    if (target_query.os_tag == .windows and target_query.abi == null) {
        if (host_os == .linux) {
            target_query.abi = .gnu;
        } else if (host_os == .windows) {
            target_query.abi = .msvc;
        }
    }

    // Project Rule: Minimum Windows version is RS4 (build 17063) for Unix socket support
    // Without this, cross-compilation defaults to older Windows version where
    // std.net.has_unix_sockets = false, causing Address.un to be void.
    if (target_query.os_tag == .windows) {
        target_query.os_version_min = .{ .windows = .win10_rs4 };
    }

    // Resolve the target after applying customizations
    const target = b.resolveTargetQuery(target_query);

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // For Zig 0.20.*
    // const network = b.option(
    //     NetworkBackend,
    //     "network",
    //     "Network backend: stdposix or posixnet",
    // ) orelse .stdposix;

    const network = .posixnet; //

    const build_options = b.addOptions();
    build_options.addOption(NetworkBackend, "network", network);

    const mailbox = b.dependency("mailbox", .{
        .target = target,
        .optimize = optimize,
    });

    const wepoll = if (target.result.os.tag == .windows) b.dependency("wepoll", .{}) else null;


    // Add the posix_net module
    const posixNetMod = b.addModule("posix_net", .{
        .root_source_file = b.path("src/platform/posixnet/wrapper/posix_net.zig"),
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

    tofuMod.addImport("posix_net", posixNetMod);
    tofuMod.addImport("mailbox", mailbox.module("mailbox"));
    tofuMod.addOptions("build_options", build_options);

    // Create the library module
    const libMod = b.createModule(.{
        .root_source_file = b.path("src/ampe.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
    });

    libMod.addImport("tofu", tofuMod);
    libMod.addImport("posix_net", posixNetMod);
    libMod.addImport("mailbox", mailbox.module("mailbox"));
    libMod.addOptions("build_options", build_options);

    // Link libc for all builds: getaddrinfo/freeaddrinfo are libc functions
    // used in SocketCreator for address resolution on all backends.
    libMod.link_libc = true;

    // Link libraries for Windows sockets
    if (target.result.os.tag == .windows) {
        libMod.linkSystemLibrary("ws2_32", .{});
        libMod.linkSystemLibrary("ntdll", .{});
    }

    if (network == .posixnet) {
        const is_kqueue = target.result.os.tag == .macos or
            target.result.os.tag == .freebsd or
            target.result.os.tag == .netbsd or
            target.result.os.tag == .openbsd;
        const is_windows = target.result.os.tag == .windows;

        const backend_flag = if (is_kqueue) "-DLIBUS_USE_KQUEUE" else "-DLIBUS_USE_EPOLL";
        const flags = &.{ "-fno-sanitize=undefined", "-DLIBUS_NO_SSL", backend_flag };

        const usockets_dep = b.dependency("usockets", .{});
        inline for ([_][]const u8{ "bsd.c", "context.c", "loop.c", "socket.c", "udp.c" }) |f| {
            libMod.addCSourceFile(.{ .file = usockets_dep.path("src/" ++ f), .flags = flags });
        }
        if (!is_windows) {
            libMod.addCSourceFile(.{ .file = usockets_dep.path("src/eventing/epoll_kqueue.c"), .flags = flags });
        } else {
            libMod.addCSourceFile(.{ .file = b.path("src/platform/posixnet/wrapper/adapters/us_epoll_win.c"), .flags = flags });
        }
        libMod.addIncludePath(usockets_dep.path("src/"));
        libMod.addIncludePath(usockets_dep.path("src/internal"));
        libMod.addIncludePath(usockets_dep.path("src/internal/networking"));
        libMod.link_libc = true;

        libMod.addCSourceFile(.{ .file = b.path("src/platform/posixnet/wrapper/adapters/pn_utils.c"), .flags = flags });
        if (is_windows) {
            libMod.addIncludePath(b.path("src/platform/posixnet/wrapper/adapters"));
            libMod.addIncludePath(wepoll.?.path(""));
        }
    }

    // LLD doesn't support Mach-O (macOS), so only use it on Windows/Linux
    const use_lld = target.result.os.tag != .macos and
        target.result.os.tag != .freebsd and
        target.result.os.tag != .openbsd and
        target.result.os.tag != .netbsd;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "tofu",
        .root_module = libMod,
        .use_llvm = true,
        .use_lld = use_lld,
    });

    if (target.result.os.tag == .windows) {
        lib.addCSourceFile(.{ .file = wepoll.?.path("wepoll.c"), .flags = &.{"-fno-sanitize=undefined"} });
        lib.addIncludePath(wepoll.?.path(""));
    }

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
    testMod.addImport("posix_net", posixNetMod);
    testMod.addImport("recipes", recipesMod);
    testMod.addImport("mailbox", mailbox.module("mailbox"));
    testMod.addOptions("build_options", build_options);
    // Separate options object so the same file is not the root of two modules.
    const test_gate_options = b.addOptions();
    test_gate_options.addOption(bool, "posixnet", network == .posixnet);
    testMod.addOptions("test_gate_options", test_gate_options);

    // Creates unit testing artifact
    const lib_unit_tests = b.addTest(.{
        .root_module = testMod,
        .use_llvm = true,
        .use_lld = use_lld,
    });

    // Link libc for all test builds: getaddrinfo/freeaddrinfo are libc functions
    // used in SocketCreator for address resolution on all backends.
    lib_unit_tests.linkLibC();

    // Link libraries for Windows tests
    if (target.result.os.tag == .windows) {
        lib_unit_tests.linkLibC();
        lib_unit_tests.linkSystemLibrary("ws2_32");
        lib_unit_tests.linkSystemLibrary("ntdll");
        lib_unit_tests.linkSystemLibrary("kernel32");

        lib_unit_tests.addCSourceFile(.{ .file = wepoll.?.path("wepoll.c"), .flags = &.{"-fno-sanitize=undefined"} });
        lib_unit_tests.addIncludePath(wepoll.?.path(""));
    }

    if (network == .posixnet) {
        const is_kqueue = target.result.os.tag == .macos or
            target.result.os.tag == .freebsd or
            target.result.os.tag == .netbsd or
            target.result.os.tag == .openbsd;
        const is_windows = target.result.os.tag == .windows;

        const backend_flag = if (is_kqueue) "-DLIBUS_USE_KQUEUE" else "-DLIBUS_USE_EPOLL";
        const flags = &.{ "-fno-sanitize=undefined", "-DLIBUS_NO_SSL", backend_flag };

        const usockets_dep = b.dependency("usockets", .{});
        inline for ([_][]const u8{ "bsd.c", "context.c", "loop.c", "socket.c", "udp.c" }) |f| {
            lib_unit_tests.addCSourceFile(.{ .file = usockets_dep.path("src/" ++ f), .flags = flags });
        }
        if (!is_windows) {
            lib_unit_tests.addCSourceFile(.{ .file = usockets_dep.path("src/eventing/epoll_kqueue.c"), .flags = flags });
        } else {
            lib_unit_tests.addCSourceFile(.{ .file = b.path("src/platform/posixnet/wrapper/adapters/us_epoll_win.c"), .flags = flags });
        }
        lib_unit_tests.addIncludePath(usockets_dep.path("src/"));
        lib_unit_tests.addIncludePath(usockets_dep.path("src/internal"));
        lib_unit_tests.addIncludePath(usockets_dep.path("src/internal/networking"));
        lib_unit_tests.linkLibC();

        lib_unit_tests.addCSourceFile(.{ .file = b.path("src/platform/posixnet/wrapper/adapters/pn_utils.c"), .flags = flags });
        if (is_windows) {
            lib_unit_tests.addIncludePath(b.path("src/platform/posixnet/wrapper/adapters"));
            lib_unit_tests.addIncludePath(wepoll.?.path(""));
        }
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
        .use_lld = use_lld,
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
        .use_lld = use_lld,
    });

    const install_cookbook_docs = b.addInstallDirectory(.{
        .source_dir = cookbook_docs_lib.getEmittedDocs(),
        .install_dir = .{ .custom = "../docs_site/docs" },
        .install_subdir = "recipes",
    });

    docs_step.dependOn(&install_tofu_docs.step);
    docs_step.dependOn(&install_cookbook_docs.step);
}
