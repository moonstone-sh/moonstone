const std = @import("std");

// Top-level commands
pub const add = @import("add.zig").add_command;
pub const sync = @import("sync.zig").sync_command;
pub const install = @import("self_install.zig").SelfInstallCommand;
pub const uninstall = @import("uninstall.zig").UninstallCommand;
pub const init = @import("init.zig").init_command;
pub const setup = @import("setup.zig").SetupCommand;
pub const link = @import("link.zig").LinkCommand;
pub const run = @import("run.zig").RunCommand;

pub const exec = @import("exec.zig").ExecCommand;
pub const remove = @import("remove.zig").remove_command;
pub const list = @import("list.zig").ListCommand;
pub const doctor = @import("doctor.zig").DoctorCommand;
pub const use = @import("use.zig").use_command;
pub const version = @import("version.zig").VersionCommand;
pub const env = @import("env.zig").EnvCommand;

// Store group
pub const store = struct {
    pub const gc = @import("store_gc.zig").StoreGcCommand;
    pub const verify = @import("store_verify.zig").StoreVerifyCommand;
    pub const path = @import("store_path.zig").StorePathCommand;
    pub const list = @import("store_list.zig").StoreListCommand;
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

// Runtime group
pub const runtime = struct {
    pub const install = @import("runtime_install.zig").RuntimeInstallCommand;
    pub const remove = @import("runtime_remove.zig").RuntimeRemoveCommand;
    pub const list = @import("runtime_list.zig").RuntimeListCommand;
    pub const current = @import("runtime_current.zig").RuntimeCurrentCommand;
    pub const path = @import("runtime_path.zig").RuntimePathCommand;
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
        }
    }
};

pub const CliError = anyerror;
pub const CommonError = error{
    AlreadyReported,
};

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

    if (json) {
        var emitter = @import("ndjson.zig").Emitter.init(allocator, stdout, "command");
        const err_name = @errorName(err);
        const value = try std.mem.concat(allocator, u8, &.{ "error.", err_name });
        defer allocator.free(value);

        if (detail) |d| {
            switch (d) {
                .hash_mismatch => |hm| try emitter.fail(io, about, value, .{ .expected = hm.expected, .got = hm.got }),
                .materializer_failed => |mf| try emitter.fail(io, about, value, .{ .exit_code = mf.exit_code, .error_detail = mf.stderr }),
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
                }),
                .locked_artifact_missing => |lam| try emitter.fail(io, about, value, .{
                    .kind = "locked_artifact_missing",
                    .error_name = err_name,
                    .name = lam.name,
                    .version = lam.version,
                    .resolver = lam.resolver,
                    .artifact_hash = lam.artifact_hash,
                }),
            }
        } else {
            if (err == error.RocksVersionDiscoveryFailed) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "LuaRocks registry is unreachable or returned an invalid manifest" });
            } else if (err == error.RockspecNotFound) {
                try emitter.fail(io, about, value, .{ .error_name = err_name, .error_detail = "LuaRocks package metadata was found, but no usable rockspec was available" });
            } else {
                try emitter.fail(io, about, value, .{ .error_name = err_name });
            }
        }
    } else {
        if (detail) |d| {
            switch (d) {
                .hash_mismatch => |hm| try stdout.print("Error: hash mismatch for {s}. Expected {s}, got {s}\n", .{ about, hm.expected, hm.got }),
                .materializer_failed => |mf| try stdout.print("Error: materializer failed for {s} with exit code {d}. Stderr: {s}\n", .{ about, mf.exit_code, mf.stderr }),
                .missing_argument => |ma| try stdout.print("Error: missing argument for flag --{s}\n", .{ ma.flag }),
                .unknown_flag => |uf| try stdout.print("Error: unknown flag --{s} for command '{s}'\n", .{ uf.flag, uf.command }),
                .unknown_command => |uc| try stdout.print("Error: unknown command '{s}'\n", .{ uc.command }),
                .message => |m| try stdout.print("Error: {s}\n", .{ m.msg }),
                .offline_transitive_missing => |otm| {
                    try stdout.print("Error: Cannot resolve ", .{});
                    try formatMaybeResolverPrefix(otm.child_resolver, otm.child_name, stdout);
                    try stdout.print(" while offline.\n", .{});
                    try stdout.print("It is required by ", .{});
                    try formatMaybeResolverPrefix(otm.parent_resolver, otm.parent_name, stdout);
                    try stdout.print("@{s} from local store manifest:\n", .{otm.parent_version});
                    try stdout.print("  {s}\n\n", .{otm.parent_manifest_path});
                    try stdout.print("Required constraint:\n", .{});
                    try stdout.print("  {s} {s}\n\n", .{otm.child_name, otm.child_constraint});
                    try stdout.print("No compatible artifact was found in the local store.\n", .{});
                },
                .locked_artifact_missing => |lam| {
                    try stdout.print("Error: Locked artifact is missing from the local store.\n\n", .{});
                    try stdout.print("Package:\n  ", .{});
                    try formatMaybeResolverPrefix(lam.resolver, lam.name, stdout);
                    try stdout.print("@{s}\n\n", .{lam.version});
                    try stdout.print("Expected artifact:\n  {s}\n\n", .{lam.artifact_hash});
                    try stdout.print("The lockfile requires this exact artifact, but it was not found.\n", .{});
                    try stdout.print("Run without --locked to resolve/rebuild, or restore the\n", .{});
                    try stdout.print("artifact into the local store.\n", .{});
                },
            }
        } else {
            if (err == error.NotInsideMoonstoneProject or err == error.MissingMoonstoneToml or err == error.NoProjectFound) {
                try stdout.print("Error: not inside a Moonstone project. Run 'moon init' first, or retry from a directory containing moonstone.toml.\n", .{});
            } else if (err == error.RocksVersionDiscoveryFailed) {
                try stdout.print("Error: LuaRocks registry is unreachable or returned an invalid manifest. Check network connectivity, MOONSTONE_LUAROCKS_URL, or retry with --offline if the package is already cached.\n", .{});
            } else if (err == error.RockspecNotFound) {
                try stdout.print("Error: LuaRocks package metadata was found, but no usable rockspec was available for the selected version.\n", .{});
            } else if (err == error.PackageNotFound) {
                try stdout.print("Error: package not found or no compatible version was available.\n", .{});
            } else if (err == error.LockfileOutOfSync) {
                try stdout.print("Error: moonstone.lock is out of sync with moonstone.toml. Run 'moon sync' to update it.\n", .{});
            } else {
                try stdout.print("Error: {s} during {s}\n", .{ @errorName(err), about });
            }
        }
    }
}

pub const ResolveCallbackContext = struct {
    io: std.Io,
    stdout: *std.Io.Writer,
    emitter: ?*@import("ndjson.zig").Emitter = null,
};

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
                context.stdout.print("Retrying {s} due to {s} (attempt {d}/{d}, waiting {d}s)...\n", .{
                    r.url, r.err_name, r.attempt, r.max_retries, r.delay_seconds,
                }) catch {};
            }
        },
        .status => |s| {
            if (context.emitter) |e| {
                e.emit(context.io, .INFO, s.pkg_name, s.msg, .{}) catch {};
            } else {
                context.stdout.print("{s}: {s}\n", .{ s.pkg_name, s.msg }) catch {};
            }
        },
    }
}


pub fn moonstone_sqlite_transient() @import("moonstone").store.driver.c.sqlite3_destructor_type {
    return @import("moonstone").store.driver.moonstone_sqlite_transient_ptr;
}
