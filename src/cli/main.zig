const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");

const router = @import("router.zig");
const command_mod = @import("commands/command.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    // Use a larger buffer for stdout to avoid frequent drains
    const stdout_buffer = try arena.alloc(u8, 64 * 1024);
    var stdout_writer = std.Io.File.stdout().writer(init.io, stdout_buffer);
    const stdout = &stdout_writer.interface;

    const all_args = try init.minimal.args.toSlice(arena);

    var ctx = router.Context{
        .allocator = arena,
        .io = init.io,
        .stdout = stdout,
        .env = init.environ_map,
        .root = null,
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
        router.CommandNode.from(command_mod.use),
        router.CommandNode.from(command_mod.version),
        router.CommandNode.from(command_mod.env),
        router.CommandNode.from(@import("commands/completions.zig").CompletionsCommand),
        
        router.CommandNode.group("store", "Manage content store", &.{
            router.CommandNode.from(command_mod.store.gc),
            router.CommandNode.from(command_mod.store.verify),
            router.CommandNode.from(command_mod.store.path),
            router.CommandNode.from(command_mod.store.list),
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
        }),
        
        router.CommandNode.group("runtime", "Manage Lua runtimes", &.{
            router.CommandNode.from(@import("commands/runtime_install.zig").RuntimeInstallCommand),
            router.CommandNode.from(@import("commands/runtime_remove.zig").RuntimeRemoveCommand),
            router.CommandNode.from(@import("commands/runtime_list.zig").RuntimeListCommand),
            router.CommandNode.from(@import("commands/runtime_current.zig").RuntimeCurrentCommand),
            router.CommandNode.from(@import("commands/runtime_path.zig").RuntimePathCommand),
        }),
    });

    ctx.root = &App;

    router.dispatch(App, all_args[1..], &ctx) catch |err| {
        if (err == error.AlreadyReported) {
            stdout.flush() catch {};
            std.process.exit(1);
        }
        // Fallback for unexpected errors that escaped router's trap
        command_mod.reportError(arena, init.io, stdout, false, err, "main", ctx.error_detail) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };

    // Final flush, ignore WriteFailed which is usually BrokenPipe at exit
    stdout.flush() catch |err| {
        if (err != error.WriteFailed) return err;
    };
}
