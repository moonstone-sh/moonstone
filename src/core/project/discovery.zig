const std = @import("std");

pub const ProjectRoot = struct {
    path: []const u8,

    pub fn deinit(self: ProjectRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn findRoot(allocator: std.mem.Allocator, io: std.Io, start_path: []const u8) !ProjectRoot {
    const search_path = try std.Io.Dir.cwd().realPathFileAlloc(io, start_path, allocator);
    defer allocator.free(search_path);

    var current_path = try allocator.dupe(u8, search_path);
    defer allocator.free(current_path);

    while (true) {
        const manifest_path = try std.fs.path.join(allocator, &.{ current_path, "moonstone.toml" });
        defer allocator.free(manifest_path);

        if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
            return .{ .path = try allocator.dupe(u8, current_path) };
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const parent = std.fs.path.dirname(current_path) orelse break;
        if (std.mem.eql(u8, parent, current_path)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current_path);
        current_path = next;
    }

    return error.NotInsideMoonstoneProject;
}

pub fn enterRoot(allocator: std.mem.Allocator, io: std.Io, start_path: []const u8) !ProjectRoot {
    const root = try findRoot(allocator, io, start_path);
    errdefer root.deinit(allocator);
    try std.process.setCurrentPath(io, root.path);
    return root;
}
