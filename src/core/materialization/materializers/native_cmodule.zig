const std = @import("std");
const manifest = @import("../../domain/manifest.zig");

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    source_dir_path: []const u8,
    out_dir_path: []const u8,
    runtime_path: []const u8,
    config: manifest.MaterializeConfig,
) !void {
    const builtin = @import("builtin");
    const is_macos = builtin.os.tag == .macos;

    // 1. Resolve Lua headers path
    const lua_include = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    defer allocator.free(lua_include);

    // 2. Prepare argv for zig cc
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "cc");

    try argv.append(allocator, "-shared");
    try argv.append(allocator, "-fPIC");

    if (is_macos) {
        // macOS specific flags for Lua modules
        try argv.append(allocator, "-undefined");
        try argv.append(allocator, "dynamic_lookup");
    }

    try argv.append(allocator, "-I");
    try argv.append(allocator, lua_include);

    // Apply custom CFLAGS (stored in .args)
    for (config.args) |flag| {
        try argv.append(allocator, flag);
    }

    // Output path
    const output_abs_path = try std.fs.path.join(allocator, &.{ out_dir_path, config.output.?.path });
    defer allocator.free(output_abs_path);

    // Ensure output parent directory exists
    const output_dir = std.fs.path.dirname(output_abs_path) orelse return error.InvalidOutputPath;
    try std.Io.Dir.cwd().createDirPath(io, output_dir);

    try argv.append(allocator, "-o");
    try argv.append(allocator, output_abs_path);

    // Apply custom LDFLAGS (stored in .cmake_args)
    for (config.cmake_args) |flag| {
        try argv.append(allocator, flag);
    }

    // Add source files
    var src_paths = std.ArrayList([]const u8).empty;
    defer {
        for (src_paths.items) |p| allocator.free(p);
        src_paths.deinit(allocator);
    }

    for (config.input.?.sources) |src| {
        const src_abs = try std.fs.path.join(allocator, &.{ source_dir_path, src });
        try src_paths.append(allocator, src_abs);
        try argv.append(allocator, src_abs);
    }

    // 3. Spawn compilation
    const res = std.process.run(allocator, io, .{
        .argv = argv.items,
        .environ_map = env_map,
        .cwd = .{ .path = source_dir_path },
    }) catch |err| {
        if (err == error.FileNotFound) {

        }
        return err;
    };

    if (res.term != .exited or res.term.exited != 0) {





        return error.CompilationFailed;
    }
}
