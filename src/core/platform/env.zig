const std = @import("std");

pub fn get_config_dir(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("MOONSTONE_CONFIG")) |dir| {
        if (dir.len != 0) return try allocator.dupe(u8, dir);
    }

    if (env.get("MOONSTONE_HOME")) |home| {
        if (home.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ home, "config" });
    }

    if (env.get("XDG_CONFIG_HOME")) |dir| {
        if (dir.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ dir, "moonstone" });
    }

    const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "moonstone" });
}

pub fn get_data_dir(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("MOONSTONE_DATA")) |dir| {
        if (dir.len != 0) return try allocator.dupe(u8, dir);
    }

    if (env.get("MOONSTONE_HOME")) |home| {
        if (home.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ home, "data" });
    }

    if (env.get("XDG_DATA_HOME")) |dir| {
        if (dir.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ dir, "moonstone" });
    }

    const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share", "moonstone" });
}

pub fn get_cache_dir(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("MOONSTONE_CACHE")) |dir| {
        if (dir.len != 0) return try allocator.dupe(u8, dir);
    }

    if (env.get("MOONSTONE_HOME")) |home| {
        if (home.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ home, "cache" });
    }

    if (env.get("XDG_CACHE_HOME")) |dir| {
        if (dir.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ dir, "moonstone" });
    }

    const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".cache", "moonstone" });
}

test "MOONSTONE_CONFIG wins over everything" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("MOONSTONE_CONFIG", "/tmp/custom/config");
    try env_map.put("MOONSTONE_HOME", "/tmp/home");
    try env_map.put("XDG_CONFIG_HOME", "/tmp/xdg");
    try env_map.put("HOME", "/tmp/fallback");

    const result = try get_config_dir(allocator, &env_map);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/custom/config", result);
}

test "MOONSTONE_HOME derives config/data/cache when specific vars are unset" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("MOONSTONE_HOME", "/tmp/moonstone-synthetic");
    try env_map.put("HOME", "/tmp/fallback");

    const config = try get_config_dir(allocator, &env_map);
    defer allocator.free(config);
    try std.testing.expectEqualStrings("/tmp/moonstone-synthetic/config", config);

    const data = try get_data_dir(allocator, &env_map);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("/tmp/moonstone-synthetic/data", data);

    const cache = try get_cache_dir(allocator, &env_map);
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("/tmp/moonstone-synthetic/cache", cache);
}

test "XDG fallback appends /moonstone" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("XDG_CONFIG_HOME", "/tmp/xdg-config");
    try env_map.put("HOME", "/tmp/fallback");

    const result = try get_config_dir(allocator, &env_map);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/xdg-config/moonstone", result);
}

test "HOME fallback works" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("HOME", "/tmp/home");

    const config = try get_config_dir(allocator, &env_map);
    defer allocator.free(config);
    try std.testing.expectEqualStrings("/tmp/home/.config/moonstone", config);

    const data = try get_data_dir(allocator, &env_map);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("/tmp/home/.local/share/moonstone", data);

    const cache = try get_cache_dir(allocator, &env_map);
    defer allocator.free(cache);
    try std.testing.expectEqualStrings("/tmp/home/.cache/moonstone", cache);
}
