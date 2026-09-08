const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("../domain/manifest.zig");
const environment = @import("environment.zig");
const package_root_mod = @import("package_root.zig");

pub const PackageRoot = package_root_mod.PackageRoot;

pub const RunEnv = struct {
    env_map: std.process.Environ.Map,
    allocator: std.mem.Allocator,

    // Explicitly stored pieces for 'moon env' formatting
    bin_path: []const u8,
    lua_path: []const u8,
    lua_cpath: []const u8,
    native_lib_path: ?[]const u8,
    lua_ver_suffix: []const u8, // e.g. "5_4"
    lua_ver_dot: []const u8, // e.g. "5.4"
    package_roots: []const PackageRoot,

    pub fn deinit(self: *RunEnv) void {
        self.env_map.deinit();
        self.allocator.free(self.bin_path);
        self.allocator.free(self.lua_path);
        self.allocator.free(self.lua_cpath);
        if (self.native_lib_path) |native_lib_path| self.allocator.free(native_lib_path);
        self.allocator.free(self.lua_ver_suffix);
        self.allocator.free(self.lua_ver_dot);
        for (self.package_roots) |entry| entry.deinit(self.allocator);
        self.allocator.free(self.package_roots);
    }
};

fn deinitPackageRoots(allocator: std.mem.Allocator, roots: []const PackageRoot) void {
    for (roots) |entry| entry.deinit(allocator);
    allocator.free(roots);
}

/// Read the `[[package]]` roots the linker recorded in `env.toml`.
///
/// The table is advisory metadata about a derived environment, not a trust
/// boundary: a malformed or truncated entry is skipped rather than blocking
/// `moon exec`.
fn parsePackageRoots(allocator: std.mem.Allocator, env_toml: @import("toml").Table) ![]const PackageRoot {
    const packages_value = env_toml.get("package") orelse return &.{};
    if (packages_value != .array) return &.{};

    var roots = std.ArrayList(PackageRoot).empty;
    errdefer {
        for (roots.items) |entry| entry.deinit(allocator);
        roots.deinit(allocator);
    }

    for (packages_value.array.items) |package_value| {
        if (package_value != .table) continue;
        const entry = package_value.table;
        const name_value = entry.get("name") orelse continue;
        const root_value = entry.get("root") orelse continue;
        if (name_value != .string or root_value != .string) continue;

        const projection = if (entry.get("projection")) |projection_value| blk: {
            if (projection_value != .string) break :blk package_root_mod.Projection.store;
            break :blk package_root_mod.Projection.fromString(projection_value.string) orelse .store;
        } else .store;

        const key = if (entry.get("env")) |key_value| blk: {
            if (key_value != .string) break :blk try package_root_mod.environmentKey(allocator, name_value.string);
            break :blk try allocator.dupe(u8, key_value.string);
        } else try package_root_mod.environmentKey(allocator, name_value.string);
        errdefer allocator.free(key);

        const name = try allocator.dupe(u8, name_value.string);
        errdefer allocator.free(name);
        try roots.append(allocator, .{
            .name = name,
            .root = try allocator.dupe(u8, root_value.string),
            .key = key,
            .projection = projection,
        });
    }

    return try roots.toOwnedSlice(allocator);
}

pub fn get_run_env(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: []const u8,
    base_env: *std.process.Environ.Map,
) !RunEnv {
    return getRunEnv(allocator, io, start_path, base_env, false);
}

/// Like `get_run_env`, but `start_path` has already been resolved by the
/// caller and must not be reinterpreted relative to the process cwd. Project
/// root discovery still walks upward, so `-C` may name a nested directory.
pub fn get_run_env_at_root(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: []const u8,
    base_env: *std.process.Environ.Map,
) !RunEnv {
    return getRunEnv(allocator, io, start_path, base_env, true);
}

fn getRunEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_path: []const u8,
    base_env: *std.process.Environ.Map,
    start_path_is_resolved: bool,
) !RunEnv {
    const platform_fs = @import("../platform/fs.zig");
    const paths = try platform_fs.resolve_moonstone(allocator, base_env, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    // 1. Search for project root (upwards)
    const search_path = if (start_path_is_resolved or std.fs.path.isAbsolute(start_path))
        try allocator.dupe(u8, start_path)
    else
        try std.Io.Dir.cwd().realPathFileAlloc(io, start_path, allocator);
    defer allocator.free(search_path);

    var project_root: ?[]const u8 = null;
    var current_path = try allocator.dupe(u8, search_path);
    defer allocator.free(current_path);

    while (project_root == null) {
        const candidate = try std.fs.path.join(allocator, &.{ current_path, ".moonstone", "env", "env.toml" });
        defer allocator.free(candidate);
        if (try platform_fs.fileExistsAbsolute(io, candidate)) {
            project_root = try allocator.dupe(u8, current_path);
            break;
        }

        const parent = std.fs.path.dirname(current_path) orelse {
            break;
        };
        if (std.mem.eql(u8, parent, current_path)) {
            break;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current_path);
        current_path = next;
    }
    defer if (project_root) |pr| allocator.free(pr);

    if (project_root) |pr| {
        // Project environment
        const env_toml_path = try std.fs.path.join(allocator, &.{ pr, ".moonstone", "env", "env.toml" });
        defer allocator.free(env_toml_path);

        const content = platform_fs.readFileAbsolute(allocator, io, env_toml_path, 1024 * 1024) catch |err| blk: {
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
            const native_lib_path = try std.fs.path.join(allocator, &.{ pr, ".moonstone", "env", "lib", "native" });
            defer allocator.free(native_lib_path);

            const package_roots = try parsePackageRoots(allocator, res.value);
            defer deinitPackageRoots(allocator, package_roots);

            return try build_run_env(allocator, io, base_env, env_bin_path, env_share_path, env_lib_path, native_lib_path, lua_ver_dot, package_roots);
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

        // The global fallback is a runtime, not a project: it projects no
        // package trees and therefore records no package roots.
        return try build_run_env(allocator, io, base_env, env_bin_path, env_share_path, env_lib_path, null, lua_ver_dot, &.{});
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
    native_lib_path: ?[]const u8,
    lua_ver_dot: []const u8,
    package_roots: []const PackageRoot,
) !RunEnv {
    const ver_suffix = try allocator.dupe(u8, lua_ver_dot);
    errdefer allocator.free(ver_suffix);
    for (ver_suffix) |*char| if (char.* == '.') {
        char.* = '_';
    };

    var final_env = try base_env.clone(allocator);
    errdefer final_env.deinit();

    const lua_path_val = try std.fmt.allocPrint(allocator, "{s}/?.lua;{s}/?/init.lua;;", .{ share_path, share_path });
    errdefer allocator.free(lua_path_val);

    var lua_cpath = std.ArrayList(u8).empty;
    errdefer lua_cpath.deinit(allocator);
    for (environment.luaCmoduleExtensions()) |extension| {
        if (lua_cpath.items.len > 0) try lua_cpath.append(allocator, ';');
        const patterns = try std.fmt.allocPrint(allocator, "{s}/?{s};{s}/?/init{s}", .{ lib_path, extension, lib_path, extension });
        defer allocator.free(patterns);
        try lua_cpath.appendSlice(allocator, patterns);
    }
    try lua_cpath.appendSlice(allocator, ";;");
    const lua_cpath_val = try lua_cpath.toOwnedSlice(allocator);
    errdefer allocator.free(lua_cpath_val);

    const active_native_lib_path = if (native_lib_path) |path| blk: {
        var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => break :blk null,
            else => return err,
        };
        directory.close(io);
        break :blk path;
    } else null;
    const old_path = base_env.get("PATH") orelse "";
    const new_path = if (comptime builtin.os.tag == .windows) blk: {
        if (active_native_lib_path) |path| {
            break :blk if (old_path.len > 0)
                try std.fmt.allocPrint(allocator, "{s}{c}{s}{c}{s}", .{ path, environment.pathSeparator(), bin_path, environment.pathSeparator(), old_path })
            else
                try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ path, environment.pathSeparator(), bin_path });
        }
        break :blk if (old_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ bin_path, environment.pathSeparator(), old_path })
        else
            try allocator.dupe(u8, bin_path);
    } else if (old_path.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ bin_path, environment.pathSeparator(), old_path })
    else
        try allocator.dupe(u8, bin_path);
    defer allocator.free(new_path);
    try final_env.put("PATH", new_path);
    if (active_native_lib_path) |path| if (environment.nativeLibraryEnvironmentVariable()) |key| {
        const old_loader_path = base_env.get(key) orelse "";
        const projected_loader_path = if (old_loader_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ path, environment.pathSeparator(), old_loader_path })
        else
            try allocator.dupe(u8, path);
        defer allocator.free(projected_loader_path);
        try final_env.put(key, projected_loader_path);
    };

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

    // Real package roots. A projected module is a symlink, so a package that
    // asks `debug.getinfo` where it lives is told about the consumer's
    // environment; this answers the question it actually meant.
    var owned_roots = std.ArrayList(PackageRoot).empty;
    errdefer {
        for (owned_roots.items) |entry| entry.deinit(allocator);
        owned_roots.deinit(allocator);
    }
    for (package_roots) |entry| {
        try final_env.put(entry.key, entry.root);
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const root = try allocator.dupe(u8, entry.root);
        errdefer allocator.free(root);
        try owned_roots.append(allocator, .{
            .name = name,
            .root = root,
            .key = try allocator.dupe(u8, entry.key),
            .projection = entry.projection,
        });
    }

    return RunEnv{
        .env_map = final_env,
        .allocator = allocator,
        .bin_path = try allocator.dupe(u8, bin_path),
        .lua_path = lua_path_val,
        .lua_cpath = lua_cpath_val,
        .native_lib_path = if (active_native_lib_path) |path| try allocator.dupe(u8, path) else null,
        .lua_ver_suffix = ver_suffix,
        .lua_ver_dot = lua_ver_dot,
        .package_roots = try owned_roots.toOwnedSlice(allocator),
    };
}

pub const EnvMode = enum {
    runtime,
    dev,
};

/// Check if a binary in .moonstone/env/bin should be visible for the given mode.
/// Returns true if allowed (or no lockfile), false if dev-only and mode is runtime.
pub fn isEnvEntryAllowed(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    entry_name: []const u8,
    mode: EnvMode,
) !bool {
    if (mode == .dev) return true;

    // Runtime mode: check lockfile groups
    const lock_path = try std.fs.path.join(allocator, &.{ project_root, "moonstone.lock" });
    defer allocator.free(lock_path);

    var content: ?[]const u8 = null;
    if (std.Io.Dir.cwd().access(io, lock_path, .{})) |_| {
        content = try std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    defer if (content) |c| allocator.free(c);
    if (content == null) return true;

    var lf = try @import("../domain/lockfile.zig").LockFile.parse(allocator, content.?);
    defer lf.deinit();

    // Read symlink target
    const bin_path = try std.fs.path.join(allocator, &.{ project_root, ".moonstone", "env", "bin", entry_name });
    defer allocator.free(bin_path);

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const abs_bin_path = try std.fs.path.resolve(allocator, &.{ cwd, bin_path });
    defer allocator.free(abs_bin_path);

    var link_buf: [std.posix.PATH_MAX]u8 = undefined;
    const link_len = std.Io.Dir.readLinkAbsolute(io, abs_bin_path, &link_buf) catch |err| {
        if (err == error.NotLink) return true;
        return err;
    };
    const target = link_buf[0..link_len];

    // Match lockfile entry by searching for artifact hash in the symlink target path
    for (lf.packages.items) |pkg| {
        if (pkg.artifact_hash.len <= 3) continue;
        const hash_suffix = pkg.artifact_hash[3..]; // strip "b3:" prefix
        if (std.mem.indexOf(u8, target, hash_suffix) != null) {
            if (pkg.roles.len == 0) return true; // backward compat
            for (pkg.roles) |g| {
                if (std.mem.eql(u8, g, "runtime") or std.mem.eql(u8, g, "dev") or std.mem.eql(u8, g, "libs") or std.mem.eql(u8, g, "bins")) return true;
            }
            return false;
        }
    }

    // Not in lockfile (e.g. runtime), allow
    return true;
}

test "build_run_env projects an existing native library directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "share/lua/5.4");
    try tmp.dir.createDirPath(io, "lib/lua/5.4");
    try tmp.dir.createDirPath(io, "lib/native");

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const bin_path = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin_path);
    const share_path = try std.fs.path.join(allocator, &.{ root, "share/lua/5.4" });
    defer allocator.free(share_path);
    const lib_path = try std.fs.path.join(allocator, &.{ root, "lib/lua/5.4" });
    defer allocator.free(lib_path);
    const native_lib_path = try std.fs.path.join(allocator, &.{ root, "lib/native" });
    defer allocator.free(native_lib_path);

    var base_env = std.process.Environ.Map.init(allocator);
    defer base_env.deinit();
    try base_env.put("PATH", "/host/bin");

    var run_env = try build_run_env(allocator, io, &base_env, bin_path, share_path, lib_path, native_lib_path, "5.4", &.{});
    defer run_env.deinit();

    try std.testing.expectEqualStrings(native_lib_path, run_env.native_lib_path.?);
    if (comptime builtin.os.tag == .windows) {
        const expected_prefix = try std.fmt.allocPrint(allocator, "{s};{s}", .{ native_lib_path, bin_path });
        defer allocator.free(expected_prefix);
        try std.testing.expect(std.mem.startsWith(u8, run_env.env_map.get("PATH").?, expected_prefix));
    } else {
        const key = environment.nativeLibraryEnvironmentVariable().?;
        try std.testing.expectEqualStrings(native_lib_path, run_env.env_map.get(key).?);
        try std.testing.expect(std.mem.startsWith(u8, run_env.env_map.get("PATH").?, bin_path));
    }
}

test "build_run_env omits absent native library directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "share/lua/5.4");
    try tmp.dir.createDirPath(io, "lib/lua/5.4");

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const bin_path = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin_path);
    const share_path = try std.fs.path.join(allocator, &.{ root, "share/lua/5.4" });
    defer allocator.free(share_path);
    const lib_path = try std.fs.path.join(allocator, &.{ root, "lib/lua/5.4" });
    defer allocator.free(lib_path);
    const native_lib_path = try std.fs.path.join(allocator, &.{ root, "lib/native" });
    defer allocator.free(native_lib_path);

    var base_env = std.process.Environ.Map.init(allocator);
    defer base_env.deinit();
    try base_env.put("PATH", "/host/bin");

    var run_env = try build_run_env(allocator, io, &base_env, bin_path, share_path, lib_path, native_lib_path, "5.4", &.{});
    defer run_env.deinit();

    try std.testing.expect(run_env.native_lib_path == null);
    if (comptime builtin.os.tag != .windows) {
        try std.testing.expect(run_env.env_map.get(environment.nativeLibraryEnvironmentVariable().?) == null);
    }
}

test "recorded package roots become exported environment variables" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "share/lua/5.1");
    try tmp.dir.createDirPath(io, "lib/lua/5.1");

    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const bin_path = try std.fs.path.join(allocator, &.{ root, "bin" });
    defer allocator.free(bin_path);
    const share_path = try std.fs.path.join(allocator, &.{ root, "share/lua/5.1" });
    defer allocator.free(share_path);
    const lib_path = try std.fs.path.join(allocator, &.{ root, "lib/lua/5.1" });
    defer allocator.free(lib_path);

    var base_env = std.process.Environ.Map.init(allocator);
    defer base_env.deinit();
    try base_env.put("PATH", "/host/bin");

    const declared = [_]PackageRoot{.{
        .name = "hydronium-ink",
        .root = "/workspace/hydronium/ink",
        .key = "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK",
        .projection = .live,
    }};

    var run_env = try build_run_env(allocator, io, &base_env, bin_path, share_path, lib_path, null, "5.1", &declared);
    defer run_env.deinit();

    try std.testing.expectEqualStrings(
        "/workspace/hydronium/ink",
        run_env.env_map.get("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK").?,
    );
    try std.testing.expectEqual(@as(usize, 1), run_env.package_roots.len);
    try std.testing.expectEqual(package_root_mod.Projection.live, run_env.package_roots[0].projection);
}

test "package roots are read back from a linker-written env.toml" {
    const allocator = std.testing.allocator;
    const env_toml =
        \\[runtime]
        \\name = "luajit"
        \\version = "2.1.0"
        \\abi = "lua51"
        \\
        \\[[package]]
        \\name = "hydronium-ink"
        \\root = "/workspace/hydronium/ink"
        \\projection = "live"
        \\env = "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK"
        \\
        \\[[package]]
        \\name = "moonstone/ballad"
        \\root = "/store/b3/aa/files"
        \\projection = "store"
        \\env = "MOONSTONE_PACKAGE_ROOT_MOONSTONE_BALLAD"
        \\
        \\[[package]]
        \\root = "/store/b3/bb/files"
    ;

    var parser = @import("toml").Parser(@import("toml").Table).init(allocator);
    defer parser.deinit();
    var res = try parser.parseString(env_toml);
    defer res.deinit();

    const roots = try parsePackageRoots(allocator, res.value);
    defer deinitPackageRoots(allocator, roots);

    // The nameless third entry is skipped rather than treated as fatal.
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("hydronium-ink", roots[0].name);
    try std.testing.expectEqualStrings("/workspace/hydronium/ink", roots[0].root);
    try std.testing.expectEqualStrings("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK", roots[0].key);
    try std.testing.expectEqual(package_root_mod.Projection.live, roots[0].projection);
    try std.testing.expectEqual(package_root_mod.Projection.store, roots[1].projection);
}
