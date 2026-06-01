const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const RegistryListCommand = struct {
    pub const name = "list";
    pub const description = "List configured registries";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon registry list [flags]
            \\
            \\List all Moonstone registries configured for the current project.
            \\
            \\Flags:
            \\  --json    Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn run(self: RegistryListCommand, ctx: *router.Context) !void {
        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        var emitter_obj = if (self.json) ndjson.Emitter.init(ctx.allocator, ctx.stdout, "registry-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, toml_path, ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
        defer mt.deinit(ctx.allocator);

        if (emitter) |e| {
            try e.emit(ctx.io, .START, "registry-list", "begin", .{});
        } else {
            try ctx.stdout.print("Project registries:\n", .{});
        }

        var it = mt.registries.iterator();
        while (it.next()) |entry| {
            const r_name = entry.key_ptr.*;
            const config = entry.value_ptr.*;
            const val = config.url orelse config.path orelse "unknown";

            if (emitter) |e| {
                try e.emit(ctx.io, .STATUS, r_name, "entry", .{ .name = r_name, .value = val });
            } else {
                try ctx.stdout.print("  {s: <15} {s}\n", .{ r_name, val });
            }
        }

        if (emitter) |e| {
            try e.terminate(ctx.io, "registry-list", "ok", .{});
        }
    }
};
