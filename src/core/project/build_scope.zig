const std = @import("std");
const builtin = @import("builtin");
const environment = @import("environment.zig");

/// A materialization-only environment assembled from already selected build
/// artifacts. It is intentionally process-local: callers must not link these
/// paths into `.moonstone/env` or treat them as runtime dependency edges.
pub const BuildScope = struct {
    env_map: std.process.Environ.Map,

    pub fn deinit(self: *BuildScope) void {
        self.env_map.deinit();
    }
};

/// The `files/` directory of one selected build artifact. Input order is
/// preserved as environment precedence, so the resolver owns tie-breaking.
pub const ArtifactRoot = struct {
    files_path: []const u8,
};

pub fn project(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_env: *const std.process.Environ.Map,
    artifact_roots: []const ArtifactRoot,
    lua_ver_dot: []const u8,
) !BuildScope {
    var final_env = try base_env.clone(allocator);
    errdefer final_env.deinit();

    var bin_paths = std.ArrayList([]const u8).empty;
    defer bin_paths.deinit(allocator);
    var share_paths = std.ArrayList([]const u8).empty;
    defer share_paths.deinit(allocator);
    var lua_lib_paths = std.ArrayList([]const u8).empty;
    defer lua_lib_paths.deinit(allocator);
    var native_lib_paths = std.ArrayList([]const u8).empty;
    defer native_lib_paths.deinit(allocator);
    var owned_paths = std.ArrayList([]u8).empty;
    defer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit(allocator);
    }

    for (artifact_roots) |artifact| {
        try appendExistingPath(allocator, io, &bin_paths, &owned_paths, &.{ artifact.files_path, "bin" });
        try appendExistingPath(allocator, io, &share_paths, &owned_paths, &.{ artifact.files_path, "share", "lua", lua_ver_dot });
        try appendExistingPath(allocator, io, &lua_lib_paths, &owned_paths, &.{ artifact.files_path, "lib", "lua", lua_ver_dot });
        try appendExistingPath(allocator, io, &native_lib_paths, &owned_paths, &.{ artifact.files_path, "lib", "native" });
    }

    try projectPath(allocator, &final_env, base_env, bin_paths.items, native_lib_paths.items);
    try projectLuaPaths(allocator, &final_env, share_paths.items, lua_lib_paths.items, lua_ver_dot);

    return .{ .env_map = final_env };
}

fn appendExistingPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *std.ArrayList([]const u8),
    owned_paths: *std.ArrayList([]u8),
    parts: []const []const u8,
) !void {
    const path = try std.fs.path.join(allocator, parts);
    errdefer allocator.free(path);

    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            allocator.free(path);
            return;
        },
        else => return err,
    };
    directory.close(io);

    try owned_paths.append(allocator, path);
    try paths.append(allocator, path);
}

fn projectPath(
    allocator: std.mem.Allocator,
    final_env: *std.process.Environ.Map,
    base_env: *const std.process.Environ.Map,
    bin_paths: []const []const u8,
    native_lib_paths: []const []const u8,
) !void {
    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);

    try paths.appendSlice(allocator, bin_paths);
    if (comptime builtin.os.tag == .windows) {
        try paths.appendSlice(allocator, native_lib_paths);
    }
    if (base_env.get("PATH")) |old_path| if (old_path.len > 0) {
        try paths.append(allocator, old_path);
    };
    if (paths.items.len > 0) {
        const projected_path = try joinPaths(allocator, paths.items, environment.pathSeparator());
        defer allocator.free(projected_path);
        try final_env.put("PATH", projected_path);
    }

    if (comptime builtin.os.tag != .windows) {
        if (environment.nativeLibraryEnvironmentVariable()) |key| if (native_lib_paths.len > 0) {
            var loader_paths = std.ArrayList([]const u8).empty;
            defer loader_paths.deinit(allocator);
            try loader_paths.appendSlice(allocator, native_lib_paths);
            if (base_env.get(key)) |old_path| if (old_path.len > 0) {
                try loader_paths.append(allocator, old_path);
            };
            const projected_loader_path = try joinPaths(allocator, loader_paths.items, environment.pathSeparator());
            defer allocator.free(projected_loader_path);
            try final_env.put(key, projected_loader_path);
        };
    }
}

fn projectLuaPaths(
    allocator: std.mem.Allocator,
    final_env: *std.process.Environ.Map,
    share_paths: []const []const u8,
    lua_lib_paths: []const []const u8,
    lua_ver_dot: []const u8,
) !void {
    const lua_path = try makeLuaPath(allocator, share_paths);
    defer allocator.free(lua_path);
    const lua_cpath = try makeLuaCpath(allocator, lua_lib_paths);
    defer allocator.free(lua_cpath);

    const lua_ver_suffix = try allocator.dupe(u8, lua_ver_dot);
    defer allocator.free(lua_ver_suffix);
    for (lua_ver_suffix) |*char| {
        if (char.* == '.') char.* = '_';
    }

    const lua_path_key = try std.fmt.allocPrint(allocator, "LUA_PATH_{s}", .{lua_ver_suffix});
    defer allocator.free(lua_path_key);
    const lua_cpath_key = try std.fmt.allocPrint(allocator, "LUA_CPATH_{s}", .{lua_ver_suffix});
    defer allocator.free(lua_cpath_key);

    try final_env.put("LUA_PATH", lua_path);
    try final_env.put("LUA_CPATH", lua_cpath);
    try final_env.put(lua_path_key, lua_path);
    try final_env.put(lua_cpath_key, lua_cpath);
}

fn makeLuaPath(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (paths) |path| {
        if (result.items.len > 0) try result.append(allocator, ';');
        const patterns = try std.fmt.allocPrint(allocator, "{s}/?.lua;{s}/?/init.lua", .{ path, path });
        defer allocator.free(patterns);
        try result.appendSlice(allocator, patterns);
    }
    try result.appendSlice(allocator, ";;");
    return result.toOwnedSlice(allocator);
}

fn makeLuaCpath(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (paths) |path| for (environment.luaCmoduleExtensions()) |extension| {
        if (result.items.len > 0) try result.append(allocator, ';');
        const patterns = try std.fmt.allocPrint(allocator, "{s}/?{s};{s}/?/init{s}", .{ path, extension, path, extension });
        defer allocator.free(patterns);
        try result.appendSlice(allocator, patterns);
    };
    try result.appendSlice(allocator, ";;");
    return result.toOwnedSlice(allocator);
}

fn joinPaths(allocator: std.mem.Allocator, paths: []const []const u8, separator: u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (paths, 0..) |path, index| {
        if (index > 0) try result.append(allocator, separator);
        try result.appendSlice(allocator, path);
    }
    return result.toOwnedSlice(allocator);
}

test "build scope projects selected artifacts without mutating the runtime environment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "first/files/bin");
    try tmp.dir.createDirPath(io, "first/files/share/lua/5.4");
    try tmp.dir.createDirPath(io, "first/files/lib/lua/5.4");
    try tmp.dir.createDirPath(io, "first/files/lib/native");
    try tmp.dir.createDirPath(io, "second/files/bin");
    try tmp.dir.createDirPath(io, "second/files/share/lua/5.4");
    try tmp.dir.createDirPath(io, "second/files/lib/lua/5.4");

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const first = try std.fs.path.join(allocator, &.{ root, "first", "files" });
    defer allocator.free(first);
    const second = try std.fs.path.join(allocator, &.{ root, "second", "files" });
    defer allocator.free(second);
    const first_bin = try std.fs.path.join(allocator, &.{ first, "bin" });
    defer allocator.free(first_bin);
    const second_bin = try std.fs.path.join(allocator, &.{ second, "bin" });
    defer allocator.free(second_bin);
    const first_share = try std.fs.path.join(allocator, &.{ first, "share", "lua", "5.4" });
    defer allocator.free(first_share);
    const second_share = try std.fs.path.join(allocator, &.{ second, "share", "lua", "5.4" });
    defer allocator.free(second_share);

    var base_env = std.process.Environ.Map.init(allocator);
    defer base_env.deinit();
    try base_env.put("PATH", "/host/bin");
    try base_env.put("LUA_PATH", "/host/lua/?.lua;;");

    var scope = try project(allocator, io, &base_env, &.{ .{ .files_path = first }, .{ .files_path = second } }, "5.4");
    defer scope.deinit();

    const expected_path = try std.fmt.allocPrint(allocator, "{s}{c}{s}{c}/host/bin", .{ first_bin, environment.pathSeparator(), second_bin, environment.pathSeparator() });
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, scope.env_map.get("PATH").?);
    try std.testing.expect(std.mem.indexOf(u8, scope.env_map.get("LUA_PATH").?, first_share) != null);
    try std.testing.expect(std.mem.indexOf(u8, scope.env_map.get("LUA_PATH").?, second_share) != null);
    try std.testing.expect(std.mem.indexOf(u8, scope.env_map.get("LUA_PATH").?, first_share).? < std.mem.indexOf(u8, scope.env_map.get("LUA_PATH").?, second_share).?);
    try std.testing.expectEqualStrings("/host/bin", base_env.get("PATH").?);
    try std.testing.expectEqualStrings("/host/lua/?.lua;;", base_env.get("LUA_PATH").?);
}

test "build scope ignores artifact paths that are not materialized" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const missing = try std.fs.path.join(allocator, &.{ root, "missing", "files" });
    defer allocator.free(missing);

    var base_env = std.process.Environ.Map.init(allocator);
    defer base_env.deinit();
    try base_env.put("PATH", "/host/bin");

    var scope = try project(allocator, io, &base_env, &.{.{ .files_path = missing }}, "5.4");
    defer scope.deinit();

    try std.testing.expectEqualStrings("/host/bin", scope.env_map.get("PATH").?);
    try std.testing.expectEqualStrings(";;", scope.env_map.get("LUA_PATH").?);
    try std.testing.expectEqualStrings(";;", scope.env_map.get("LUA_CPATH").?);
}
