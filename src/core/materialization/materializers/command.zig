const std = @import("std");
const manifest = @import("../../domain/manifest.zig");

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
    try build_internal(allocator, io, env_map, source_dir_path, out_dir_path, runtime_path, lua_abi, config, null);
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
) !void {
    const src_abs = source_dir_path;
    const out_abs = out_dir_path;
    const lua_include = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    defer allocator.free(lua_include);
    const lua_lib = try std.fs.path.join(allocator, &.{ runtime_path, "files", "lib" });
    defer allocator.free(lua_lib);
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
                .cmd = try expandVariables(allocator, s.command, out_abs, src_abs, bdir, lua_include, lua_lib, lua_bin_dir, lua_abi),
                .args = try expandArray(allocator, s.args, out_abs, src_abs, bdir, lua_include, lua_lib, lua_bin_dir, lua_abi),
            });
        }
    } else if (config.command) |cmd| {
        try steps.append(allocator, .{
            .cmd = try expandVariables(allocator, cmd, out_abs, src_abs, bdir, lua_include, lua_lib, lua_bin_dir, lua_abi),
            .args = try expandArray(allocator, config.args, out_abs, src_abs, bdir, lua_include, lua_lib, lua_bin_dir, lua_abi),
        });
    } else return error.MissingCommand;

    // 2. Prepare env
    var final_env = try env_map.clone(allocator);
    defer final_env.deinit();
    
    // Add default build env
    try final_env.put("CC", "zig cc");
    try final_env.put("AR", "zig ar");
    try final_env.put("LUA_INCDIR", lua_include);
    try final_env.put("LUA_LIBDIR", lua_lib);
    try final_env.put("LUA_BINDIR", lua_bin_dir);
    try final_env.put("LUA_ABI", lua_abi);

    for (config.env) |pair| {
        const expanded_val = try expandVariables(allocator, pair.value, out_abs, src_abs, bdir, lua_include, lua_lib, lua_bin_dir, lua_abi);
        defer allocator.free(expanded_val);
        try final_env.put(pair.key, expanded_val);
    }
    try final_env.put("OUT_DIR", out_abs);

    // 3. Run steps
    for (steps.items) |step| {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, step.cmd);
        try argv.appendSlice(allocator, step.args);

        const res = try std.process.run(allocator, io, .{
            .argv = argv.items,
            .environ_map = &final_env,
            .cwd = .{ .path = src_abs },
        });

        if (res.term != .exited or res.term.exited != 0) {


            return error.CommandFailed;
        }
    }

    // 4. Collect outputs
    try collectOutputs(allocator, io, src_abs, out_abs, bdir, config.collect, lua_abi, lua_include, lua_lib, lua_bin_dir);
}

fn expandVariables(
    allocator: std.mem.Allocator,
    input: []const u8,
    out_path: []const u8,
    src_path: []const u8,
    build_path: []const u8,
    lua_include: []const u8,
    lua_lib: []const u8,
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
    lua_bin_dir: []const u8,
    lua_abi: []const u8,
) ![]const []const u8 {
    var results = std.ArrayList([]const u8).empty;
    for (inputs) |in| {
        try results.append(allocator, try expandVariables(allocator, in, out_path, src_path, build_path, lua_include, lua_lib, lua_bin_dir, lua_abi));
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
            const expanded_src = try expandVariables(allocator, item.path, out_path, src_path, build_path, lua_include, lua_lib, lua_bin_dir, lua_abi);
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
            if (cp_res.term != .exited or cp_res.term.exited != 0) {

                return error.CopyFailed;
            }
        }
    }
}
