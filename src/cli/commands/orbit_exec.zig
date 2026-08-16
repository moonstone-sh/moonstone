const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");
const exec_command = @import("exec.zig").ExecCommand;

pub const OrbitExecCommand = struct {
    pub const name = "exec";
    pub const description = "Run arbitrary command inside a child orbit environment";
    pub const opaque_arguments_after = 2;

    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit exec <orbit> [--] <command> [-- [args...]]
            \\
            \\Executes a command inside the isolated environment of a child orbit.
            \\The current working directory will be temporarily changed to the orbit's path.
            \\
            \\Example:
            \\  moon orbit exec openresty resty -- app.lua
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        _ = args;
        const project_root = moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".") catch return &.{};
        defer project_root.deinit(ctx.allocator);
        const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch return &.{};
        defer ctx.allocator.free(content);
        var mt = moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content) catch return &.{};
        defer mt.deinit(ctx.allocator);

        const orbits = moonstone.project.orbits.resolveOrbits(ctx.allocator, ctx.io, project_root.path, &mt) catch return &.{};
        defer {
            for (orbits) |*o| o.deinit(ctx.allocator);
            ctx.allocator.free(orbits);
        }

        var list = std.ArrayList([]const u8).empty;
        for (orbits) |orbit| {
            try list.append(ctx.allocator, try ctx.allocator.dupe(u8, orbit.name));
        }
        return list.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: OrbitExecCommand, ctx: *router.Context) !void {
        if (self.positionals.len < 2) {
            try ctx.stdout.print(
                \\Usage: moon orbit exec <orbit> [--] <cmd...>
                \\
            , .{});
            return error.MissingArgument;
        }

        const target = self.positionals[0];
        const remaining_args = self.positionals[1..];
        const cmd_args = if (remaining_args.len > 0 and std.mem.eql(u8, remaining_args[0], "--")) remaining_args[1..] else remaining_args;
        if (cmd_args.len == 0) return error.MissingArgument;

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
                std.mem.eql(u8, orbit.path, target_abs))
            {
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

        var exec_cmd = exec_command{
            .positionals = cmd_args,
        };

        try exec_cmd.run(ctx);
    }
};
