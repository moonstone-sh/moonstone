const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");
const run_command = @import("run.zig").RunCommand;

pub const OrbitRunCommand = struct {
    pub const name = "run";
    pub const description = "Run a named script inside a child orbit environment";

    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit run <orbit> <script> [args...]
            \\
            \\Executes a script inside the isolated environment of a child orbit.
            \\The current working directory will be temporarily changed to the orbit's path.
            \\
            \\Example:
            \\  moon orbit run openresty serve --port 8080
            \\
        , .{});
    }

    pub fn run(self: OrbitRunCommand, ctx: *router.Context) !void {
        if (self.positionals.len < 2) {
            try ctx.stdout.print(
                \\Usage: moon orbit run <orbit> <script> [args...]
                \\
            , .{});
            return error.MissingArgument;
        }

        const target = self.positionals[0];
        const script_args = self.positionals[1..];

        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
        defer mt.deinit(ctx.allocator);

        const orbits = try moonstone.project.orbits.resolveOrbits(ctx.allocator, ctx.io, project_root.path, &mt);
        defer {
            for (orbits) |*o| o.deinit(ctx.allocator);
            ctx.allocator.free(orbits);
        }

        const target_abs = try std.fs.path.resolve(ctx.allocator, &.{ project_root.path, target });
        defer ctx.allocator.free(target_abs);

        var selected_orbit: ?moonstone.project.orbits.OrbitRef = null;
        for (orbits) |orbit| {
            if (std.mem.eql(u8, orbit.name, target) or 
                std.mem.eql(u8, orbit.package_name, target) or 
                std.mem.eql(u8, orbit.path, target_abs)) {
                
                if (selected_orbit != null) {
                    try ctx.stdout.print("Ambiguous orbit selector \"{s}\":\n", .{target});
                    try ctx.stdout.print("Use the orbit path or exact name.\n", .{});
                    return error.AmbiguousOrbit;
                }
                
                selected_orbit = orbit;
            }
        }

        if (selected_orbit == null) {
            try ctx.stdout.print("Unknown orbit \"{s}\".\nRun `moon orbit list` to see available orbits.\n", .{target});
            if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
            ctx.error_detail = .{ .orbit_not_found = .{ .orbit = try ctx.allocator.dupe(u8, target) } };
            return error.OrbitNotFound;
        }

        const orbit = selected_orbit.?;
        const root_cwd = project_root.path;

        try std.process.setCurrentPath(ctx.io, orbit.path);
        defer std.process.setCurrentPath(ctx.io, root_cwd) catch {};

        var r_cmd = run_command{
            .positionals = script_args,
        };

        try r_cmd.run(ctx);
    }
};
