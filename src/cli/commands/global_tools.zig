const std = @import("std");
const moonstone = @import("moonstone");

pub const EnteredProject = struct {
    previous: []const u8,
    path: []const u8,
};

pub fn projectPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) ![]const u8 {
    const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }
    return try std.fs.path.join(allocator, &.{ paths.projects, "global-tools" });
}

pub fn ensureProject(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) ![]const u8 {
    const path = try projectPath(allocator, env, io);
    errdefer allocator.free(path);

    try std.Io.Dir.cwd().createDirPath(io, path);

    const toml_path = try std.fs.path.join(allocator, &.{ path, "moonstone.toml" });
    defer allocator.free(toml_path);

    std.Io.Dir.cwd().access(io, toml_path, .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        const content =
            \\[package]
            \\name = "moonstone-global-tools"
            \\version = "0.0.0"
            \\kind = "script"
            \\
            \\[runtime]
            \\name = "lua"
            \\version = "5.4"
            \\abi = "5.4"
            \\
        ;
        const file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    };

    return path;
}

pub fn enterProject(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) !EnteredProject {
    const previous = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    errdefer allocator.free(previous);

    const path = try ensureProject(allocator, env, io);
    errdefer allocator.free(path);

    try std.process.setCurrentPath(io, path);
    return .{ .previous = previous, .path = path };
}

pub fn leaveProject(allocator: std.mem.Allocator, io: std.Io, state: EnteredProject) void {
    std.process.setCurrentPath(io, state.previous) catch {};
    allocator.free(state.previous);
    allocator.free(state.path);
}
