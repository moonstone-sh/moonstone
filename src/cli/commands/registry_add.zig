const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const RegistryAddCommand = struct {
    pub const name = "add";
    pub const description = "Add a new registry to the project";

    positionals: []const []const u8 = &.{},
    name_arg: ?[]const u8 = null,
    url: ?[]const u8 = null,
    default: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry add --name <name> --url <uri> [flags]
            \\       moon registry add <name> <uri> [flags]
            \\
            \\Add a Moonstone registry to the project configuration.
            \\
            \\Arguments:
            \\  <name>        Local registry alias (legacy positional form)
            \\  <uri>         URL or local path (legacy positional form)
            \\
            \\Flags:
            \\  --name <name>  Registry alias: lowercase letters, digits, internal hyphens
            \\  --url <uri>    Registry URL (http(s)://...) or local file path
            \\  --default     Set as the default registry for resolution
            \\
        , .{});
    }

    pub fn run(self: RegistryAddCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
        defer project_root.deinit(allocator);

        const r_name = self.name_arg orelse if (self.positionals.len >= 1) self.positionals[0] else return error.MissingArgument;
        const r_uri = self.url orelse if (self.positionals.len >= 2) self.positionals[1] else return error.MissingArgument;
        if (!moonstone.domain.registry_name.isValid(r_name)) {
            ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, "Registry names must use lowercase letters, digits, and internal hyphens (1-40 characters).") } };
            return error.InvalidRegistryName;
        }

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        var config = moonstone.domain.manifest.RegistryConfig{
            .resolver = try allocator.dupe(u8, "moonstone"),
        };
        if (std.mem.startsWith(u8, r_uri, "http")) {
            config.url = try allocator.dupe(u8, r_uri);
        } else if (std.mem.startsWith(u8, r_uri, "file:")) {
            config.path = try allocator.dupe(u8, r_uri[5..]);
        } else {
            config.path = try allocator.dupe(u8, r_uri);
        }

        try mt.registries.put(allocator, try allocator.dupe(u8, r_name), config);

        const toml_file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
        defer toml_file.close(io);

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try mt.serialize(allocator, &aw.writer);
        try aw.writer.flush();
        try toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

        try stdout.print("Added registry '{s}' to {s}.\n", .{ r_name, toml_path });
    }
};
