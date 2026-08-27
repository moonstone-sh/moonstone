const std = @import("std");
const builtin = @import("builtin");

/// Returns the user's home directory using the host platform's conventional
/// environment variable. Windows shells normally define USERPROFILE rather
/// than HOME.
pub fn get_home_dir(env: *std.process.Environ.Map) ![]const u8 {
    if (env.get("HOME")) |home| {
        if (home.len != 0) return home;
    }

    if (comptime builtin.os.tag == .windows) {
        if (env.get("USERPROFILE")) |home| {
            if (home.len != 0) return home;
        }
    }

    return error.EnvironmentVariableNotFound;
}

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

    if (comptime builtin.os.tag == .windows) {
        if (env.get("APPDATA")) |dir| {
            if (dir.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ dir, "moonstone" });
        }
    }

    const home = try get_home_dir(env);
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

    if (comptime builtin.os.tag == .windows) {
        if (env.get("LOCALAPPDATA")) |dir| {
            if (dir.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ dir, "moonstone", "data" });
        }
    }

    const home = try get_home_dir(env);
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

    if (comptime builtin.os.tag == .windows) {
        if (env.get("LOCALAPPDATA")) |dir| {
            if (dir.len != 0) return try std.fs.path.join(allocator, &[_][]const u8{ dir, "moonstone", "cache" });
        }
    }

    const home = try get_home_dir(env);
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

test "Windows profile variables provide defaults when HOME is absent" {
    const allocator = std.testing.allocator;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    try env_map.put("USERPROFILE", "C:\\Users\\moon");
    try env_map.put("APPDATA", "C:\\Users\\moon\\AppData\\Roaming");
    try env_map.put("LOCALAPPDATA", "C:\\Users\\moon\\AppData\\Local");

    const home = try get_home_dir(&env_map);
    try std.testing.expectEqualStrings("C:\\Users\\moon", home);

    const config = try get_config_dir(allocator, &env_map);
    defer allocator.free(config);
    const data = try get_data_dir(allocator, &env_map);
    defer allocator.free(data);
    const cache = try get_cache_dir(allocator, &env_map);
    defer allocator.free(cache);

    if (comptime builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\Users\\moon\\AppData\\Roaming\\moonstone", config);
        try std.testing.expectEqualStrings("C:\\Users\\moon\\AppData\\Local\\moonstone\\data", data);
        try std.testing.expectEqualStrings("C:\\Users\\moon\\AppData\\Local\\moonstone\\cache", cache);
    } else {
        try std.testing.expectEqualStrings("C:\\Users\\moon/.config/moonstone", config);
        try std.testing.expectEqualStrings("C:\\Users\\moon/.local/share/moonstone", data);
        try std.testing.expectEqualStrings("C:\\Users\\moon/.cache/moonstone", cache);
    }
}
