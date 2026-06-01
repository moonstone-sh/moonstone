const std = @import("std");
const build_options = @import("build_options");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const VersionCommand = struct {
    pub const name = "version";
    pub const description = "Print version information";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon version [flags]
            \\
            \\Print Moonstone version information.
            \\
            \\Flags:
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: VersionCommand, ctx: *router.Context) !void {
        if (self.json) {
            var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, name);
            try emitter.terminate(ctx.io, name, "ok", .{ .version = build_options.version });
        } else {
            try ctx.stdout.print("Moonstone v{s}\n", .{build_options.version});
        }
    }
};
