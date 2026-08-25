const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");

const router = @import("router.zig");
const command_mod = @import("commands/command.zig");
const global_options = @import("global_options.zig");
const profiler = moonstone.diagnostics.profiler;

fn applyGlobalConfigFile(
    allocator: std.mem.Allocator,
    raw_args: []const []const u8,
    env: *std.process.Environ.Map,
) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    errdefer args.deinit(allocator);

    if (raw_args.len == 0) return try args.toOwnedSlice(allocator);
    try args.append(allocator, raw_args[0]);

    var index: usize = 1;
    var parsing_global_flags = true;
    while (index < raw_args.len) : (index += 1) {
        const arg = raw_args[index];
        if (parsing_global_flags and std.mem.startsWith(u8, arg, "--config-file=")) {
            const path = arg["--config-file=".len..];
            if (path.len == 0) return error.MissingArgument;
            try env.put("MOONSTONE_CONFIG_FILE", path);
            continue;
        }
        if (parsing_global_flags and std.mem.eql(u8, arg, "--config-file")) {
            index += 1;
            if (index >= raw_args.len) return error.MissingArgument;
            try env.put("MOONSTONE_CONFIG_FILE", raw_args[index]);
            continue;
        }

        try args.append(allocator, arg);
        if (parsing_global_flags and !std.mem.startsWith(u8, arg, "-")) {
            parsing_global_flags = false;
        }
    }

    return try args.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    // Use a larger buffer for stdout to avoid frequent drains
    const stdout_buffer = try arena.alloc(u8, 64 * 1024);
    var stdout_writer = std.Io.File.stdout().writer(init.io, stdout_buffer);
    const stdout = &stdout_writer.interface;

    const stderr_buffer = try arena.alloc(u8, 64 * 1024);
    var stderr_writer = std.Io.File.stderr().writer(init.io, stderr_buffer);
    const stderr = &stderr_writer.interface;

    const raw_args = try init.minimal.args.toSlice(arena);
    const directory_args = try global_options.extractDirectory(arena, raw_args);
    const working_directory = if (directory_args.directory) |directory|
        try std.Io.Dir.cwd().realPathFileAlloc(init.io, directory, arena)
    else
        null;
    if (working_directory) |directory| try moonstone.platform.fs.setCurrentPath(init.io, directory);
    const all_args = try applyGlobalConfigFile(arena, directory_args.args, init.environ_map);

    profiler.init(init.environ_map);

    var ctx = router.Context{
        .allocator = arena,
        .io = init.io,
        .stdout = stdout,
        .stderr = stderr,
        .env = init.environ_map,
        .working_directory = working_directory,
        .root = null,
        .all_args = all_args,
    };

    const App = router.CommandNode.group("moon", "Moonstone - Modern, deterministic Lua project environments and package management\n\nGlobal options:\n  -C, --directory <path>  Change the project-resolution base before dispatch", &.{
        router.CommandNode.from(command_mod.add),
        router.CommandNode.from(command_mod.sync),
        router.CommandNode.from(command_mod.init),
        router.CommandNode.from(command_mod.setup),
        router.CommandNode.from(@import("commands/link.zig").LinkCommand),
        router.CommandNode.from(command_mod.run),
        router.CommandNode.from(command_mod.exec),
        router.CommandNode.from(command_mod.remove),
        router.CommandNode.from(command_mod.list),
        router.CommandNode.from(command_mod.doctor),
        router.CommandNode.from(command_mod.version),
        router.CommandNode.from(command_mod.env),
        router.CommandNode.from(@import("commands/completions.zig").CompletionsCommand),

        router.CommandNode.group("manifest", "Inspect the project manifest through versioned semantic contracts", &.{
            router.CommandNode.from(command_mod.manifest.export_cmd),
            router.CommandNode.from(command_mod.manifest.apply),
            router.CommandNode.from(command_mod.manifest.tidy),
            router.CommandNode.group("script", "Inspect and edit semantic project scripts", &.{
                router.CommandNode.from(command_mod.manifest.script.list),
                router.CommandNode.from(command_mod.manifest.script.get),
                router.CommandNode.from(command_mod.manifest.script.set),
                router.CommandNode.from(command_mod.manifest.script.remove),
            }),
        }),
        router.CommandNode.group("lock", "Inspect and verify the project lockfile through versioned semantic contracts", &.{
            router.CommandNode.from(command_mod.lock.export_cmd),
            router.CommandNode.from(command_mod.lock.verify),
            router.CommandNode.group("profile", "Inspect locked resolution profiles", &.{
                router.CommandNode.from(command_mod.lock.profile_list),
                router.CommandNode.from(command_mod.lock.profile_get),
            }),
            router.CommandNode.group("package", "Inspect locked packages", &.{
                router.CommandNode.from(command_mod.lock.package_list),
                router.CommandNode.from(command_mod.lock.package_get),
            }),
            router.CommandNode.group("realization", "Inspect profile-specific locked realizations", &.{
                router.CommandNode.from(command_mod.lock.realization_list),
                router.CommandNode.from(command_mod.lock.realization_get),
            }),
            router.CommandNode.group("graph", "Export locked profile dependency graphs", &.{
                router.CommandNode.from(command_mod.lock.graph_export),
            }),
        }),

        router.CommandNode.group("self", "Manage Moonstone installation and lifecycle", &.{
            router.CommandNode.from(command_mod.self_cmd.install),
            router.CommandNode.from(command_mod.self_cmd.uninstall),
        }),

        router.CommandNode.group("store", "Manage content store", &.{
            router.CommandNode.from(command_mod.store.prune),
            router.CommandNode.from(command_mod.store.verify),
            router.CommandNode.from(command_mod.store.path),
            router.CommandNode.from(command_mod.store.list),
            router.CommandNode.from(command_mod.store.query),
            router.CommandNode.from(command_mod.store.purge),
        }),

        router.CommandNode.group("index", "Manage metadata index", &.{
            router.CommandNode.from(command_mod.index.rebuild),
            router.CommandNode.from(command_mod.index.check),
            router.CommandNode.from(command_mod.index.stats),
            router.CommandNode.from(command_mod.index.vacuum),
        }),

        router.CommandNode.groupWithFallback("registry", "Manage registries", &.{
            router.CommandNode.from(@import("commands/registry_list.zig").RegistryListCommand),
            router.CommandNode.from(@import("commands/registry_add.zig").RegistryAddCommand),
            router.CommandNode.from(@import("commands/registry_remove.zig").RegistryRemoveCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistryCreateCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistrySyncCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistryPushCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistryPurgeCommand),
        }, @import("commands/registry_target.zig").dispatch, @import("commands/registry_target.zig").complete),

        router.CommandNode.group("cache", "Manage Moonstone caches", &.{
            router.CommandNode.from(command_mod.cache.clean),
            router.CommandNode.group("manifest", "Manage cached package manifests and indexes", &.{
                router.CommandNode.from(command_mod.cache.manifest.list),
                router.CommandNode.from(command_mod.cache.manifest.refresh),
                router.CommandNode.from(command_mod.cache.manifest.path),
                router.CommandNode.from(command_mod.cache.manifest.clear),
            }),
        }),

        router.CommandNode.group("config", "Manage Moonstone configuration", &.{
            router.CommandNode.from(command_mod.config.show),
            router.CommandNode.from(command_mod.config.get),
            router.CommandNode.from(command_mod.config.set),
            router.CommandNode.from(command_mod.config.unset),
            router.CommandNode.from(command_mod.config.reset),
        }),

        router.CommandNode.group("interpreter", "Manage Lua interpreters", &.{
            router.CommandNode.from(command_mod.interpreter.set),
            router.CommandNode.from(@import("commands/interpreter_install.zig").InterpreterInstallCommand),
            router.CommandNode.from(@import("commands/interpreter_remove.zig").InterpreterRemoveCommand),
            router.CommandNode.from(@import("commands/interpreter_list.zig").InterpreterListCommand),
            router.CommandNode.from(@import("commands/interpreter_current.zig").InterpreterCurrentCommand),
            router.CommandNode.from(@import("commands/interpreter_path.zig").InterpreterPathCommand),
        }),

        router.CommandNode.group("orbit", "Manage nested orbit projects", &.{
            router.CommandNode.from(@import("commands/orbit_add.zig").OrbitAddCommand),
            router.CommandNode.from(@import("commands/orbit_list.zig").OrbitListCommand),
            router.CommandNode.from(@import("commands/orbit_remove.zig").OrbitRemoveCommand),
            router.CommandNode.from(@import("commands/orbit_sync.zig").OrbitSyncCommand),
            router.CommandNode.from(@import("commands/orbit_exec.zig").OrbitExecCommand),
            router.CommandNode.from(@import("commands/orbit_run.zig").OrbitRunCommand),
        }),
    });

    ctx.root = &App;

    router.dispatch(App, all_args[1..], &ctx) catch |err| {
        if (err == error.AlreadyReported) {
            stdout.flush() catch {};
            profiler.finish("process.exit.error");
            std.process.exit(1);
        }
        // Fallback for unexpected errors that escaped router's trap
        command_mod.reportError(arena, init.io, stdout, false, err, "main", ctx.error_detail) catch {};
        stdout.flush() catch {};
        profiler.finish("process.exit.error");
        std.process.exit(1);
    };

    profiler.finish("process.exit.ok");

    // Final flush, ignore WriteFailed which is usually BrokenPipe at exit
    stdout.flush() catch |err| {
        if (err != error.WriteFailed) return err;
    };
    stderr.flush() catch |err| {
        if (err != error.WriteFailed) return err;
    };
}
