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
        const label = build_options.distribution_label;
        if (self.json) {
            var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, name);
            try emitter.terminate(ctx.io, name, "ok", .{ .version = build_options.version, .revision = build_options.revision, .label = label });
        } else if (build_options.revision.len > 0) {
            // A development build: never mistakable for the release it precedes.
            try ctx.stdout.print("Moonstone v{s}-{s} ({s})\n", .{ build_options.version, build_options.revision, label });
        } else {
            try ctx.stdout.print("Moonstone v{s} ({s})\n", .{ build_options.version, label });
        }
    }
};
