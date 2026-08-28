const std = @import("std");
const zon = @import("build.zig.zon");

pub const InstallationOwnership = enum {
    self_managed,
    externally_managed,
};

pub const ArchiveBackend = enum {
    native,
    system,
};

pub fn build(b: *std.Build) void {

    // 1. Build Options
    // -------------------------------------------------------------------------
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const default_registry_url = b.option([]const u8, "default-registry-url", "Default registry URL") orelse "https://registry.moonstone.sh/registry/v0";
    const default_homepage_url = b.option([]const u8, "default-homepage-url", "Default homepage URL") orelse "https://moonstone.sh";
    const default_installer_url = b.option([]const u8, "default-installer-url", "Default Moonstone installer script URL") orelse "https://moonstone.sh/install";

    if (std.mem.indexOfAny(u8, default_installer_url, " \t\r\n'\"$`;&|<>") != null or
        (!std.mem.startsWith(u8, default_installer_url, "http://") and !std.mem.startsWith(u8, default_installer_url, "https://")))
    {
        @panic("default_installer_url must be a plain HTTP(S) URL without whitespace or shell metacharacters");
    }

    const installation_ownership = b.option(
        InstallationOwnership,
        "installation-ownership",
        "Whether Moonstone manages its own installation lifecycle (self-managed, external)",
    ) orelse .self_managed;

    const distribution_label = (b.option([]const u8, "distribution-label", "Distribution channel (standalone, homebrew, custom)")) orelse "standalone";

    const archive_backend = b.option(
        ArchiveBackend,
        "archive-backend",
        "Archive and compression backend (native, system)",
    ) orelse .native;

    const options = b.addOptions();
    options.addOption([]const u8, "name", @tagName(zon.name));
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "default_registry_url", default_registry_url);
    options.addOption([]const u8, "default_homepage_url", default_homepage_url);
    options.addOption([]const u8, "default_installer_url", default_installer_url);
    options.addOption(InstallationOwnership, "installation_ownership", installation_ownership);
    options.addOption([]const u8, "distribution_label", distribution_label);
    options.addOption(ArchiveBackend, "archive_backend", archive_backend);

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
    const profile_plan_tests = createMoonTest(b, "tests/unit/multi_profile_plan_test.zig", target, optimize, build_options_mod);
    const artifact_provider_tests = createMoonTest(b, "tests/unit/artifact_provider_test.zig", target, optimize, build_options_mod);
    const artifact_publication_tests = createMoonTest(b, "tests/unit/artifact_publication_test.zig", target, optimize, build_options_mod);
    const closure_assurance_tests = createMoonTest(b, "tests/unit/closure_assurance_test.zig", target, optimize, build_options_mod);
    const replay_contract_tests = createMoonTest(b, "tests/unit/replay_contract_test.zig", target, optimize, build_options_mod);
    const archive_tests = createMoonTest(b, "tests/unit/archive_test.zig", target, optimize, build_options_mod);
    const archive_contract_tests = createMoonTest(b, "tests/unit/archive_contract_test.zig", target, optimize, build_options_mod);
    const archive_corruption_tests = createMoonTest(b, "tests/unit/archive_corruption_test.zig", target, optimize, build_options_mod);
    const archive_security_tests = createMoonTest(b, "tests/unit/archive_security_test.zig", target, optimize, build_options_mod);
    const archive_differential_tests = createMoonTest(b, "tests/unit/archive_differential_test.zig", target, optimize, build_options_mod);
    const system_tools_tests = createMoonTest(b, "tests/unit/system_tools_test.zig", target, optimize, build_options_mod);
    const doctor_archive_tests = createMoonTest(b, "tests/unit/doctor_archive_test.zig", target, optimize, build_options_mod);

    const run_core_tests = b.addRunArtifact(core_tests);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const run_profile_plan_tests = b.addRunArtifact(profile_plan_tests);
    const run_artifact_provider_tests = b.addRunArtifact(artifact_provider_tests);
    const run_artifact_publication_tests = b.addRunArtifact(artifact_publication_tests);
    const run_closure_assurance_tests = b.addRunArtifact(closure_assurance_tests);
    const run_replay_contract_tests = b.addRunArtifact(replay_contract_tests);
    const run_archive_tests = b.addRunArtifact(archive_tests);
    const run_archive_contract_tests = b.addRunArtifact(archive_contract_tests);
    const run_archive_corruption_tests = b.addRunArtifact(archive_corruption_tests);
    const run_archive_security_tests = b.addRunArtifact(archive_security_tests);
    const run_archive_differential_tests = b.addRunArtifact(archive_differential_tests);
    const run_system_tools_tests = b.addRunArtifact(system_tools_tests);
    const run_doctor_archive_tests = b.addRunArtifact(doctor_archive_tests);

    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_profile_plan_tests.step);
    test_step.dependOn(&run_artifact_provider_tests.step);
    test_step.dependOn(&run_artifact_publication_tests.step);
    test_step.dependOn(&run_closure_assurance_tests.step);
    test_step.dependOn(&run_replay_contract_tests.step);
    test_step.dependOn(&run_archive_tests.step);
    test_step.dependOn(&run_archive_contract_tests.step);
    test_step.dependOn(&run_archive_corruption_tests.step);
    test_step.dependOn(&run_archive_security_tests.step);
    test_step.dependOn(&run_archive_differential_tests.step);
    test_step.dependOn(&run_system_tools_tests.step);
    test_step.dependOn(&run_doctor_archive_tests.step);

    // 4. Official Release Matrix (`zig build release`)
    // -------------------------------------------------------------------------
    const release_step = b.step("release", "Outputs all the targets to be uploaded into moonstone.sh and the official homebrew tap.");
    inline for (official_release_targets) |release_target| {
        const resolved_target = b.resolveTargetQuery(release_target.query());
        const triple = release_target.triple();

        const binary_name = b.fmt("moon-{s}-{s}", .{ zon.version, triple });

        const release_exe = createMoonExecutable(b, binary_name, resolved_target, optimize, build_options_mod);
        const install_release = b.addInstallArtifact(release_exe, .{});
        release_step.dependOn(&install_release.step);
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
    if (target.result.os.tag == .windows) exe.root_module.addCSourceFile(.{ .file = b.path("src/core/platform/windows_file.c"), .flags = &.{} });

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
    if (target.result.os.tag == .windows) t.root_module.addCSourceFile(.{ .file = b.path("src/core/platform/windows_file.c"), .flags = &.{} });
    t.root_module.addIncludePath(b.path("vendor/sqlite"));
    t.root_module.addCSourceFile(.{
        .file = b.path("src/core/platform/sqlite_helper.c"),
        .flags = &.{},
    });

    return t;
}

const ReleaseTarget = struct {
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    abi: std.Target.Abi = .none,

    pub fn query(self: @This()) std.Target.Query {
        return .{
            .cpu_arch = self.cpu_arch,
            .os_tag = self.os_tag,
            .abi = self.abi,
        };
    }

    pub fn triple(comptime self: @This()) []const u8 {
        return comptime switch (self.abi) {
            std.Target.Abi.none => std.fmt.comptimePrint("{s}-{s}", .{ @tagName(self.cpu_arch), @tagName(self.os_tag) }),
            else => std.fmt.comptimePrint("{s}-{s}-{s}", .{ @tagName(self.cpu_arch), @tagName(self.os_tag), @tagName(self.abi) }),
        };
    }
};

const official_release_targets: []const ReleaseTarget = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
    .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
};
