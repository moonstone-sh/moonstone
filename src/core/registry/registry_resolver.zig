const std = @import("std");
const toml = @import("toml");
const manifest = @import("../domain/manifest.zig");
const fs = @import("../platform/fs.zig");
const registry = @import("registry.zig");

fn expandEnv(allocator: std.mem.Allocator, text: []const u8, environ_map: *std.process.Environ.Map) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "${")) {
            const end = std.mem.indexOfScalarPos(u8, text, i + 2, '}') orelse {
                try result.appendSlice(allocator, text[i..]);
                break;
            };
            const key = text[i + 2 .. end];
            if (environ_map.get(key)) |val| {
                try result.appendSlice(allocator, val);
            } else {
                // Keep literal if not found, or maybe error? Let's keep literal for now.
                try result.appendSlice(allocator, text[i .. end + 1]);
            }
            i = end + 1;
        } else {
            try result.append(allocator, text[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Read moonstone.toml from the current directory and config.toml from the
/// Moonstone config directory, merge their [registries] tables, and return
/// an ordered list of registry URLs sorted by priority (highest first).
///
/// Caller owns the returned memory and must call `deinit` on each entry
/// and `allocator.free` on the slice itself.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
) ![]registry.ResolvedRegistry {
    var result = std.ArrayList(registry.ResolvedRegistry).empty;
    errdefer {
        for (result.items) |*r| r.deinit(allocator);
        result.deinit(allocator);
    }

    var paths = try fs.resolve_moonstone(allocator, environ_map, io);
    defer paths.deinit(allocator);

    // ── 1. Read config.toml registries ────────────────────────────────────
    const config_file_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
    defer allocator.free(config_file_path);

    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_file_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound) {}
        break :blk null;
    };
    defer if (config_content) |c| allocator.free(c);

    if (config_content) |c| {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();
        const maybe_res = parser.parseString(c) catch |err| blk: {
            // TODO: handle error;
            std.debug.print("config parse error: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (maybe_res) |res| {
            defer res.deinit();
            if (res.value.get("registries")) |regs| {
                var it = regs.table.iterator();
                while (it.next()) |entry| {
                    const reg_name = entry.key_ptr.*;
                    if (std.mem.eql(u8, reg_name, "moonstone") or std.mem.eql(u8, reg_name, "rocks")) {
                        continue;
                    }
                    const cfg = entry.value_ptr.table;
                    const url_v = cfg.get("url");
                    const path_v = cfg.get("path");
                    const priority_v = cfg.get("priority");
                    const token_v = cfg.get("token");

                    var url: ?[]const u8 = null;
                    if (url_v) |u| {
                        url = try expandEnv(allocator, u.string, environ_map);
                    } else if (path_v) |p| {
                        const expanded_path = try expandEnv(allocator, p.string, environ_map);
                        defer allocator.free(expanded_path);
                        const abs_path = if (std.fs.path.isAbsolute(expanded_path))
                            try allocator.dupe(u8, expanded_path)
                        else
                            try std.fs.path.join(allocator, &.{ ".", expanded_path });
                        defer allocator.free(abs_path);
                        url = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
                    }

                    if (url) |u| {
                        const priority: i32 = if (priority_v) |p| switch (p) {
                            .integer => @intCast(p.integer),
                            .float => @intFromFloat(p.float),
                            else => 0,
                        } else 0;

                        const token = if (token_v) |t| try expandEnv(allocator, t.string, environ_map) else null;

                        try result.append(allocator, .{
                            .name = try allocator.dupe(u8, reg_name),
                            .url = u,
                            .token = token,
                            .priority = priority,
                        });
                    }
                }
            }
        }
    }

    // ── 2. Read moonstone.toml registries (override config) ───────────────
    const mt_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound) {}
        break :blk null;
    };
    defer if (mt_content) |c| allocator.free(c);

    if (mt_content) |c| {
        var parser = toml.Parser(manifest.MoonstoneToml).init(allocator);
        defer parser.deinit();
        const maybe_res = parser.parseString(c) catch |err| blk: {
            // TODO: handle err
            std.debug.print("config parse error: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        if (maybe_res) |res| {
            defer res.deinit();
            var it = res.value.registries.iterator();
            while (it.next()) |entry| {
                const reg_name = entry.key_ptr.*;
                if (std.mem.eql(u8, reg_name, "moonstone") or std.mem.eql(u8, reg_name, "rocks")) {
                    continue;
                }
                const cfg = entry.value_ptr.*;

                // Remove any config registry with matching name to avoid duplicate names in prefixing
                var i: usize = 0;
                while (i < result.items.len) {
                    if (std.mem.eql(u8, result.items[i].name, reg_name)) {
                        result.items[i].deinit(allocator);
                        _ = result.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }

                var url: ?[]const u8 = null;
                if (cfg.url) |u| {
                    url = try expandEnv(allocator, u, environ_map);
                } else if (cfg.path) |p| {
                    const expanded_path = try expandEnv(allocator, p, environ_map);
                    defer allocator.free(expanded_path);
                    const abs_path = if (std.fs.path.isAbsolute(expanded_path))
                        try allocator.dupe(u8, expanded_path)
                    else
                        try std.fs.path.join(allocator, &.{ ".", expanded_path });
                    defer allocator.free(abs_path);
                    url = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path});
                }

                if (url) |u| {
                    const token = if (cfg.token) |t| try expandEnv(allocator, t, environ_map) else null;
                    try result.append(allocator, .{
                        .name = try allocator.dupe(u8, reg_name),
                        .url = u,
                        .token = token,
                        .priority = cfg.priority,
                    });
                }
            }
        }
    }

    // ── 3. Fall back to default ───────────────────────────────────────────
    if (result.items.len == 0) {
        try result.append(allocator, .{
            .name = try allocator.dupe(u8, "official"),
            .url = try allocator.dupe(u8, @import("build_options").default_registry_url),
            .token = null,
            .priority = 0,
        });
    }

    // Sort by priority descending
    std.mem.sort(registry.ResolvedRegistry, result.items, {}, struct {
        fn lessThan(_: void, a: registry.ResolvedRegistry, b: registry.ResolvedRegistry) bool {
            return a.priority > b.priority;
        }
    }.lessThan);

    return try result.toOwnedSlice(allocator);
}
