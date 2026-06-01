const std = @import("std");
const build_options = @import("build_options");
const Command = @import("./command.zig").Command;

pub fn run(allocator: std.mem.Allocator, command: Command, io: std.Io, stdout: *std.Io.Writer) !void {
    _ = allocator;
    _ = io;
    const version = build_options.version;

    switch (command) {
        .help_for => |target| {
            const target_tag_name = @tagName(target);
            inline for (std.meta.fields(Command)) |field| {
                if (std.mem.eql(u8, field.name, target_tag_name)) {
                    const T = field.type;
                    if (target == .completions) {
                        const help_text = @import("./completions.zig").CompletionsCommand.help;
                        try stdout.print("{s}\n", .{help_text});
                        return;
                    }
                    if (@hasDecl(T, "help")) {
                        const help_text = T.help;
                        try stdout.print("{s}\n", .{help_text});
                        return;
                    }
                }
            }
            try stdout.print("Help for {s} is not yet implemented.\n", .{target_tag_name});
        },
        else => {
            try stdout.print(
                \\Moonstone v{s} - Deterministic Lua project environments
                \\
                \\Usage: moon [global flags] <command> [arguments]
                \\
                \\Commands:
                \\  init            Create a new project
                \\  add             Add dependencies (modifies moonstone.toml)
                \\  use             Select runtime (updates moonstone.toml)
                \\  sync            Synchronize and link project environment
                \\  run             Run named script from [scripts]
                \\  exec            Run arbitrary command inside environment
                \\  env             Print env / shell activation
                \\  runtime         Manage Lua runtimes
                \\  store           Inspect/verify/gc content store
                \\  index           Rebuild/check SQLite index
                \\  registry        Manage registries
                \\  help            Print this help message
                \\
            , .{version});
        },
    }
}

test "help general output contains version and commands" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const cmd = Command{ .help = .{} };
    try run(std.testing.allocator, cmd, std.testing.io, &aw.writer);

    const output = aw.writer.buffered();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "moonstone"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "init"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "add"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "sync"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "run"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "exec"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "env"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "help"));
}

test "help for init command contains init usage" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const cmd = Command{ .help_for = .init };
    try run(std.testing.allocator, cmd, std.testing.io, &aw.writer);

    const output = aw.writer.buffered();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Usage: moon init"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "--name"));
}

test "help for add command contains add usage" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const cmd = Command{ .help_for = .add };
    try run(std.testing.allocator, cmd, std.testing.io, &aw.writer);

    const output = aw.writer.buffered();
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Usage: moon add"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "--dev"));
}
