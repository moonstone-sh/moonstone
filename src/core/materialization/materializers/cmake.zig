const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("../../domain/manifest.zig");
const command = @import("command.zig");

pub const install_staging_dir_name = ".moonstone-cmake-install";

/// Controls ownership of CMake's private install tree after the build exits.
/// Generic materialization promotes declared outputs during the build and can
/// discard it immediately. LuaRocks materialization needs to inspect and
/// promote the staged install tree after CMake returns.
pub const InstallStagingDisposition = enum {
    cleanup,
    preserve_for_caller,
};

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
    install_staging_disposition: InstallStagingDisposition,
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
    const lua_lib = try std.fs.path.join(allocator, &.{ runtime_path, "files", "lib" });
    defer allocator.free(lua_lib);
    const lua_link_library = try command.findLuaLinkLibrary(allocator, io, lua_lib) orelse return error.RuntimeLuaLibraryNotFound;
    defer allocator.free(lua_link_library);
    const lua_bin = try std.fs.path.join(allocator, &.{ runtime_path, "files", "bin", "lua" });
    defer allocator.free(lua_bin);
    const lua_libfile = std.fs.path.basename(lua_link_library);

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
    const lua_share_dir = try std.fs.path.join(allocator, &.{ install_dir, "share", "lua", lua_abi });
    defer allocator.free(lua_share_dir);
    const lua_cmodule_dir = try std.fs.path.join(allocator, &.{ install_dir, "lib", "lua", lua_abi });
    defer allocator.free(lua_cmodule_dir);

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

    // LuaRocks CMake definitions use this marker for install destinations.
    // It is resolved here, where the disposable staging root exists, rather
    // than letting a rock write directly into Moonstone's final artifact tree.
    // Other Moonstone placeholders are expanded later by command.build_internal.
    for (config.ldflags) |arg| {
        const expanded_install = try std.mem.replaceOwned(u8, allocator, arg, "${cmake.install}", install_dir);
        defer allocator.free(expanded_install);
        const fully_expanded = try command.expandVariables(allocator, expanded_install, out_dir_path, source_dir_path, build_dir, lua_include, lua_lib, lua_link_library, lua_bin, lua_abi);
        try conf_args.append(allocator, fully_expanded);
    }

    // Present the selected runtime using LuaRocks' CMake variable contract.
    // Append these after source-rock definitions so Moonstone's projected
    // runtime cannot be replaced by a literal `${runtime.*}` placeholder or a
    // host-system Lua discovery result.
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA={s}", .{lua_bin}));
    try conf_args.append(allocator, try allocator.dupe(u8, "-DLUA_BUILD_TYPE=System"));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCDIR={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_LIBDIR={s}", .{lua_lib}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_LIBFILE={s}", .{lua_libfile}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUADIR={s}", .{lua_share_dir}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLIBDIR={s}", .{lua_cmodule_dir}));

    // Keep common FindLua variable spellings aligned with the same runtime.
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCLUDE_DIR={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_INCLUDE_DIRS={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLua_INCLUDE_DIR={s}", .{lua_include}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_LIBRARY={s}", .{lua_link_library}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLUA_LIBRARIES={s}", .{lua_link_library}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLua_LIBRARY={s}", .{lua_link_library}));
    try conf_args.append(allocator, try std.fmt.allocPrint(allocator, "-DLua_LIBRARIES={s}", .{lua_link_library}));

    if (comptime builtin.os.tag == .linux) {
        // Linux CMake modules such as luv intentionally leave Lua symbols for
        // the interpreter to provide. Moonstone's runtime executable does not
        // promise those symbols through its dynamic export table, so link the
        // selected runtime archive into the module closure explicitly. CMake
        // inserts this variable before target objects; use a bounded whole
        // archive group so static Lua objects are retained regardless of that
        // ordering.
        try conf_args.append(allocator, try std.fmt.allocPrint(
            allocator,
            "-DCMAKE_MODULE_LINKER_FLAGS=-Wl,--whole-archive,{s},--no-whole-archive",
            .{lua_link_library},
        ));
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

    if (install_staging_disposition == .cleanup) {
        // The install root is an execution-only staging area. Declared outputs
        // have already been promoted into the artifact workspace; retaining
        // this tree would leak CMake's private layout into the content-addressed
        // closure and make replayed artifacts carry duplicate module files.
        // Cleanup is deliberately best-effort because filesystem error sets
        // differ by target and a failed cleanup cannot invalidate the already-
        // complete artifact.
        std.Io.Dir.cwd().deleteTree(io, install_dir) catch {};
    }
}
