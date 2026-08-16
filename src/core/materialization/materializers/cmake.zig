const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const command = @import("command.zig");

pub const install_staging_dir_name = ".moonstone-cmake-install";

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    source_dir_path: []const u8,
    out_dir_path: []const u8,
    runtime_path: []const u8,
    lua_abi: []const u8,
    config: manifest.MaterializeConfig,
    log_file_name: []const u8,
    on_event: ?@import("../../resolution/options.zig").ResolveCallback,
    on_event_context: ?*anyopaque,
) !void {
    // 0. Ensure cmake is available
    {
        const cmake_executable = try command.resolve_command_from_path(allocator, io, env_map, "cmake");
        defer allocator.free(cmake_executable);
        const res = std.process.run(allocator, io, .{
            .argv = &.{ cmake_executable, "--version" },
            .environ_map = env_map,
        }) catch |err| {
            return err;
        };
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    const lua_include = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    defer allocator.free(lua_include);

    // CMake's generated build tree contains host- and run-specific metadata.
    // Keep it in the disposable source workspace. Its install tree is staged
    // below the output workspace and promoted by the LuaRocks resolver only
    // through typed provision declarations.
    const build_dir = try std.fs.path.join(allocator, &.{ source_dir_path, ".moonstone-cmake-build" });
    defer allocator.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);

    const install_dir = try std.fs.path.join(allocator, &.{ out_dir_path, install_staging_dir_name });
    defer allocator.free(install_dir);
    try std.Io.Dir.cwd().createDirPath(io, install_dir);

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
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DCMAKE_INSTALL_PREFIX={s}", .{install_dir}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_ABI={s}", .{lua_abi}));

    // Explicitly pass Lua include paths to prevent system discovery
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCLUDE_DIR={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCLUDE_DIRS={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLua_INCLUDE_DIR={s}", .{lua_include}));

    // LuaRocks CMake definitions use this marker for install destinations.
    // It is resolved here, where the disposable staging root exists, rather
    // than letting a rock write directly into Moonstone's final artifact tree.
    // Other Moonstone placeholders are expanded later by command.build_internal.
    for (config.ldflags) |arg| {
        const expanded = try std.mem.replaceOwned(u8, allocator, arg, "${cmake.install}", install_dir);
        try conf_args.append(allocator, expanded);
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

    // 3. Install step. The resolver promotes CMake's staged install tree into
    // the final artifact root only through recognized module roots and explicit
    // rockspec declarations.
    var install_args = std.ArrayList([]const u8).empty;
    defer {
        for (install_args.items) |a| allocator.free(a);
        install_args.deinit(allocator);
    }
    try install_args.append(allocator, try allocator.dupe(u8, "--install"));
    try install_args.append(allocator, try allocator.dupe(u8, build_dir));
    try install_args.append(allocator, try allocator.dupe(u8, "--prefix"));
    try install_args.append(allocator, try allocator.dupe(u8, install_dir));
    try install_args.append(allocator, try allocator.dupe(u8, "--config"));
    try install_args.append(allocator, try allocator.dupe(u8, "Release"));

    try steps.append(allocator, .{
        .command = try allocator.dupe(u8, "cmake"),
        .args = try install_args.toOwnedSlice(allocator),
    });

    // Create a modified config for the command materializer
    var cmd_config = config;
    cmd_config.steps = steps.items;

    try command.build_internal(allocator, io, env_map, source_dir_path, out_dir_path, runtime_path, lua_abi, cmd_config, build_dir, log_file_name, on_event, on_event_context);

    // The install root is an execution-only staging area. Declared outputs
    // have already been promoted into the artifact workspace; retaining this
    // tree would leak CMake's private layout into the content-addressed
    // closure and make replayed artifacts carry duplicate module files.
    // Cleanup occurs only after the staged outputs have been promoted. It is
    // deliberately best-effort because filesystem error sets differ by target
    // and a failed cleanup cannot invalidate the already-complete artifact.
    std.Io.Dir.cwd().deleteTree(io, install_dir) catch {};
}
