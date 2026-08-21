const std = @import("std");

// Top-level commands
pub const add = @import("add.zig").add_command;
pub const sync = @import("sync.zig").sync_command;
pub const init = @import("init.zig").init_command;
pub const setup = @import("setup.zig").SetupCommand;
pub const link = @import("link.zig").LinkCommand;
pub const run = @import("run.zig").RunCommand;
pub const manifest = struct {
    pub const export_cmd = @import("manifest_export.zig").ManifestExportCommand;
    pub const apply = @import("manifest_apply.zig").ManifestApplyCommand;
    pub const tidy = @import("manifest_tidy.zig").ManifestTidyCommand;
    pub const script = struct {
        pub const list = @import("manifest_script.zig").ListCommand;
        pub const get = @import("manifest_script.zig").GetCommand;
        pub const set = @import("manifest_script.zig").SetCommand;
        pub const remove = @import("manifest_script.zig").RemoveCommand;
    };
};
pub const lock = struct {
    pub const export_cmd = @import("lock_commands.zig").LockExportCommand;
    pub const verify = @import("lock_commands.zig").LockVerifyCommand;
    pub const profile_list = @import("lock_commands.zig").LockProfileListCommand;
    pub const package_list = @import("lock_commands.zig").LockPackageListCommand;
    pub const profile_get = @import("lock_commands.zig").LockProfileGetCommand;
    pub const package_get = @import("lock_commands.zig").LockPackageGetCommand;
    pub const realization_list = @import("lock_commands.zig").LockRealizationListCommand;
    pub const realization_get = @import("lock_commands.zig").LockRealizationGetCommand;
    pub const graph_export = @import("lock_commands.zig").LockGraphExportCommand;
};

pub const exec = @import("exec.zig").ExecCommand;
pub const remove = @import("remove.zig").remove_command;
pub const list = @import("list.zig").ListCommand;
pub const doctor = @import("doctor.zig").DoctorCommand;
pub const version = @import("version.zig").VersionCommand;
pub const env = @import("env.zig").EnvCommand;

// Self group
pub const self_cmd = struct {
    pub const install = @import("self_install.zig").SelfInstallCommand;
    pub const uninstall = @import("self_uninstall.zig").SelfUninstallCommand;
};

// Store group
pub const store = struct {
    pub const prune = @import("store_prune.zig").StorePruneCommand;
    pub const verify = @import("store_verify.zig").StoreVerifyCommand;
    pub const path = @import("store_path.zig").StorePathCommand;
    pub const list = @import("store_list.zig").StoreListCommand;
    pub const query = @import("store_query.zig").StoreQueryCommand;
    pub const purge = @import("store_purge.zig").StorePurgeCommand;
};

// StoreDriver group
pub const index = struct {
    pub const rebuild = @import("index_rebuild.zig").StoreDriverRebuildCommand;
    pub const check = @import("index_check.zig").StoreDriverCheckCommand;
    pub const stats = @import("index_stats.zig").StoreDriverStatsCommand;
    pub const vacuum = @import("index_vacuum.zig").StoreDriverVacuumCommand;
};

// Registry group
pub const registry = struct {
    pub const list = @import("registry_list.zig").RegistryListCommand;
    pub const add = @import("registry_add.zig").RegistryAddCommand;
    pub const remove = @import("registry_remove.zig").RegistryRemoveCommand;
};

pub const cache = struct {
    pub const clean = @import("cache_clean.zig").CacheCleanCommand;
    pub const manifest = struct {
        pub const list = @import("cache_manifest.zig").CacheManifestListCommand;
        pub const refresh = @import("cache_manifest.zig").CacheManifestRefreshCommand;
        pub const path = @import("cache_manifest.zig").CacheManifestPathCommand;
        pub const clear = @import("cache_manifest.zig").CacheManifestClearCommand;
    };
};

pub const config = struct {
    pub const show = @import("config_show.zig").ConfigShowCommand;
    pub const reset = @import("config_reset.zig").ConfigResetCommand;
    pub const get = @import("config_settings.zig").ConfigGetCommand;
    pub const set = @import("config_settings.zig").ConfigSetCommand;
    pub const unset = @import("config_settings.zig").ConfigUnsetCommand;
};

// Interpreter group
pub const interpreter = struct {
    pub const set = @import("interpreter_set.zig").InterpreterSetCommand;
    pub const install = @import("interpreter_install.zig").InterpreterInstallCommand;
    pub const remove = @import("interpreter_remove.zig").InterpreterRemoveCommand;
    pub const list = @import("interpreter_list.zig").InterpreterListCommand;
    pub const current = @import("interpreter_current.zig").InterpreterCurrentCommand;
    pub const path = @import("interpreter_path.zig").InterpreterPathCommand;
};

pub const CliErrorSet = error{
    UnknownCommand,
    UnknownFlag,
    MissingArgument,
    UnexpectedPositionalArgument,
    FileNotFound,
    PermissionDenied,
    LockFileRequired,
    MissingFromLockfile,
    OfflineNoRegistry,
    LockfileHashMismatch,
    MaterializerFailed,
    RegistryUnreachable,
    SqliteCorrupt,
    ScriptNotFound,
    DanglingSymlink,
    HealthCheckFailed,
    AlreadyReported,
    ResolutionFailed,
    MissingRuntime,
    NotInsideMoonstoneProject,
    MissingMoonstoneToml,
    InvalidLinkPathMode,
    NameAlreadyTaken,
    AlreadyInitialized,
    OfflineTransitiveArtifactMissing,
} || anyerror;

fn formatMaybeResolverPrefix(resolver: ?[]const u8, name: []const u8, writer: anytype) !void {
    if (resolver) |r| {
        try writer.print("{s}:{s}", .{ r, name });
    } else {
        try writer.print("{s}", .{name});
    }
}

pub const CliErrorDetail = union(enum) {
    hash_mismatch: struct {
        expected: []const u8,
        got: []const u8,
    },
    materializer_failed: struct {
        exit_code: u8,
        stderr: []const u8,
    },
    missing_argument: struct {
        flag: []const u8,
    },
    unknown_flag: struct {
        flag: []const u8,
        command: []const u8,
    },
    unknown_command: struct {
        command: []const u8,
    },
    message: struct {
        msg: []const u8,
    },
    offline_transitive_missing: struct {
        child_name: []const u8,
        child_resolver: ?[]const u8,
        child_constraint: []const u8,
        parent_name: []const u8,
        parent_version: []const u8,
        parent_resolver: ?[]const u8,
        parent_manifest_path: []const u8,
    },
    locked_artifact_missing: struct {
        name: []const u8,
        version: []const u8,
        resolver: ?[]const u8,
        artifact_hash: []const u8,
    },
    script_not_found: struct {
        name: []const u8,
    },
    orbit_not_found: struct {
        orbit: []const u8,
    },

    pub fn deinit(self: *CliErrorDetail, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .hash_mismatch => {},
            .materializer_failed => |mf| allocator.free(mf.stderr),
            .missing_argument => |ma| allocator.free(ma.flag),
            .unknown_flag => |uf| {
                allocator.free(uf.flag);
                allocator.free(uf.command);
            },
            .unknown_command => |uc| allocator.free(uc.command),
            .message => |m| allocator.free(m.msg),
            .offline_transitive_missing => |otm| {
                allocator.free(otm.child_name);
                if (otm.child_resolver) |r| allocator.free(r);
                allocator.free(otm.child_constraint);
                allocator.free(otm.parent_name);
                allocator.free(otm.parent_version);
                if (otm.parent_resolver) |r| allocator.free(r);
                allocator.free(otm.parent_manifest_path);
            },
            .locked_artifact_missing => |lam| {
                allocator.free(lam.name);
                allocator.free(lam.version);
                if (lam.resolver) |r| allocator.free(r);
                allocator.free(lam.artifact_hash);
            },
            .script_not_found => |snf| allocator.free(snf.name),
            .orbit_not_found => |onf| allocator.free(onf.orbit),
        }
    }
};

pub const CliError = anyerror;
pub const CommonError = error{
    AlreadyReported,
};

fn manifestErrorDetail(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingPackageSection => "moonstone.toml is missing the required [package] section.",
        error.InvalidPackageSection => "moonstone.toml [package] must be a TOML table.",
        error.MissingPackageName => "moonstone.toml [package] is missing name.",
        error.InvalidPackageName => "moonstone.toml [package].name must be a string.",
        error.MissingPackageVersion => "moonstone.toml [package] is missing version.",
        error.InvalidPackageVersion => "moonstone.toml [package].version must be a string.",
        error.MissingPackageKind => "moonstone.toml [package] is missing kind.",
        error.InvalidPackageKind => "moonstone.toml [package].kind must be a string.",
        error.InvalidRuntimeSection => "moonstone.toml [interpreter] must be a TOML table.",
        error.InvalidRuntimeName => "moonstone.toml [interpreter].name must be a string.",
        error.InvalidRuntimeVersion => "moonstone.toml [interpreter].version must be a string.",
        error.InvalidRuntimeAbi => "moonstone.toml [interpreter].abi must be a string.",
        error.LegacyDependencyRole => "dependency role 'dependency' is no longer supported; use 'runtime' or [dependencies.runtime].",
        error.InvalidDependencyRole => "dependency role must be one of: runtime, dev, tool, helper, external, optional.",
        else => null,
    };
}

fn recoveryHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ScriptNotFound => "List the project entrypoints with `moon manifest script list`, then run one with `moon run <name>`.",
        error.LockFileRequired, error.MissingFromLockfile, error.LockfileHashMismatch => "Synchronize the project with `moon sync`; use `moon sync --update` only when you intend to change the locked closure.",
        error.MaterializerFailed => "Run `moon doctor`, verify the package's native build prerequisites, then retry `moon sync`.",
        error.OfflineTransitiveArtifactMissing => "Retry online to stage the missing artifact, or add the exact artifact to a declared local registry before using `--offline`.",
        error.RockspecNotFound => "Pin a published rock release, check the configured LuaRocks registry, or choose a package version with an available rockspec.",
        error.PackageNotFound => "Check the package name and registry prefix. LuaRocks packages use `rocks:<name>`; inspect configured registries with `moon registry list`.",
        error.DanglingSymlink => "Run `moon sync` to rebuild the projected environment. Do not repair files inside `.moonstone/env` by hand.",
        error.InvalidLinkPathMode => "Use `moon link` for a registered live link or `moon add path:<directory>` for a project-local dependency.",
        else => null,
    };
}

pub fn reportError(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    json: bool,
    err: CliError,
    about: []const u8,
    detail: ?CliErrorDetail,
) !void {
    if (err == error.AlreadyReported or err == error.HealthCheckFailed) return;
    const contextual_detail = if (detail == null) @import("moonstone").diagnostics.error_context.take(allocator) else null;
    defer if (contextual_detail) |msg| allocator.free(msg);

    if (json) {
        var emitter = @import("ndjson.zig").Emitter.init(allocator, stdout, "command");
        const err_name = @errorName(err);
        const value = try std.mem.concat(allocator, u8, &.{ "error.", err_name });
        defer allocator.free(value);

        if (detail) |d| {
            switch (d) {
                .hash_mismatch => |hm| try emitter.fail(io, about, value, .{ .expected = hm.expected, .got = hm.got }),
                .materializer_failed => |mf| try emitter.fail(io, about, value, .{ .exit_code = mf.exit_code, .error_detail = mf.stderr, .recovery = recoveryHint(err) }),
                .missing_argument => |ma| try emitter.fail(io, about, value, .{ .flag = ma.flag }),
                .unknown_flag => |uf| try emitter.fail(io, about, value, .{ .flag = uf.flag, .command = uf.command }),
                .unknown_command => |uc| try emitter.fail(io, about, value, .{ .command = uc.command }),
                .message => |m| try emitter.fail(io, about, value, .{ .error_detail = m.msg }),
                .offline_transitive_missing => |otm| try emitter.fail(io, about, value, .{
                    .kind = "offline_transitive_missing",
                    .error_name = err_name,
                    .child_name = otm.child_name,
                    .child_resolver = otm.child_resolver,
                    .child_constraint = otm.child_constraint,
                    .parent_name = otm.parent_name,
                    .parent_version = otm.parent_version,
                    .parent_resolver = otm.parent_resolver,
                    .parent_manifest_path = otm.parent_manifest_path,
                    .recovery = recoveryHint(err),
                }),
                .locked_artifact_missing => |lam| try emitter.fail(io, about, value, .{
                    .kind = "locked_artifact_missing",
                    .error_name = err_name,
                    .name = lam.name,
                    .version = lam.version,
                    .resolver = lam.resolver,
                    .artifact_hash = lam.artifact_hash,
                }),
                .script_not_found => |snf| try emitter.fail(io, about, value, .{ .script = snf.name, .recovery = recoveryHint(err) }),
                .orbit_not_found => |onf| try emitter.fail(io, about, value, .{ .orbit = onf.orbit, .recovery = recoveryHint(err) }),
            }
        } else if (contextual_detail) |msg| {
            try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = msg });
        } else {
            if (err == error.RocksVersionDiscoveryFailed) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "LuaRocks registry is unreachable or returned an invalid manifest" });
            } else if (err == error.RockspecNotFound) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "LuaRocks package metadata was found, but no usable rockspec was available", .recovery = recoveryHint(err) });
            } else if (err == error.CompilerNotFound) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "Building native LuaRocks modules requires `zig` on PATH" });
            } else if (err == error.SQLiteCantOpen) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "Moonstone could not open its SQLite index. Check that the Moonstone data directory exists and is writable, or set MOONSTONE_HOME to a writable directory." });
            } else if (err == error.SQLiteReadOnly) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "Moonstone's SQLite index is read-only. Check permissions for the Moonstone data directory, or set MOONSTONE_HOME to a writable directory." });
            } else if (err == error.SQLiteBusy) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "Moonstone's SQLite index is busy or locked by another process. Retry after the other Moonstone operation finishes." });
            } else if (err == error.SQLiteCorrupt) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "Moonstone's SQLite index is corrupt or is not a SQLite database. Run 'moon index rebuild' to recreate it." });
            } else if (err == error.ConfigFileReadOnly) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "The active Moonstone config file is read-only or cannot be modified. Choose a writable --config-file, update its permissions, or use a writable MOONSTONE_CONFIG directory." });
            } else if (manifestErrorDetail(err)) |error_detail| {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = error_detail });
            } else {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .recovery = recoveryHint(err) });
            }
        }
    } else {
        try stdout.print("\x1b[2K\r", .{});
        if (detail) |d| {
            switch (d) {
                .hash_mismatch => |hm| try stdout.print("Error: hash mismatch for {s}. Expected {s}, got {s}\n", .{ about, hm.expected, hm.got }),
                .materializer_failed => |mf| {
                    try stdout.print("Error: Moonstone could not materialize {s} (exit code {d}).\n", .{ about, mf.exit_code });
                    try stdout.print("Details:\n{s}\n", .{mf.stderr});
                },
                .missing_argument => |ma| try stdout.print("Error: missing argument for flag --{s}\n", .{ma.flag}),
                .unknown_flag => |uf| try stdout.print("Error: unknown flag --{s} for command '{s}'\n", .{ uf.flag, uf.command }),
                .unknown_command => |uc| try stdout.print("Error: unknown command '{s}'\n", .{uc.command}),
                .message => |m| try stdout.print("Error: {s}\n", .{m.msg}),
                .offline_transitive_missing => |otm| {
                    try stdout.print("Error: Cannot resolve ", .{});
                    try formatMaybeResolverPrefix(otm.child_resolver, otm.child_name, stdout);
                    try stdout.print(" while offline.\n", .{});
                    try stdout.print("It is required by ", .{});
                    try formatMaybeResolverPrefix(otm.parent_resolver, otm.parent_name, stdout);
                    try stdout.print("@{s} from local store manifest:\n", .{otm.parent_version});
                    try stdout.print("  {s}\n\n", .{otm.parent_manifest_path});
                    try stdout.print("Required constraint:\n", .{});
                    try stdout.print("  {s} {s}\n\n", .{ otm.child_name, otm.child_constraint });
                    try stdout.print("No compatible artifact was found in the local store.\n", .{});
                },
                .locked_artifact_missing => |lam| {
                    try stdout.print("Error: Artifact pinned by moonstone.lock could not be restored.\n\n", .{});
                    try stdout.print("Package:\n  ", .{});
                    try formatMaybeResolverPrefix(lam.resolver, lam.name, stdout);
                    try stdout.print("@{s}\n\n", .{lam.version});
                    try stdout.print("Expected artifact:\n  {s}\n\n", .{lam.artifact_hash});
                    try stdout.print("A matching lockfile makes 'moon sync' replay its pinned resolution;\n", .{});
                    try stdout.print("the --locked flag is not required. Moonstone checked the local store\n", .{});
                    try stdout.print("and configured registries, but could not restore this exact artifact.\n", .{});
                    try stdout.print("Run 'moon sync --update'\n", .{});
                    try stdout.print("to create a new lockfile, or restore/publish the locked artifact.\n", .{});
                },
                .script_not_found => |snf| {
                    try stdout.print("Error: script '{s}' is not declared in moonstone.toml.\n", .{snf.name});
                },
                .orbit_not_found => |onf| {
                    try stdout.print("Error: orbit '{s}' not found.\n", .{onf.orbit});
                },
            }
        } else if (contextual_detail) |msg| {
            try stdout.print("Error: {s}\n", .{msg});
        } else {
            if (err == error.NotInsideMoonstoneProject or err == error.MissingMoonstoneToml or err == error.NoProjectFound) {
                try stdout.print("Error: not inside a Moonstone project. Run 'moon init' first, or retry from a directory containing moonstone.toml.\n", .{});
            } else if (err == error.RocksVersionDiscoveryFailed) {
                try stdout.print("Error: LuaRocks registry is unreachable or returned an invalid manifest. Check network connectivity, MOONSTONE_LUAROCKS_URL, or retry with --offline if the package is already cached.\n", .{});
            } else if (err == error.RockspecNotFound) {
                try stdout.print("Error: LuaRocks package metadata was found, but no usable rockspec was available for the selected version.\n", .{});
            } else if (err == error.CompilerNotFound) {
                try stdout.print("Error: building native LuaRocks modules requires `zig` on PATH. Install Zig or expose it in PATH, then retry.\n", .{});
            } else if (err == error.PackageNotFound) {
                try stdout.print("Error: package not found or no compatible version was available.\n", .{});
            } else if (err == error.LockfileOutOfSync) {
                try stdout.print("Error: moonstone.lock is out of sync with moonstone.toml. Run 'moon sync' to update it.\n", .{});
            } else if (err == error.SQLiteCantOpen) {
                try stdout.print("Error: Moonstone could not open its SQLite index. Check that the Moonstone data directory exists and is writable, or set MOONSTONE_HOME to a writable directory.\n", .{});
            } else if (err == error.SQLiteReadOnly) {
                try stdout.print("Error: Moonstone's SQLite index is read-only. Check permissions for the Moonstone data directory, or set MOONSTONE_HOME to a writable directory.\n", .{});
            } else if (err == error.SQLiteBusy) {
                try stdout.print("Error: Moonstone's SQLite index is busy or locked by another process. Retry after the other Moonstone operation finishes.\n", .{});
            } else if (err == error.SQLiteCorrupt) {
                try stdout.print("Error: Moonstone's SQLite index is corrupt or is not a SQLite database. Run 'moon index rebuild' to recreate it.\n", .{});
            } else if (err == error.ConfigFileReadOnly) {
                try stdout.print("Error: the active Moonstone config file is read-only or cannot be modified. Choose a writable --config-file, update its permissions, or use a writable MOONSTONE_CONFIG directory.\n", .{});
            } else if (err == error.OrbitMissingInterpreter) {
                try stdout.print("Error: orbit is missing an [interpreter] block in its moonstone.toml.\n", .{});
            } else if (manifestErrorDetail(err)) |error_detail| {
                try stdout.print("Error: {s}\n", .{error_detail});
            } else {
                try stdout.print("Error: {s} during {s}\n", .{ @errorName(err), about });
            }
        }

        if (recoveryHint(err)) |hint| {
            try stdout.print("Next: {s}\n", .{hint});
        }
    }
}

test "recovery hints stay actionable and deterministic" {
    try std.testing.expectEqualStrings(
        "List the project entrypoints with `moon manifest script list`, then run one with `moon run <name>`.",
        recoveryHint(error.ScriptNotFound).?,
    );
    try std.testing.expectEqualStrings(
        "Run `moon doctor`, verify the package's native build prerequisites, then retry `moon sync`.",
        recoveryHint(error.MaterializerFailed).?,
    );
    try std.testing.expect(recoveryHint(error.UnknownCommand) == null);
}

pub const ResolveCallbackContext = struct {
    io: std.Io,
    stdout: *std.Io.Writer,
    emitter: ?*@import("ndjson.zig").Emitter = null,
    spinner_frame: usize = 0,
};

pub fn progress(stdout: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try stdout.print(fmt, args);
    try stdout.flush();
}

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub fn renderSpinner(context: *ResolveCallbackContext, comptime fmt: []const u8, args: anytype) !void {
    const frame = spinner_frames[context.spinner_frame % spinner_frames.len];
    context.spinner_frame +%= 1;
    try context.stdout.print("\x1b[2K\r{s} ", .{frame});
    try context.stdout.print(fmt, args);
    try context.stdout.flush();
}

pub fn renderDone(context: *ResolveCallbackContext, comptime fmt: []const u8, args: anytype) !void {
    try context.stdout.print("\x1b[2K\r⠿ ", .{});
    try context.stdout.print(fmt, args);
    try context.stdout.print("\n", .{});
    try context.stdout.flush();
}

const fill_levels = [_][]const u8{ "⠀", "⡀", "⣀", "⣄", "⣤", "⣦", "⣶", "⣷", "⣿" };

pub fn renderProgress(context: *ResolveCallbackContext, fraction: f32, width: usize, comptime fmt: []const u8, args: anytype) !void {
    const frame = spinner_frames[context.spinner_frame % spinner_frames.len];
    context.spinner_frame +%= 1;

    try context.stdout.print("\x1b[2K\r{s} [", .{frame});

    const total_states = width * 8; // 8 states per character (from 0 to 8 fill levels)
    const current_state = @as(usize, @intFromFloat(fraction * @as(f32, @floatFromInt(total_states))));

    for (0..width) |i| {
        const char_state = if (current_state >= (i + 1) * 8)
            8
        else if (current_state <= i * 8)
            0
        else
            current_state - i * 8;

        try context.stdout.print("{s}", .{fill_levels[char_state]});
    }

    try context.stdout.print("] ", .{});
    try context.stdout.print(fmt, args);
    try context.stdout.flush();
}

pub fn onResolveEvent(ctx: ?*anyopaque, event: @import("moonstone").resolution.options.ResolveEvent) void {
    const context: *ResolveCallbackContext = @ptrCast(@alignCast(ctx orelse return));
    switch (event) {
        .retry => |r| {
            if (context.emitter) |e| {
                e.emit(context.io, .WARN, r.url, "retrying", .{
                    .error_name = r.err_name,
                    .attempt = r.attempt,
                    .max_retries = r.max_retries,
                    .delay_seconds = r.delay_seconds,
                }) catch {};
            } else {
                renderSpinner(context, "Retrying {s} due to {s} (attempt {d}/{d}, waiting {d}s)...", .{
                    r.url, r.err_name, r.attempt, r.max_retries, r.delay_seconds,
                }) catch {};
            }
        },
        .status => |s| {
            if (context.emitter) |e| {
                e.emit(context.io, .INFO, s.pkg_name, s.msg, .{}) catch {};
            } else {
                renderSpinner(context, "{s}: {s}", .{ s.pkg_name, s.msg }) catch {};
            }
        },
        .download_progress => |dp| {
            if (context.emitter) |e| {
                e.emit(context.io, .INFO, dp.pkg_name orelse "fetch", "downloading", .{
                    .url = dp.url,
                    .downloaded_bytes = dp.downloaded_bytes,
                    .total_bytes = dp.total_bytes,
                }) catch {};
            } else {
                if (dp.total_bytes) |total| {
                    const fraction = @as(f32, @floatFromInt(dp.downloaded_bytes)) / @as(f32, @floatFromInt(total));
                    renderProgress(context, fraction, 10, "{s} downloading... {d}/{d} bytes", .{ dp.pkg_name orelse dp.url, dp.downloaded_bytes, total }) catch {};
                } else {
                    renderSpinner(context, "{s} downloading... {d} bytes", .{ dp.pkg_name orelse dp.url, dp.downloaded_bytes }) catch {};
                }
            }
        },
        .metadata_sync_started => |label| {
            if (context.emitter) |e| {
                e.emit(context.io, .INFO, label, "syncing", .{}) catch {};
            } else {
                renderSpinner(context, "{s}", .{label}) catch {};
            }
        },
        .metadata_sync_done => |label| {
            if (context.emitter) |e| {
                e.emit(context.io, .STATUS, label, "synced", .{}) catch {};
            } else {
                renderDone(context, "{s}", .{label}) catch {};
            }
        },
        .build_failed => |bf| {
            if (context.emitter) |e| {
                e.emit(context.io, .ERROR, bf.pkg_name, "build_failed", .{
                    .command = bf.command,
                    .stderr_tail = bf.stderr_tail,
                    .log_path = bf.log_path,
                }) catch {};
            } else {
                context.stdout.print("\nBuild failed for '{s}'\nCommand: {s}\n", .{ bf.pkg_name, bf.command }) catch {};
                if (bf.log_path) |lp| {
                    context.stdout.print("Full log: {s}\n", .{lp}) catch {};
                }
                context.stdout.print("Tail of stderr:\n{s}\n", .{bf.stderr_tail}) catch {};
            }
        },
    }
}

pub fn onSolverEvent(ctx: ?*anyopaque, event: @import("moonstone").resolution.solver.report.SolverEvent, data: std.json.Value) void {
    const context: *ResolveCallbackContext = @ptrCast(@alignCast(ctx orelse return));
    const msg = switch (event) {
        .resolving => "choosing package version...",
        .propagating => "applying constraints...",
        .conflict => "conflict found; deriving explanation...",
        .backtracking => "backtracking...",
    };
    if (context.emitter) |e| {
        e.emit(context.io, .INFO, "solver", switch (event) {
            .resolving => "solver: choosing package version...",
            .propagating => "solver: applying constraints...",
            .conflict => "solver: conflict found; deriving explanation...",
            .backtracking => "solver: backtracking...",
        }, data) catch {};
    } else {
        if (data == .object) {
            if (data.object.get("package")) |pkg| {
                if (pkg == .string) {
                    if (event == .resolving) {
                        renderSpinner(context, "solver: choosing package version for {s}...", .{pkg.string}) catch {};
                        return;
                    } else if (event == .propagating) {
                        renderSpinner(context, "solver: applying constraints for {s}...", .{pkg.string}) catch {};
                        return;
                    }
                }
            }
        }
        renderSpinner(context, "solver: {s}", .{msg}) catch {};
    }
}

pub fn moonstone_sqlite_transient() @import("moonstone").store.driver.c.sqlite3_destructor_type {
    return @import("moonstone").store.driver.moonstone_sqlite_transient_ptr;
}
