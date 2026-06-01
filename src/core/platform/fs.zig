const std = @import("std");
const toml = @import("toml");
const env_utils = @import("env.zig");
const build_options = @import("build_options");

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

pub fn resolve_moonstone(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) !MOONSTONE_PATHS {
    const config_dir = env_utils.get_config_dir(allocator, env) catch |err| {
        return err;
    };
    defer allocator.free(config_dir);

    const data_dir = env_utils.get_data_dir(allocator, env) catch |err| {
        return err;
    };
    defer allocator.free(data_dir);

    const cache_dir = env_utils.get_cache_dir(allocator, env) catch |err| {
        return err;
    };
    defer allocator.free(cache_dir);

    const config_file_path = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
    defer allocator.free(config_file_path);

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

    const HOME = env.get("HOME") orelse return error.EnvNoHome;

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
        if (table.get("store")) |n| {
            const patched = try patch_config_path(allocator, n.string, HOME);
            allocator.free(paths.store);
            paths.store = patched;
        }
        if (table.get("cache")) |n| {
            const patched = try patch_config_path(allocator, n.string, HOME);
            allocator.free(paths.cache);
            paths.cache = patched;
        }
        if (table.get("shims")) |n| {
            const patched = try patch_config_path(allocator, n.string, HOME);
            allocator.free(paths.shims);
            paths.shims = patched;
        }
        if (table.get("downloads")) |n| {
            const patched = try patch_config_path(allocator, n.string, HOME);
            allocator.free(paths.downloads);
            paths.downloads = patched;
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

    const config_file_path = std.fs.path.join(allocator, &.{ paths.config, "config.toml" }) catch return .{};
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
