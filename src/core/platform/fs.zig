const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");
const env_utils = @import("env.zig");
const build_options = @import("build_options");

extern "kernel32" fn SetCurrentDirectoryW(path: [*:0]const u16) callconv(.winapi) std.os.windows.BOOL;
extern fn moonstone_file_exists_w(path: [*:0]const u16, out_error: *u32) c_int;
extern fn moonstone_read_file_w(path: [*:0]const u16, out_bytes: *?[*]u8, out_len: *usize, limit: usize, out_error: *u32) c_int;
extern fn moonstone_free_file_w(bytes: [*]u8) void;

/// Changes the process directory using Kernel32 on Windows. Zig 0.16's
/// RtlSetCurrentDirectory path is rejected by Wine, while this public Win32
/// API has the same native Windows semantics.
pub fn setCurrentPath(io: std.Io, path: []const u8) !void {
    if (comptime builtin.os.tag != .windows) return std.process.setCurrentPath(io, path);

    var path_w: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = try std.unicode.wtf8ToWtf16Le(&path_w, path);
    path_w[len] = 0;
    if (!SetCurrentDirectoryW(&path_w).toBool()) return error.FileNotFound;
}

/// Checks an absolute file path through Win32 only in Windows binaries.
pub fn fileExistsAbsolute(io: std.Io, path: []const u8) !bool {
    if (comptime builtin.os.tag != .windows) {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    var path_w: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const path_len = try std.unicode.wtf8ToWtf16Le(&path_w, path);
    path_w[path_len] = 0;
    var win_error: u32 = 0;
    if (moonstone_file_exists_w(&path_w, &win_error) != 0) return true;
    return switch (win_error) {
        2, 3 => false,
        5 => error.AccessDenied,
        else => error.Unexpected,
    };
}

/// Reads an absolute file through Win32 only in Windows binaries. This avoids
/// the Wine-incompatible Io.Dir absolute-path path while other targets retain
/// the normal Zig implementation.
pub fn readFileAbsolute(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    if (comptime builtin.os.tag != .windows)
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(limit));

    var path_w: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const path_len = try std.unicode.wtf8ToWtf16Le(&path_w, path);
    path_w[path_len] = 0;
    var bytes: ?[*]u8 = null;
    var bytes_len: usize = 0;
    var win_error: u32 = 0;
    if (moonstone_read_file_w(&path_w, &bytes, &bytes_len, limit, &win_error) == 0) switch (win_error) {
        2, 3 => return error.FileNotFound,
        5 => return error.AccessDenied,
        223 => return error.FileTooBig,
        else => return error.Unexpected,
    };
    defer moonstone_free_file_w(bytes.?);
    return try allocator.dupe(u8, bytes.?[0..bytes_len]);
}

pub fn copyTreeAbsolute(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination_path);
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);

    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const source_entry = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_entry);
        const destination_entry = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
        defer allocator.free(destination_entry);

        switch (entry.kind) {
            .directory => try copyTreeAbsolute(allocator, io, source_entry, destination_entry),
            .file => try std.Io.Dir.copyFileAbsolute(source_entry, destination_entry, io, .{ .replace = true }),
            .sym_link => {
                var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const target_len = try std.Io.Dir.readLinkAbsolute(io, source_entry, &target_buffer);
                try std.Io.Dir.cwd().symLink(io, target_buffer[0..target_len], destination_entry, .{});
            },
            else => return error.UnsupportedTreeEntry,
        }
    }
}

pub const MOONSTONE_PATHS = struct {
    data: []const u8,
    bin: []const u8,
    downloads: []const u8,
    store: []const u8,
    index: []const u8,
    tmp: []const u8,
    cache: []const u8,
    shims: []const u8,
    config: []const u8,
    projects: []const u8,

    pub fn deinit(self: *MOONSTONE_PATHS, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.bin);
        allocator.free(self.downloads);
        allocator.free(self.store);
        allocator.free(self.index);
        allocator.free(self.tmp);
        allocator.free(self.cache);
        allocator.free(self.shims);
        allocator.free(self.config);
        allocator.free(self.projects);
    }
};

pub fn patch_config_path(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    patch: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(config_path)) {
        return allocator.dupe(u8, config_path);
    }

    if (std.mem.startsWith(u8, config_path, "~/")) {
        const rest = config_path[2..];
        return try std.fs.path.join(allocator, &.{ patch, rest });
    }

    if (std.mem.eql(u8, config_path, "~")) {
        return try allocator.dupe(u8, patch);
    }

    return error.InvalidSetting;
}

pub fn resolve_config_file(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]const u8 {
    if (env.get("MOONSTONE_CONFIG_FILE")) |path| {
        if (path.len != 0) return try allocator.dupe(u8, path);
    }

    const config_dir = try env_utils.get_config_dir(allocator, env);
    defer allocator.free(config_dir);
    return try std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
}

fn configDirectoryForFile(allocator: std.mem.Allocator, config_file: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(config_file) orelse return try allocator.dupe(u8, ".");
    return try allocator.dupe(u8, parent);
}

pub fn resolve_moonstone(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) !MOONSTONE_PATHS {
    const config_file_path = try resolve_config_file(allocator, env);
    defer allocator.free(config_file_path);

    const config_dir = try configDirectoryForFile(allocator, config_file_path);
    defer allocator.free(config_dir);

    const data_dir = env_utils.get_data_dir(allocator, env) catch |err| {
        return err;
    };
    defer allocator.free(data_dir);

    const cache_dir = env_utils.get_cache_dir(allocator, env) catch |err| {
        return err;
    };
    defer allocator.free(cache_dir);

    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_file_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound) {}
        break :blk null;
    };
    defer if (config_content) |c| allocator.free(c);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const res = if (config_content) |c| parser.parseString(c) catch |err| blk: {
        // TODO: properly manage this error
        std.debug.print("config parse error: {s}\n", .{@errorName(err)});
        break :blk null;
    } else null;
    defer if (res) |r| r.deinit();

    const HOME = env.get("HOME") orelse if (comptime builtin.os.tag == .windows)
        (env.get("USERPROFILE") orelse return error.EnvNoHome)
    else
        return error.EnvNoHome;

    const VERSION = build_options.version;
    const MAJOR = VERSION[0];
    const major_v = try std.fmt.allocPrint(allocator, "v{c}", .{MAJOR});
    defer allocator.free(major_v);

    var paths = MOONSTONE_PATHS{
        .data = try allocator.dupe(u8, data_dir),
        .bin = try std.fs.path.join(allocator, &.{ data_dir, "bin" }),
        .store = try std.fs.path.join(allocator, &.{ data_dir, "store", major_v }),
        .index = try std.fs.path.join(allocator, &.{ data_dir, "index", major_v }),
        .tmp = try std.fs.path.join(allocator, &.{ data_dir, "tmp" }),
        .cache = try allocator.dupe(u8, cache_dir),
        .shims = try std.fs.path.join(allocator, &.{ data_dir, major_v, "shims" }),
        .downloads = try std.fs.path.join(allocator, &.{ cache_dir, "downloads" }),
        .config = try allocator.dupe(u8, config_dir),
        .projects = try std.fs.path.join(allocator, &.{ data_dir, "projects" }),
    };

    if (res) |r| {
        const table = r.value;
        const paths_table = if (table.get("paths")) |paths_value| switch (paths_value) {
            .table => |value| value,
            else => null,
        } else null;

        if (paths_table) |configured_paths| {
            if (configured_paths.get("home_directory")) |n| {
                const home_directory = try patch_config_path(allocator, n.string, HOME);
                defer allocator.free(home_directory);

                allocator.free(paths.data);
                allocator.free(paths.bin);
                allocator.free(paths.store);
                allocator.free(paths.index);
                allocator.free(paths.tmp);
                allocator.free(paths.cache);
                allocator.free(paths.shims);
                allocator.free(paths.downloads);
                allocator.free(paths.projects);

                paths.data = try std.fs.path.join(allocator, &.{ home_directory, "data" });
                paths.bin = try std.fs.path.join(allocator, &.{ paths.data, "bin" });
                paths.store = try std.fs.path.join(allocator, &.{ paths.data, "store", major_v });
                paths.index = try std.fs.path.join(allocator, &.{ paths.data, "index", major_v });
                paths.tmp = try std.fs.path.join(allocator, &.{ paths.data, "tmp" });
                paths.cache = try std.fs.path.join(allocator, &.{ home_directory, "cache" });
                paths.shims = try std.fs.path.join(allocator, &.{ paths.data, major_v, "shims" });
                paths.downloads = try std.fs.path.join(allocator, &.{ paths.cache, "downloads" });
                paths.projects = try std.fs.path.join(allocator, &.{ paths.data, "projects" });
            }
        }

        if (paths_table) |configured_paths| {
            if (configured_paths.get("store")) |n| {
                const patched = try patch_config_path(allocator, n.string, HOME);
                allocator.free(paths.store);
                paths.store = patched;
            }
            if (configured_paths.get("cache")) |n| {
                const patched = try patch_config_path(allocator, n.string, HOME);
                allocator.free(paths.cache);
                paths.cache = patched;
            }
            if (configured_paths.get("shims")) |n| {
                const patched = try patch_config_path(allocator, n.string, HOME);
                allocator.free(paths.shims);
                paths.shims = patched;
            }
            if (configured_paths.get("downloads")) |n| {
                const patched = try patch_config_path(allocator, n.string, HOME);
                allocator.free(paths.downloads);
                paths.downloads = patched;
            }
        }
    }

    return paths;
}

pub fn copy_moonstone_config(allocator: std.mem.Allocator, path: []const u8, io: std.Io) !void {
    const config_raw = @embedFile("raw/config.toml");

    const config_file_path = try std.fs.path.join(allocator, &.{ path, "config.toml" });
    defer allocator.free(config_file_path);

    const config_file = try std.Io.Dir.cwd().createFile(io, config_file_path, .{});
    defer config_file.close(io);

    try config_file.writeStreamingAll(io, config_raw);
}

pub fn create_moonstone_dirs(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) !void {
    var moonstone_dirs = try resolve_moonstone(allocator, env, io);
    defer moonstone_dirs.deinit(allocator);

    inline for (std.meta.fields(@TypeOf(moonstone_dirs))) |field| {
        const value = @field(moonstone_dirs, field.name);
        try std.Io.Dir.cwd().createDirPath(io, value);
    }

    try copy_moonstone_config(allocator, moonstone_dirs.config, io);
}

pub const NetworkConfig = struct {
    timeout: u32 = 30,
    retries: u32 = 3,
    retry_delay: u32 = 1,
};

pub fn is_json_mode(allocator: std.mem.Allocator) bool {
    var args = std.process.argsWithAllocator(allocator) catch return false;
    defer args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

pub fn get_network_config(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) NetworkConfig {
    const paths = resolve_moonstone(allocator, env, io) catch return .{};
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    const config_file_path = resolve_config_file(allocator, env) catch return .{};
    defer allocator.free(config_file_path);

    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_file_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch return .{};
    defer allocator.free(config_content);

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const res = parser.parseString(config_content) catch return .{};
    defer res.deinit();

    var cfg = NetworkConfig{};
    const table = res.value;
    if (table.get("network")) |net_val| {
        switch (net_val) {
            .table => |net_table| {
                if (net_table.get("timeout")) |t_val| {
                    switch (t_val) {
                        .integer => |i| cfg.timeout = @intCast(i),
                        else => {},
                    }
                }
                if (net_table.get("retries")) |r_val| {
                    switch (r_val) {
                        .integer => |i| cfg.retries = @intCast(i),
                        else => {},
                    }
                }
                if (net_table.get("retry_delay")) |rd_val| {
                    switch (rd_val) {
                        .integer => |i| cfg.retry_delay = @intCast(i),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return cfg;
}

test "patch_config_path absolute returns as-is" {
    const allocator = std.testing.allocator;
    const result = try patch_config_path(allocator, "/tmp/store", "/tmp/home");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/store", result);
}

test "patch_config_path tilde expands to home" {
    const allocator = std.testing.allocator;
    const result = try patch_config_path(allocator, "~/store", "/tmp/home");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/home/store", result);
}

test "patch_config_path lone tilde expands to home" {
    const allocator = std.testing.allocator;
    const result = try patch_config_path(allocator, "~", "/tmp/home");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/home", result);
}

test "patch_config_path relative errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidSetting, patch_config_path(allocator, "relative/path", "/tmp/home"));
}

test "get_network_config parses custom config correctly" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    // Setup custom config environment
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("HOME", "/tmp");
    const tmp_home = "/tmp/moonstone-test-network-config";
    try env_map.put("MOONSTONE_CONFIG", tmp_home);

    try std.Io.Dir.cwd().createDirPath(io, tmp_home);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    const toml_path = try std.fs.path.join(allocator, &.{ tmp_home, "config.toml" });
    defer allocator.free(toml_path);

    const custom_toml =
        \\[network]
        \\timeout = 42
        \\retries = 5
        \\retry_delay = 2
        \\
    ;

    const file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
    try file.writeStreamingAll(io, custom_toml);
    file.close(io);

    const cfg = get_network_config(allocator, &env_map, io);
    try std.testing.expectEqual(@as(u32, 42), cfg.timeout);
    try std.testing.expectEqual(@as(u32, 5), cfg.retries);
    try std.testing.expectEqual(@as(u32, 2), cfg.retry_delay);
}
