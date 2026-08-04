const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const RegistryRemoveCommand = struct {
    pub const name = "remove";
    pub const description = "Remove a registry from the project";

    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry remove <name>
            \\
            \\Remove a Moonstone registry from the project configuration.
            \\
            \\Arguments:
            \\  <name>        Local name of the registry to remove
            \\
        , .{});
    }

    pub fn run(self: RegistryRemoveCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
        defer project_root.deinit(allocator);

        if (self.positionals.len == 0) return error.MissingArgument;
        const r_name = self.positionals[0];

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        if (mt.registries.fetchSwapRemove(r_name)) |entry| {
            allocator.free(entry.key);
            entry.value.deinit(allocator);

            const serialized_manifest = try moonstone.project.manifest_editor.commit(allocator, io, &mt);
            defer allocator.free(serialized_manifest);

            try stdout.print("Removed registry '{s}'.\n", .{r_name});
        } else {
            try stdout.print("Registry '{s}' not found.\n", .{r_name});
        }
    }
};
