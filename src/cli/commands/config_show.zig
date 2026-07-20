const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const router = @import("../router.zig");

pub const ConfigShowCommand = struct {
    pub const name = "show";
    pub const description = "Display active Moonstone configuration paths and settings";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon config show [flags]
            \\
            \\Display active Moonstone configuration paths and build settings.
            \\
            \\Flags:
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: ConfigShowCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
        defer paths.deinit(allocator);

        const config_file = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
        defer allocator.free(config_file);

        if (self.json) {
            var emitter = @import("ndjson.zig").Emitter.init(allocator, stdout, name);
            try emitter.terminate(io, name, "ok", .{
                .version = build_options.version,
                .installation_ownership = @tagName(build_options.installation_ownership),
                .distribution_label = build_options.distribution_label,
                .default_installer_url = build_options.default_installer_url,
                .default_registry_url = build_options.default_registry_url,
                .config_dir = paths.config,
                .config_file = config_file,
                .data_dir = paths.data,
                .store_dir = paths.store,
                .cache_dir = paths.cache,
            });
        } else {
            try stdout.print("Moonstone Configuration:\n", .{});
            try stdout.print("  Version:                {s}\n", .{build_options.version});
            try stdout.print("  Installation Ownership: {s}\n", .{@tagName(build_options.installation_ownership)});
            try stdout.print("  Distribution Label:     {s}\n", .{build_options.distribution_label});
            try stdout.print("  Default Installer URL:  {s}\n", .{build_options.default_installer_url});
            try stdout.print("  Default Registry URL:   {s}\n", .{build_options.default_registry_url});
            try stdout.print("  Config Directory:       {s}\n", .{paths.config});
            try stdout.print("  Config File:            {s}\n", .{config_file});
            try stdout.print("  Data Directory:         {s}\n", .{paths.data});
            try stdout.print("  Store Directory:        {s}\n", .{paths.store});
            try stdout.print("  Cache Directory:        {s}\n", .{paths.cache});
        }
    }
};
