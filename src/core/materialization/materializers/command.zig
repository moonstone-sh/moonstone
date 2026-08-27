const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const executable = @import("../../platform/executable.zig");

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
    try build_internal(allocator, io, env_map, source_dir_path, out_dir_path, runtime_path, lua_abi, config, null, log_file_name, on_event, on_event_context);
}

pub fn build_internal(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    source_dir_path: []const u8,
    out_dir_path: []const u8,
    runtime_path: []const u8,
    lua_abi: []const u8,
    config: manifest.MaterializeConfig,
    build_dir: ?[]const u8,
    log_file_name: []const u8,
    on_event: ?@import("../../resolution/options.zig").ResolveCallback,
    on_event_context: ?*anyopaque,
) !void {
    const src_abs = source_dir_path;
    const out_abs = out_dir_path;
    const lua_include = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    defer allocator.free(lua_include);
    const lua_lib = try std.fs.path.join(allocator, &.{ runtime_path, "files", "lib" });
    defer allocator.free(lua_lib);
    const lua_link_library = try findLuaLinkLibrary(allocator, io, lua_lib);
    defer if (lua_link_library) |path| allocator.free(path);
    const lua_bin_dir = try std.fs.path.join(allocator, &.{ runtime_path, "files", "bin" });
    defer allocator.free(lua_bin_dir);

    const bdir = build_dir orelse src_abs;

    // 1. Prepare steps
    const Step = struct { cmd: []const u8, args: []const []const u8 };
    var steps = std.ArrayList(Step).empty;
    defer {
        for (steps.items) |s| {
            allocator.free(s.cmd);
            for (s.args) |a| allocator.free(a);
            allocator.free(s.args);
        }
        steps.deinit(allocator);
    }

    if (config.steps.len > 0) {
        for (config.steps) |s| {
            try steps.append(allocator, .{
                .cmd = try expandVariables(allocator, s.command, out_abs, src_abs, bdir, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi),
                .args = try expandArray(allocator, s.args, out_abs, src_abs, bdir, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi),
            });
        }
    } else if (config.command) |cmd| {
        try steps.append(allocator, .{
            .cmd = try expandVariables(allocator, cmd, out_abs, src_abs, bdir, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi),
            .args = try expandArray(allocator, config.args, out_abs, src_abs, bdir, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi),
        });
    } else return error.MissingCommand;

    // 2. Prepare env
    var final_env = try env_map.clone(allocator);
    defer final_env.deinit();

    // Add default build env
    // Let the system use default CC/CXX unless cross-compiling
    // try final_env.put("CC", "zig cc");
    // try final_env.put("CXX", "zig c++");
    // try final_env.put("AR", "zig ar");
    try final_env.put("LUA_INCDIR", lua_include);
    try final_env.put("LUA_LIBDIR", lua_lib);
    try final_env.put("LUALIB", lua_link_library orelse "");
    try final_env.put("LUA_BINDIR", lua_bin_dir);
    try final_env.put("LUA_ABI", lua_abi);

    for (config.env) |pair| {
        const expanded_val = try expandVariables(allocator, pair.value, out_abs, src_abs, bdir, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi);
        defer allocator.free(expanded_val);
        try final_env.put(pair.key, expanded_val);
    }
    try final_env.put("OUT_DIR", out_abs);

    // 3. Run steps
    for (steps.items) |step| {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        const resolved_command = try resolve_command_from_path(allocator, io, &final_env, step.cmd);
        defer allocator.free(resolved_command);
        try argv.append(allocator, resolved_command);
        try argv.appendSlice(allocator, step.args);

        const res = try std.process.run(allocator, io, .{
            .argv = argv.items,
            .environ_map = &final_env,
            .cwd = .{ .path = src_abs },
        });

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
                    .pkg_name = std.fs.path.basename(out_abs),
                    .command = step.cmd,
                    .stderr_tail = tail,
                    .log_path = log_path,
                } });
            } else {
                const tail_len = @min(res.stderr.len, 2048);
                const tail = res.stderr[res.stderr.len - tail_len ..];
                std.debug.print("\nCommand failed: {s}\n", .{step.cmd});
                if (log_path) |lp| std.debug.print("Full log written to: {s}\n", .{lp});
                std.debug.print("Tail of stderr:\n{s}\n", .{tail});
            }
            if (log_path) |lp| allocator.free(lp);
            return error.CommandFailed;
        }
    }

    // 4. Collect outputs
    try collectOutputs(allocator, io, src_abs, out_abs, bdir, config.collect, lua_abi, lua_include, lua_lib, lua_link_library, lua_bin_dir);
}

pub fn findLuaLinkLibrary(allocator: std.mem.Allocator, io: std.Io, lua_lib_dir: []const u8) !?[]const u8 {
    const candidates = [_][]const u8{
        "liblua.a",
        "libluajit-5.1.a",
        "lua54.lib",
        "lua53.lib",
        "lua52.lib",
        "lua51.lib",
        "lua.lib",
        "liblua.so",
        "libluajit-5.1.so",
        "liblua.dylib",
        "libluajit-5.1.dylib",
    };

    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ lua_lib_dir, candidate });
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    return null;
}

pub fn resolve_command_from_path(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    command: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(command) or
        std.mem.indexOfAny(u8, command, "/\\") != null)
    {
        return try allocator.dupe(u8, command);
    }

    const path_value = env_map.get("PATH") orelse return error.CommandNotFound;
    const separator: u8 = if (comptime @import("builtin").os.tag == .windows) ';' else ':';
    var directories = std.mem.splitScalar(u8, path_value, separator);
    while (directories.next()) |directory| {
        if (directory.len == 0 or !std.fs.path.isAbsolute(directory)) continue;
        if (try executable.resolveInDirectory(allocator, io, directory, command)) |candidate| {
            return candidate;
        }
    }
    return error.CommandNotFound;
}

pub fn expandVariables(
    allocator: std.mem.Allocator,
    input: []const u8,
    out_path: []const u8,
    src_path: []const u8,
    build_path: []const u8,
    lua_include: []const u8,
    lua_lib: []const u8,
    lua_link_library: ?[]const u8,
    lua_bin_dir: []const u8,
    lua_abi: []const u8,
) ![]const u8 {
    var result = try allocator.dupe(u8, input);
    errdefer allocator.free(result);

    const mappings = [_]struct { key: []const u8, val: []const u8 }{
        .{ .key = "${out}", .val = out_path },
        .{ .key = "${source}", .val = src_path },
        .{ .key = "${build}", .val = build_path },
        .{ .key = "${runtime.include}", .val = lua_include },
        .{ .key = "${runtime.lib}", .val = lua_lib },
        .{ .key = "${runtime.lualib}", .val = lua_link_library orelse "" },
        .{ .key = "${runtime.bin_dir}", .val = lua_bin_dir },
        .{ .key = "${lua_abi}", .val = lua_abi },
    };

    for (mappings) |m| {
        const next = try std.mem.replaceOwned(u8, allocator, result, m.key, m.val);
        allocator.free(result);
        result = next;
    }
    return result;
}

fn expandArray(
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
    out_path: []const u8,
    src_path: []const u8,
    build_path: []const u8,
    lua_include: []const u8,
    lua_lib: []const u8,
    lua_link_library: ?[]const u8,
    lua_bin_dir: []const u8,
    lua_abi: []const u8,
) ![]const []const u8 {
    var results = std.ArrayList([]const u8).empty;
    for (inputs) |in| {
        try results.append(allocator, try expandVariables(allocator, in, out_path, src_path, build_path, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi));
    }
    return try results.toOwnedSlice(allocator);
}

fn collectOutputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_path: []const u8,
    out_path: []const u8,
    build_path: []const u8,
    collect: manifest.CollectConfig,
    lua_abi: []const u8,
    lua_include: []const u8,
    lua_lib: []const u8,
    lua_link_library: ?[]const u8,
    lua_bin_dir: []const u8,
) !void {
    const categories = [_][]const manifest.FeatureProvision{
        collect.lua_cmodules,
        collect.lua_modules,
        collect.bins,
        collect.headers,
        collect.native_lib,
    };

    for (categories) |items| {
        for (items) |item| {
            const expanded_src = try expandVariables(allocator, item.path, out_path, src_path, build_path, lua_include, lua_lib, lua_link_library, lua_bin_dir, lua_abi);
            defer allocator.free(expanded_src);

            const src_abs = if (std.fs.path.isAbsolute(expanded_src)) expanded_src else try std.fs.path.join(allocator, &.{ src_path, expanded_src });
            defer if (!std.fs.path.isAbsolute(expanded_src)) allocator.free(src_abs);

            const dest_abs = try std.fs.path.join(allocator, &.{ out_path, item.name });
            defer allocator.free(dest_abs);

            // Skip if source and destination are the same path
            if (std.mem.eql(u8, src_abs, dest_abs)) {
                continue;
            }

            if (std.fs.path.dirname(dest_abs)) |parent| {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }

            const cp_res = try std.process.run(allocator, io, .{
                .argv = &.{ "cp", src_abs, dest_abs },
            });
            defer allocator.free(cp_res.stdout);
            defer allocator.free(cp_res.stderr);
            if (cp_res.term != .exited or cp_res.term.exited != 0) {
                std.log.err("Failed to copy '{s}' to '{s}': {s}", .{ src_abs, dest_abs, cp_res.stderr });
                return error.CopyFailed;
            }
        }
    }
}
