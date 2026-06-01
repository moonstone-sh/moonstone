const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const command = @import("command.zig");

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    source_dir_path: []const u8,
    out_dir_path: []const u8,
    runtime_path: []const u8,
    lua_abi: []const u8,
    config: manifest.MaterializeConfig,
) !void {
    // 0. Ensure cmake is available
    {
        const res = std.process.run(allocator, io, .{
            .argv = &.{ "cmake", "--version" },
        }) catch |err| {
            if (err == error.FileNotFound) {

            }
            return err;
        };
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    const lua_include = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    defer allocator.free(lua_include);
    
    const build_dir = try std.fs.path.join(allocator, &.{ out_dir_path, "build" });
    defer allocator.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);

    var steps = std.ArrayList(manifest.CommandStep).empty;
    defer {
        for (steps.items) |s| {
            allocator.free(s.command);
            for (s.args) |a| allocator.free(a);
            allocator.free(s.args);
        }
        steps.deinit(allocator);
    }

    // 1. Configure step
    var conf_args = std.ArrayList([]const u8).empty;
    defer {
        for (conf_args.items) |a| allocator.free(a);
        conf_args.deinit(allocator);
    }

    try conf_args.append(allocator, try allocator.dupe(u8, "-S"));
    try conf_args.append(allocator, try allocator.dupe(u8, source_dir_path));
    try conf_args.append(allocator, try allocator.dupe(u8, "-B"));
    try conf_args.append(allocator, try allocator.dupe(u8, build_dir));
    try conf_args.append(allocator, try allocator.dupe(u8, "-DCMAKE_BUILD_TYPE=Release"));
    
    // Explicitly pass Lua include paths to prevent system discovery
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCLUDE_DIR={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCLUDE_DIRS={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLua_INCLUDE_DIR={s}", .{lua_include}));
    
    // Append user cmake_args
    for (config.cmake_args) |arg| {
        try conf_args.append(allocator, try allocator.dupe(u8, arg));
    }

    try steps.append(allocator, .{
        .command = try allocator.dupe(u8, "cmake"),
        .args = try conf_args.toOwnedSlice(allocator),
    });

    // 2. Build step
    var build_args = std.ArrayList([]const u8).empty;
    defer {
        for (build_args.items) |a| allocator.free(a);
        build_args.deinit(allocator);
    }
    try build_args.append(allocator, try allocator.dupe(u8, "--build"));
    try build_args.append(allocator, try allocator.dupe(u8, build_dir));
    try build_args.append(allocator, try allocator.dupe(u8, "--config"));
    try build_args.append(allocator, try allocator.dupe(u8, "Release"));

    try steps.append(allocator, .{
        .command = try allocator.dupe(u8, "cmake"),
        .args = try build_args.toOwnedSlice(allocator),
    });

    // Create a modified config for the command materializer
    var cmd_config = config;
    cmd_config.steps = steps.items;
    
    // Ensure we use the build dir in collect paths if they are relative
    // Actually, the user should use ${build} or similar if we want to be explicit.
    // Let's add ${build} to the expansion.

    try command.build_internal(allocator, io, env_map, source_dir_path, out_dir_path, runtime_path, lua_abi, cmd_config, build_dir);
}
