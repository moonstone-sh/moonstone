const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const ManifestExportCommand = struct {
    pub const name = "export";
    pub const description = "Export the project manifest through the versioned JSON protocol";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon manifest export --json
            \\
            \\Export the normalized manifest domain model. This is the stable
            \\machine-facing protocol; it is not a TOML layout dump.
            \\
            \\Flags:
            \\  --json    Required. Emit moonstone:manifest:v1 JSON.
            \\
        , .{});
    }

    pub fn run(self: ManifestExportCommand, ctx: *router.Context) !void {
        if (!self.json) return error.ManifestJsonRequired;

        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        const source = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(source);

        var manifest = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, source);
        defer manifest.deinit(ctx.allocator);
        try moonstone.domain.manifest_protocol.writeExport(&manifest, source, ctx.stdout);
    }
};
