const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const OrbitListCommand = struct {
    pub const name = "list";
    pub const description = "List configured orbits";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit list [flags]
            \\
            \\List all Moonstone orbits configured for the current project.
            \\
            \\Flags:
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: OrbitListCommand, ctx: *router.Context) !void {
        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        var emitter_obj = if (self.json) ndjson.Emitter.init(ctx.allocator, ctx.stdout, "orbit-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, toml_path, ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
        defer mt.deinit(ctx.allocator);

        const orbits = try moonstone.project.orbits.resolveOrbits(ctx.allocator, ctx.io, project_root.path, &mt);
        defer {
            for (orbits) |*o| o.deinit(ctx.allocator);
            ctx.allocator.free(orbits);
        }

        if (emitter) |e| {
            try e.emit(ctx.io, .START, "orbit-list", "begin", .{});
        } else {
            try ctx.stdout.print("Orbits:\n", .{});
        }

        for (orbits) |orbit| {
            const int_display = try std.fmt.allocPrint(ctx.allocator, "{s}@{s}", .{ orbit.interpreter_name, orbit.interpreter_version });
            defer ctx.allocator.free(int_display);

            const display_path = try std.fs.path.relative(ctx.allocator, project_root.path, null, project_root.path, orbit.path);
            defer ctx.allocator.free(display_path);

            if (emitter) |e| {
                try e.emit(ctx.io, .STATUS, orbit.name, "entry", .{ .name = orbit.name, .path = display_path, .interpreter = int_display });
            } else {
                try ctx.stdout.print("  {s: <15} {s: <22} {s}\n", .{ orbit.name, display_path, int_display });
            }
        }

        if (emitter) |e| {
            try e.terminate(ctx.io, "orbit-list", "ok", .{});
        }
    }
};
