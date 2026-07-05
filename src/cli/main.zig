const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");

const router = @import("router.zig");
const command_mod = @import("commands/command.zig");
const profiler = moonstone.diagnostics.profiler;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    // Use a larger buffer for stdout to avoid frequent drains
    const stdout_buffer = try arena.alloc(u8, 64 * 1024);
    var stdout_writer = std.Io.File.stdout().writer(init.io, stdout_buffer);
    const stdout = &stdout_writer.interface;

    const stderr_buffer = try arena.alloc(u8, 64 * 1024);
    var stderr_writer = std.Io.File.stderr().writer(init.io, stderr_buffer);
    const stderr = &stderr_writer.interface;

    const all_args = try init.minimal.args.toSlice(arena);

    profiler.init(init.environ_map);

    var ctx = router.Context{
        .allocator = arena,
        .io = init.io,
        .stdout = stdout,
        .stderr = stderr,
        .env = init.environ_map,
        .root = null,
        .all_args = all_args,
    };

    const App = router.CommandNode.group("moon", "Moonstone - Modern, deterministic Lua project environments and package management", &.{
        router.CommandNode.from(command_mod.add),
        router.CommandNode.from(command_mod.sync),
        router.CommandNode.from(command_mod.install),
        router.CommandNode.from(command_mod.uninstall),
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

        router.CommandNode.group("store", "Manage content store", &.{
            router.CommandNode.from(command_mod.store.gc),
            router.CommandNode.from(command_mod.store.verify),
            router.CommandNode.from(command_mod.store.path),
            router.CommandNode.from(command_mod.store.list),
            router.CommandNode.from(command_mod.store.query),
        }),

        router.CommandNode.group("index", "Manage metadata index", &.{
            router.CommandNode.from(command_mod.index.rebuild),
            router.CommandNode.from(command_mod.index.check),
            router.CommandNode.from(command_mod.index.stats),
            router.CommandNode.from(command_mod.index.vacuum),
        }),

        router.CommandNode.group("registry", "Manage registries", &.{
            router.CommandNode.from(@import("commands/registry_list.zig").RegistryListCommand),
            router.CommandNode.from(@import("commands/registry_add.zig").RegistryAddCommand),
            router.CommandNode.from(@import("commands/registry_remove.zig").RegistryRemoveCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistryCreateCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistrySyncCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistryPushCommand),
            router.CommandNode.from(@import("commands/registry_file.zig").RegistryPurgeCommand),
        }),

        router.CommandNode.group("cache", "Manage Moonstone caches", &.{
            router.CommandNode.group("manifest", "Manage cached package manifests and indexes", &.{
                router.CommandNode.from(command_mod.cache.manifest.list),
                router.CommandNode.from(command_mod.cache.manifest.refresh),
                router.CommandNode.from(command_mod.cache.manifest.path),
                router.CommandNode.from(command_mod.cache.manifest.clear),
            }),
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
            router.CommandNode.from(@import("commands/orbit_list.zig").OrbitListCommand),
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
}
