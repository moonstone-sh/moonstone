const std = @import("std");
const manifest = @import("../../domain/manifest.zig");

fn find_lua_include(allocator: std.mem.Allocator, io: std.Io, runtime_path: []const u8) ![]const u8 {
    const include_path = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    errdefer allocator.free(include_path);

    const direct_header = try std.fs.path.join(allocator, &.{ include_path, "lua.h" });
    defer allocator.free(direct_header);
    if (std.Io.Dir.cwd().access(io, direct_header, .{})) |_| return include_path else |err| {
        if (err != error.FileNotFound) return err;
    }

    var include_dir = try std.Io.Dir.cwd().openDir(io, include_path, .{ .iterate = true });
    defer include_dir.close(io);
    var iterator = include_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const nested_path = try std.fs.path.join(allocator, &.{ include_path, entry.name });
        const nested_header = try std.fs.path.join(allocator, &.{ nested_path, "lua.h" });
        defer allocator.free(nested_header);
        if (std.Io.Dir.cwd().access(io, nested_header, .{})) |_| {
            allocator.free(include_path);
            return nested_path;
        } else |err| {
            allocator.free(nested_path);
            if (err != error.FileNotFound) return err;
        }
    }

    return include_path;
}

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    source_dir_path: []const u8,
    out_dir_path: []const u8,
    runtime_path: []const u8,
    config: manifest.MaterializeConfig,
    target: []const u8,
    log_file_name: []const u8,
    on_event: ?@import("../../resolution/options.zig").ResolveCallback,
    on_event_context: ?*anyopaque,
) !void {
    const builtin = @import("builtin");
    const is_macos = builtin.os.tag == .macos;

    // 1. Resolve Lua headers path
    const lua_include = try find_lua_include(allocator, io, runtime_path);
    defer allocator.free(lua_include);

    // 2. Prepare argv for zig cc
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "zig");
    try argv.append(allocator, "cc");

    if (target.len > 0) {
        try argv.append(allocator, "-target");
        try argv.append(allocator, target);
    }

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

    // Apply custom LDFLAGS
    for (config.ldflags) |flag| {
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
            return error.CompilerNotFound;
        }
        return err;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        var log_path: ?[]const u8 = null;
        if (std.Io.Dir.cwd().openDir(io, ".moonstone", .{})) |moon_dir| {
            if (moon_dir.createDirPath(io, "logs/build")) |_| {
                const log_full_path = try std.fs.path.join(allocator, &.{ ".moonstone", "logs", "build", log_file_name });
                if (std.Io.Dir.cwd().createFile(io, log_full_path, .{})) |log_file| {
                    log_file.writeStreamingAll(io, "=== STDOUT ===\n") catch {};
                    log_file.writeStreamingAll(io, res.stdout) catch {};
                    log_file.writeStreamingAll(io, "\n=== STDERR ===\n") catch {};
                    log_file.writeStreamingAll(io, res.stderr) catch {};
                    log_file.close(io);
                    log_path = log_full_path;
                } else |_| {
                    allocator.free(log_full_path);
                }
            } else |_| {}
            moon_dir.close(io);
        } else |_| {}

        if (on_event) |cb| {
            const tail_len = @min(res.stderr.len, 2048);
            const tail = res.stderr[res.stderr.len - tail_len ..];
            cb(on_event_context, .{ .build_failed = .{
                .pkg_name = std.fs.path.basename(out_dir_path),
                .command = "zig cc",
                .stderr_tail = tail,
                .log_path = log_path,
            }});
        } else {
            const tail_len = @min(res.stderr.len, 2048);
            const tail = res.stderr[res.stderr.len - tail_len ..];
            std.debug.print("native module compilation failed:\n", .{});
            if (log_path) |lp| std.debug.print("Full log written to: {s}\n", .{lp});
            std.debug.print("Tail of stderr:\n{s}\n", .{tail});
        }
        if (log_path) |lp| allocator.free(lp);
        return error.CompilationFailed;
    }
}
