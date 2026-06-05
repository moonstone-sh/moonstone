const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    // =========================================================================
    // 1. GLOBAL SETUP (Outside the loop)
    // =========================================================================

    const target_triples = [_][]const u8{
        "aarch64-freebsd", // For your VM
        "x86_64-freebsd", // Standard Intel/AMD FreeBSD
        "aarch64-macos", // Native M3 Mac
        "aarch64-linux-gnu", // ARM Linux (Standard glibc)
        "x86_64-linux-musl", // Intel Linux (Static musl binary)
        "riscv64-linux-gnu", // RISC-V Linux
        // "riscv64-freestanding-none", // Bare metal RISC-V
    };

    // Optimization is usually shared across all targets
    const optimize = b.standardOptimizeOption(.{});

    // Custom build options (Shared)
    const default_registry_url = b.option([]const u8, "default_registry_url", "Default registry URL") orelse "https://moonstone.sh/registry/v0";
    const options = b.addOptions();
    options.addOption([]const u8, "name", @tagName(zon.name));
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "default_registry_url", default_registry_url);
    const build_options_mod = options.createModule();

    const test_step = b.step("test", "Run native tests");

    // =========================================================================
    // 2. THE MATRIX LOOP
    // =========================================================================

    for (target_triples) |triple| {
        // Resolve the specific target for this iteration
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("Invalid triple");
        const resolved_target = b.resolveTargetQuery(query);

        // Format the binary name (e.g., "moon-1.0.1-aarch64-freebsd")
        const bin_name = b.fmt("moon-{s}-{s}", .{ zon.version, triple });

        // Target-specific dependencies
        const toml = b.dependency("toml", .{
            .target = resolved_target,
            .optimize = optimize,
        });

        // Create the Core Module
        const mod = b.addModule(@tagName(zon.name), .{
            .root_source_file = b.path("src/core/root.zig"),
            .target = resolved_target,
            .optimize = optimize,
        });
        mod.addIncludePath(b.path("vendor/sqlite"));
        mod.addImport("toml", toml.module("toml"));
        mod.addImport("build_options", build_options_mod);

        // Create the Executable
        const exe = b.addExecutable(.{
            .name = bin_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli/main.zig"),
                .target = resolved_target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "moonstone", .module = mod },
                    .{ .name = "build_options", .module = build_options_mod },
                    .{ .name = "toml", .module = toml.module("toml") },
                },
            }),
        });

        // Add C source files for SQLite to the executable
        exe.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{
                "-DSQLITE_THREADSAFE=1",
                "-DSQLITE_OMIT_LOAD_EXTENSION",
                "-DSQLITE_ENABLE_JSON1",
            },
        });
        exe.root_module.addIncludePath(b.path("vendor/sqlite"));
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/core/platform/sqlite_helper.c"),
            .flags = &.{},
        });

        // Install this specific executable to zig-out/bin/
        const install_exe = b.addInstallArtifact(exe, .{});

        b.getInstallStep().dependOn(&install_exe.step);
    }

    // =========================================================================
    // 3. NATIVE DEVELOPMENT TOOLS (Outside the loop)
    // =========================================================================

    // We create a separate, standard target just for `zig build run` and local tests
    // so you can rapidly test your code on your local machine without triggering the matrix.
    const native_target = b.standardTargetOptions(.{});
    const native_toml = b.dependency("toml", .{
        .target = native_target,
        .optimize = optimize,
    });

    // Native Core Module
    const native_mod = b.addModule(@tagName(zon.name), .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = native_target,
        .optimize = optimize,
    });
    native_mod.addIncludePath(b.path("vendor/sqlite"));
    native_mod.addImport("toml", native_toml.module("toml"));
    native_mod.addImport("build_options", build_options_mod);

    const native_mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/root.zig"),
            .target = native_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "toml", .module = native_toml.module("toml") },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    native_mod_tests.root_module.addIncludePath(b.path("vendor/sqlite"));
    native_mod_tests.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_JSON1" },
    });
    native_mod_tests.root_module.addCSourceFile(.{
        .file = b.path("src/core/platform/sqlite_helper.c"),
        .flags = &.{},
    });
    const run_native_mod_tests = b.addRunArtifact(native_mod_tests);
    test_step.dependOn(&run_native_mod_tests.step);

    const native_exe = b.addExecutable(.{
        .name = "moon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = native_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "moonstone", .module = native_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "toml", .module = native_toml.module("toml") },
            },
        }),
    });
    native_exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_ENABLE_JSON1" },
    });
    native_exe.root_module.addIncludePath(b.path("vendor/sqlite"));
    native_exe.root_module.addCSourceFile(.{
        .file = b.path("src/core/platform/sqlite_helper.c"),
        .flags = &.{},
    });

    // Install the native 'moon' binary to zig-out/bin/
    const install_native = b.addInstallArtifact(native_exe, .{});
    b.getInstallStep().dependOn(&install_native.step);

    const run_step = b.step("run", "Run the app natively");
    const run_cmd = b.addRunArtifact(native_exe);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
