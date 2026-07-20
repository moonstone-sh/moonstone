const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const ndjson = @import("ndjson.zig");

pub const ConfigResetCommand = struct {
    pub const name = "reset";
    pub const description = "Reset user configuration to defaults";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon config reset [flags]
            \\
            \\Reset user configuration to default settings.
            \\
            \\Flags:
            \\  --json    Output result as JSON
            \\
        , .{});
    }

    pub fn run(self: ConfigResetCommand, ctx: *router.Context) !void {
        try resetConfig(ctx.allocator, ctx.io, ctx.stdout, ctx.env, self.json);
    }
};

pub fn resetConfig(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map, is_json: bool) !void {
    var paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
    defer paths.deinit(allocator);

    const config_file = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
    defer allocator.free(config_file);

    std.Io.Dir.cwd().deleteFile(io, config_file) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, stdout, ConfigResetCommand.name);
        try emitter.terminate(io, ConfigResetCommand.name, "ok", .{
            .config_file = config_file,
        });
    } else {
        try stdout.print("Reset user configuration to defaults ({s}).\n", .{config_file});
    }
}
