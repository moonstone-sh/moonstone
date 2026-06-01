const std = @import("std");
const manifest = @import("../domain/manifest.zig");

pub const RunEnv = struct {
    env_map: std.process.Environ.Map,
    allocator: std.mem.Allocator,
    
    // Explicitly stored pieces for 'moon env' formatting
    bin_path: []const u8,
    lua_path: []const u8,
    lua_cpath: []const u8,
    lua_ver_suffix: []const u8, // e.g. "5_4"
    lua_ver_dot: []const u8,    // e.g. "5.4"

    pub fn deinit(self: *RunEnv) void {
        self.env_map.deinit();
        self.allocator.free(self.bin_path);
        self.allocator.free(self.lua_path);
        self.allocator.free(self.lua_cpath);
        self.allocator.free(self.lua_ver_suffix);
        self.allocator.free(self.lua_ver_dot);
    }
};

pub fn get_run_env(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: []const u8,
    base_env: *std.process.Environ.Map,
) !RunEnv {
    const platform_fs = @import("../platform/fs.zig");
    const paths = try platform_fs.resolve_moonstone(allocator, base_env, io);
    defer { var p = paths; p.deinit(allocator); }

    // 1. Search for project root (upwards)
    const search_path = try std.Io.Dir.cwd().realPathFileAlloc(io, start_path, allocator);
    defer allocator.free(search_path);

    var project_root: ?[]const u8 = null;
    var current_path = try allocator.dupe(u8, search_path);
    defer allocator.free(current_path);

    while (true) {
        var dir = std.Io.Dir.openDirAbsolute(io, current_path, .{ .iterate = true }) catch break;

        var is_project = false;
        if (dir.access(io, ".moonstone", .{})) |_| {
            // Further verify it's a valid project environment
            const env_toml_path = try std.fs.path.join(allocator, &.{ current_path, ".moonstone", "env", "env.toml" });
            defer allocator.free(env_toml_path);
            if (std.Io.Dir.cwd().access(io, env_toml_path, .{})) |_| {
                is_project = true;
            } else |_| {}
        } else |_| {}

        if (is_project) {
            dir.close(io);
            project_root = try allocator.dupe(u8, current_path);
            break;
        }

        const parent = std.fs.path.dirname(current_path) orelse {
            dir.close(io);
            break;
        };
        if (std.mem.eql(u8, parent, current_path)) {
            dir.close(io);
            break;
        }
        
        const next = try allocator.dupe(u8, parent);
        allocator.free(current_path);
        current_path = next;
        dir.close(io);
    }
    defer if (project_root) |pr| allocator.free(pr);

    if (project_root) |pr| {
        // Project environment
        const env_toml_path = try std.fs.path.join(allocator, &.{ pr, ".moonstone", "env", "env.toml" });
        defer allocator.free(env_toml_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, env_toml_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            return err;
        };
        
        if (content) |c| {
            defer allocator.free(c);
            var parser = @import("toml").Parser(@import("toml").Table).init(allocator);
            defer parser.deinit();
            var res = try parser.parseString(c);
            defer res.deinit();

            const runtime_table = res.value.get("runtime").?.table;
            const abi = runtime_table.get("abi").?.string;

            var lua_ver_dot: []const u8 = undefined;
            if (std.mem.startsWith(u8, abi, "lua") and abi.len >= 5) {
                if (abi.len == 5) {
                    lua_ver_dot = try std.fmt.allocPrint(allocator, "{c}.{c}", .{ abi[3], abi[4] });
                } else if (std.mem.indexOfScalar(u8, abi, '-')) |pos| {
                    lua_ver_dot = try allocator.dupe(u8, abi[pos + 1 ..]);
                } else {
                    lua_ver_dot = try allocator.dupe(u8, abi[3..]);
                }
            } else {
                lua_ver_dot = try allocator.dupe(u8, abi);
            }
            errdefer allocator.free(lua_ver_dot);

            const env_bin_path = try std.fs.path.join(allocator, &.{ pr, ".moonstone", "env", "bin" });
            const env_share_path = try std.fs.path.join(allocator, &.{ pr, ".moonstone", "env", "share", "lua", lua_ver_dot });
            const env_lib_path = try std.fs.path.join(allocator, &.{ pr, ".moonstone", "env", "lib", "lua", lua_ver_dot });

            return try build_run_env(allocator, io, base_env, env_bin_path, env_share_path, env_lib_path, lua_ver_dot);
        }
    }

    // 2. Global fallback
    const config_toml_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
    defer allocator.free(config_toml_path);

    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_toml_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.NoActiveEnvironment;
        return err;
    };
    defer allocator.free(config_content);

    var parser = @import("toml").Parser(@import("toml").Table).init(allocator);
    defer parser.deinit();
    var config_res = try parser.parseString(config_content);
    defer config_res.deinit();

    const moonstone_table = config_res.value.get("moonstone") orelse return error.NoActiveEnvironment;
    const default_rt = moonstone_table.table.get("default_runtime") orelse return error.NoActiveEnvironment;
    const rt_spec = default_rt.string;

    // Resolve default runtime path in store
    const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
    defer allocator.free(index_db_path);
    const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
    defer allocator.free(index_db_path_z);

    const driver_mod = @import("../store/driver.zig");
    var idx = try driver_mod.StoreDriver.init(allocator, index_db_path_z);
    defer idx.deinit();

    const sql = "SELECT path, version, lua_abi FROM artifacts WHERE kind = 'runtime' AND (name || '-' || version = ? OR version = ?) LIMIT 1;";
    var stmt: ?*driver_mod.c.sqlite3_stmt = null;
    if (driver_mod.c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != driver_mod.c.SQLITE_OK) return error.SQLitePrepareError;
    defer _ = driver_mod.c.sqlite3_finalize(stmt);

    const transient = driver_mod.moonstone_sqlite_transient_ptr;
    _ = driver_mod.c.sqlite3_bind_text(stmt, 1, rt_spec.ptr, @intCast(rt_spec.len), transient);
    _ = driver_mod.c.sqlite3_bind_text(stmt, 2, rt_spec.ptr, @intCast(rt_spec.len), transient);

    if (driver_mod.c.sqlite3_step(stmt) == driver_mod.c.SQLITE_ROW) {
        const rt_path = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 0));
        const rt_ver = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 1));
        const rt_abi = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 2));

        const lua_ver_dot = if (std.mem.startsWith(u8, rt_abi, "lua") and rt_abi.len >= 5) blk: {
            if (rt_abi.len == 5) {
                break :blk try std.fmt.allocPrint(allocator, "{c}.{c}", .{ rt_abi[3], rt_abi[4] });
            } else if (std.mem.indexOfScalar(u8, rt_abi, '-')) |pos| {
                break :blk try allocator.dupe(u8, rt_abi[pos + 1 ..]);
            } else {
                break :blk try allocator.dupe(u8, rt_abi[3..]);
            }
        } else try allocator.dupe(u8, rt_ver);

        const env_bin_path = try std.fs.path.join(allocator, &.{ rt_path, "files", "bin" });
        const env_share_path = try std.fs.path.join(allocator, &.{ rt_path, "files", "share", "lua", lua_ver_dot });
        const env_lib_path = try std.fs.path.join(allocator, &.{ rt_path, "files", "lib", "lua", lua_ver_dot });

        return try build_run_env(allocator, io, base_env, env_bin_path, env_share_path, env_lib_path, lua_ver_dot);
    }

    return error.NoActiveEnvironment;
}

fn build_run_env(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_env: *std.process.Environ.Map,
    bin_path: []const u8,
    share_path: []const u8,
    lib_path: []const u8,
    lua_ver_dot: []const u8,
) !RunEnv {
    _ = io;
    const ver_suffix = try allocator.dupe(u8, lua_ver_dot);
    errdefer allocator.free(ver_suffix);
    for (ver_suffix) |*char| if (char.* == '.') {
        char.* = '_';
    };

    var final_env = try base_env.clone(allocator);
    errdefer final_env.deinit();

    const lua_path_val = try std.fmt.allocPrint(allocator, "{s}/?.lua;{s}/?/init.lua;;", .{ share_path, share_path });
    errdefer allocator.free(lua_path_val);

    const lua_cpath_val = try std.fmt.allocPrint(allocator, "{s}/?.so;{s}/?/init.so;;", .{ lib_path, lib_path });
    errdefer allocator.free(lua_cpath_val);

    const old_path = base_env.get("PATH") orelse "";
    const new_path = if (old_path.len > 0)
        try std.fmt.allocPrint(allocator, "{s}:{s}", .{ bin_path, old_path })
    else
        try allocator.dupe(u8, bin_path);
    defer allocator.free(new_path);
    try final_env.put("PATH", new_path);

    // Version-specific vars
    const lua_path_ver_key = try std.fmt.allocPrint(allocator, "LUA_PATH_{s}", .{ver_suffix});
    defer allocator.free(lua_path_ver_key);
    try final_env.put(lua_path_ver_key, lua_path_val);

    const lua_cpath_ver_key = try std.fmt.allocPrint(allocator, "LUA_CPATH_{s}", .{ver_suffix});
    defer allocator.free(lua_cpath_ver_key);
    try final_env.put(lua_cpath_ver_key, lua_cpath_val);

    // Standard vars
    try final_env.put("LUA_PATH", lua_path_val);
    try final_env.put("LUA_CPATH", lua_cpath_val);

    return RunEnv{
        .env_map = final_env,
        .allocator = allocator,
        .bin_path = try allocator.dupe(u8, bin_path),
        .lua_path = lua_path_val,
        .lua_cpath = lua_cpath_val,
        .lua_ver_suffix = ver_suffix,
        .lua_ver_dot = lua_ver_dot,
    };
}
