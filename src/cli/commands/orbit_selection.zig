const std = @import("std");
const moonstone = @import("moonstone");
pub fn select(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const root = try moonstone.project.discovery.findRoot(allocator, io, ".");
    defer root.deinit(allocator);
    const manifest_path = try std.fs.path.join(allocator, &.{ root.path, "moonstone.toml" });
    defer allocator.free(manifest_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(bytes);
    var manifest = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, bytes);
    defer manifest.deinit(allocator);
    var selected: ?[]const u8 = null;
    for (manifest.orbits.items) |orbit| {
        if (!std.mem.eql(u8, orbit.name, name)) continue;
        if (selected != null) return error.AmbiguousOrbitName;
        selected = orbit.path;
    }
    const path = try std.fs.path.join(allocator, &.{ root.path, selected orelse return error.OrbitNotFound });
    defer allocator.free(path);
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    errdefer allocator.free(canonical);
    const relative = try std.fs.path.relative(allocator, root.path, null, root.path, canonical);
    defer allocator.free(relative);
    if (std.fs.path.isAbsolute(relative) or relative.len == 0 or std.mem.eql(u8, relative, ".") or std.mem.eql(u8, relative, "..") or std.mem.startsWith(u8, relative, "../") or std.mem.startsWith(u8, relative, "..\\")) return error.OrbitOutsideWorkspace;
    const child_manifest = try std.fs.path.join(allocator, &.{ canonical, "moonstone.toml" });
    defer allocator.free(child_manifest);
    try std.Io.Dir.cwd().access(io, child_manifest, .{});
    return canonical;
}

pub fn complete(ctx: *@import("../router.zig").Context) anyerror![]const []const u8 {
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
