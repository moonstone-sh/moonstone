const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const OrbitRemoveCommand = struct {
    pub const name = "remove";
    pub const description = "Remove an orbit declaration by name";

    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit remove <name>
            \\
            \\Remove an orbit declaration from the current project's moonstone.toml.
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        const prefix = if (args.len > 0) args[args.len - 1] else "";
        const project_root = moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".") catch return &.{};
        defer project_root.deinit(ctx.allocator);
        const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch return &.{};
        defer ctx.allocator.free(content);
        var manifest = moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content) catch return &.{};
        defer manifest.deinit(ctx.allocator);

        var names = std.ArrayList([]const u8).empty;
        for (manifest.orbits.items) |orbit| {
            if (!std.mem.startsWith(u8, orbit.name, prefix)) continue;
            try names.append(ctx.allocator, try ctx.allocator.dupe(u8, orbit.name));
        }
        return names.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: OrbitRemoveCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return error.MissingArgument;
        const orbit_name = self.positionals[0];

        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);
        const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(content);
        var manifest = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
        defer manifest.deinit(ctx.allocator);

        for (manifest.orbits.items, 0..) |orbit, index| {
            if (!std.mem.eql(u8, orbit.name, orbit_name)) continue;
            const removed = manifest.orbits.orderedRemove(index);
            ctx.allocator.free(removed.name);
            ctx.allocator.free(removed.path);
            try writeManifest(ctx, &manifest);
            try ctx.stdout.print("Removed orbit '{s}'.\n", .{orbit_name});
            return;
        }

        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
        ctx.error_detail = .{ .orbit_not_found = .{ .orbit = try ctx.allocator.dupe(u8, orbit_name) } };
        return error.OrbitNotFound;
    }
};

fn writeManifest(ctx: *router.Context, manifest: *const moonstone.domain.manifest.MoonstoneToml) !void {
    var writer = std.Io.Writer.Allocating.init(ctx.allocator);
    defer writer.deinit();
    try manifest.serialize(ctx.allocator, &writer.writer);
    try writer.writer.flush();

    const toml_file = try std.Io.Dir.cwd().createFile(ctx.io, "moonstone.toml", .{});
    defer toml_file.close(ctx.io);
    try toml_file.writeStreamingAll(ctx.io, writer.writer.buffer[0..writer.writer.end]);
}
