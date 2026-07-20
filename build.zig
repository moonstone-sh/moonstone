const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {

    // 1. Build Options
    // -------------------------------------------------------------------------
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const default_registry_url = b.option([]const u8, "default_registry_url", "Default registry URL") orelse "https://registry.moonstone.sh/registry/v0";
    const distribution_channel = (b.option([]const u8, "distribution-channel", "Distribution channel (standalone, homebrew, aur, nix, apt, alpine, custom)"))
        orelse (b.option([]const u8, "distribution_channel", "Distribution channel alias"))
        orelse "standalone";

    const options = b.addOptions();
    options.addOption([]const u8, "name", @tagName(zon.name));
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "default_registry_url", default_registry_url);
    options.addOption([]const u8, "distribution_channel", distribution_channel);
    const build_options_mod = options.createModule();

    // 2. Canonical Executable (`zig build` / `zig build -Dtarget=...`)
    // -------------------------------------------------------------------------
    const canonical_exe = createMoonExecutable(b, "moon", target, optimize, build_options_mod);
    const install_canonical = b.addInstallArtifact(canonical_exe, .{});
    b.getInstallStep().dependOn(&install_canonical.step);

    const run_step = b.step("run", "Run the app natively");
    const run_cmd = b.addRunArtifact(canonical_exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // 3. Tests Step (`zig build test`)
    // -------------------------------------------------------------------------
    const test_step = b.step("test", "Run native tests");
    const core_tests = createMoonTest(b, "src/core/root.zig", target, optimize, build_options_mod);
    const cli_tests = createMoonTest(b, "src/cli/main.zig", target, optimize, build_options_mod);

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);

    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    // 4. Release Target Matrix Step (`zig build release`)
    // -------------------------------------------------------------------------
    const release_step = b.step("release", "Build the complete versioned target matrix for release");

    const target_triples = [_][]const u8{
        "aarch64-freebsd",
        "x86_64-freebsd",
        "aarch64-macos",
        "x86_64-macos",
        "aarch64-linux-gnu",
        "x86_64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "arm-linux-gnueabihf",
        "riscv64-linux-gnu",
    };

    for (target_triples) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("Invalid triple");
        const resolved_target = b.resolveTargetQuery(query);
        const bin_name = b.fmt("moon-{s}-{s}", .{ zon.version, triple });

        const matrix_exe = createMoonExecutable(b, bin_name, resolved_target, optimize, build_options_mod);
        const install_matrix = b.addInstallArtifact(matrix_exe, .{});
        release_step.dependOn(&install_matrix.step);
    }
}

fn createMoonExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.addModule(@tagName(zon.name), .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addIncludePath(b.path("vendor/sqlite"));
    core_mod.addImport("toml", toml.module("toml"));
    core_mod.addImport("build_options", build_options_mod);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "moonstone", .module = core_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "toml", .module = toml.module("toml") },
            },
        }),
    });

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

    return exe;
}

fn createMoonTest(
    b: *std.Build,
    root_src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const toml = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.addModule(@tagName(zon.name), .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_mod.addIncludePath(b.path("vendor/sqlite"));
    core_mod.addImport("toml", toml.module("toml"));
    core_mod.addImport("build_options", build_options_mod);

    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "moonstone", .module = core_mod },
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "toml", .module = toml.module("toml") },
            },
        }),
    });

    t.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_ENABLE_JSON1",
        },
    });
    t.root_module.addIncludePath(b.path("vendor/sqlite"));
    t.root_module.addCSourceFile(.{
        .file = b.path("src/core/platform/sqlite_helper.c"),
        .flags = &.{},
    });

    return t;
}
