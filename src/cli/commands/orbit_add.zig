const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const OrbitAddCommand = struct {
    pub const command_name = "add";
    pub const description = "Add a child Moonstone project as an orbit";

    name: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit add --name <name> --path <child-project-path>
            \\
            \\Add a child Moonstone project to the current project's orbit members.
            \\The path must resolve to a strict subdirectory of the current project and
            \\must contain a valid moonstone.toml file.
            \\
            \\Flags:
            \\  --name <name>    Unique orbit name
            \\  --path <path>    Child project directory
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        if (args.len < 2 or !std.mem.eql(u8, args[args.len - 2], "--path")) return &.{};

        const prefix = args[args.len - 1];
        const project_root = moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".") catch return &.{};
        defer project_root.deinit(ctx.allocator);

        const result = std.process.run(ctx.allocator, ctx.io, .{
            .argv = &.{ "find", project_root.path, "-type", "f", "-name", "moonstone.toml", "-not", "-path", "*/.moonstone/*" },
        }) catch return &.{};
        defer ctx.allocator.free(result.stdout);
        defer ctx.allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return &.{};

        const root_manifest_path = try std.fs.path.join(ctx.allocator, &.{ project_root.path, "moonstone.toml" });
        defer ctx.allocator.free(root_manifest_path);

        var paths = std.ArrayList([]const u8).empty;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |manifest_path| {
            if (manifest_path.len == 0 or std.mem.eql(u8, manifest_path, root_manifest_path)) continue;
            const child_path = std.fs.path.dirname(manifest_path) orelse continue;
            const relative_path = try std.fs.path.relative(ctx.allocator, project_root.path, null, project_root.path, child_path);
            if (!std.mem.startsWith(u8, relative_path, prefix)) {
                ctx.allocator.free(relative_path);
                continue;
            }
            try paths.append(ctx.allocator, relative_path);
        }
        return paths.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: OrbitAddCommand, ctx: *router.Context) !void {
        const orbit_name = self.name orelse return missingFlag(ctx, "--name");
        const requested_path = self.path orelse return missingFlag(ctx, "--path");
        if (orbit_name.len == 0) return fail(ctx, "Orbit name cannot be empty.");

        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        const child_path = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, requested_path, ctx.allocator) catch {
            return fail(ctx, "Orbit path must name an existing child project directory.");
        };
        defer ctx.allocator.free(child_path);

        if (!isStrictChildPath(project_root.path, child_path)) {
            return fail(ctx, "Orbit path must be a subdirectory of the current Moonstone project.");
        }

        const child_manifest_path = try std.fs.path.join(ctx.allocator, &.{ child_path, "moonstone.toml" });
        defer ctx.allocator.free(child_manifest_path);
        const child_manifest_content = std.Io.Dir.cwd().readFileAlloc(ctx.io, child_manifest_path, ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch {
            return fail(ctx, "Orbit path must contain a valid moonstone.toml file.");
        };
        defer ctx.allocator.free(child_manifest_content);
        var child_manifest = moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, child_manifest_content) catch {
            return fail(ctx, "Orbit path must contain a valid moonstone.toml file.");
        };
        defer child_manifest.deinit(ctx.allocator);

        const relative_path = try std.fs.path.relative(ctx.allocator, project_root.path, null, project_root.path, child_path);
        defer ctx.allocator.free(relative_path);

        const root_manifest_content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(root_manifest_content);
        var root_manifest = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, root_manifest_content);
        defer root_manifest.deinit(ctx.allocator);

        for (root_manifest.orbits.items) |orbit| {
            if (std.mem.eql(u8, orbit.name, orbit_name)) {
                return fail(ctx, "An orbit with this name already exists.");
            }
            if (std.mem.eql(u8, orbit.path, relative_path)) {
                return fail(ctx, "An orbit already uses this child project path.");
            }
        }

        try root_manifest.orbits.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, orbit_name),
            .path = try ctx.allocator.dupe(u8, relative_path),
        });
        try writeManifest(ctx, &root_manifest);
        try ctx.stdout.print("Added orbit '{s}' at {s}.\n", .{ orbit_name, relative_path });
    }
};

fn missingFlag(ctx: *router.Context, flag: []const u8) !void {
    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
    ctx.error_detail = .{ .missing_argument = .{ .flag = try ctx.allocator.dupe(u8, flag) } };
    return error.MissingArgument;
}

fn fail(ctx: *router.Context, message: []const u8) !void {
    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
    ctx.error_detail = .{ .message = .{ .msg = try ctx.allocator.dupe(u8, message) } };
    return error.InvalidOrbit;
}

fn isStrictChildPath(root_path: []const u8, child_path: []const u8) bool {
    if (std.mem.eql(u8, root_path, child_path)) return false;
    if (std.mem.eql(u8, root_path, "/")) return std.mem.startsWith(u8, child_path, "/");
    return child_path.len > root_path.len and
        std.mem.startsWith(u8, child_path, root_path) and
        child_path[root_path.len] == std.fs.path.sep;
}

fn writeManifest(ctx: *router.Context, manifest: *const moonstone.domain.manifest.MoonstoneToml) !void {
    var writer = std.Io.Writer.Allocating.init(ctx.allocator);
    defer writer.deinit();
    try manifest.serialize(ctx.allocator, &writer.writer);
    try writer.writer.flush();

    const toml_file = try std.Io.Dir.cwd().createFile(ctx.io, "moonstone.toml", .{});
    defer toml_file.close(ctx.io);
    try toml_file.writeStreamingAll(ctx.io, writer.writer.buffer[0..writer.writer.end]);
}
