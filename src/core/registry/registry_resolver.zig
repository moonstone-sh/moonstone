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

fn traceEnabled(env: *std.process.Environ.Map) bool {
    if (env.get("MOONSTONE_TRACE_REGISTRY")) |v| {
        return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    }
    return false;
}

fn trace(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[registry] " ++ fmt ++ "\n", args);
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

    const do_trace = traceEnabled(environ_map);

    var paths = try fs.resolve_moonstone(allocator, environ_map, io);
    defer paths.deinit(allocator);

    if (do_trace) trace("config_dir={s} data_dir={s}", .{ paths.config, paths.data });

    // ── 1. Read config.toml registries ────────────────────────────────────
    const config_file_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
    defer allocator.free(config_file_path);

    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_file_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound and do_trace) trace("config.toml read error: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (config_content) |c| allocator.free(c);

    if (config_content) |c| {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();
        const maybe_res = parser.parseString(c) catch |err| blk: {
            if (do_trace) trace("config.toml parse error: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (maybe_res) |res| {
            defer res.deinit();
            if (res.value.get("registries")) |regs_val| {
                var temp_map = std.StringArrayHashMapUnmanaged(manifest.RegistryConfig).empty;
                defer {
                    var it = temp_map.iterator();
                    while (it.next()) |entry| entry.value_ptr.*.deinit(allocator);
                    temp_map.deinit(allocator);
                }
                manifest.extractRegistriesFromToml(allocator, regs_val, &temp_map) catch |err| {
                    if (do_trace) trace("config.toml registry extraction error: {s}", .{@errorName(err)});
                };
                if (do_trace) trace("config.toml loaded {d} registries", .{temp_map.count()});
                var it = temp_map.iterator();
                while (it.next()) |entry| {
                    const reg_name = entry.key_ptr.*;
                    const cfg = entry.value_ptr.*;

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
                        if (do_trace) trace("config registry: name={s} url={s} priority={d}", .{ reg_name, u, cfg.priority });
                    }
                }
            } else if (do_trace) {
                trace("config.toml has no [registries] section", .{});
            }
        }
    }

    // ── 2. Read moonstone.toml registries (override config) ───────────────
    const mt_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
        if (err != error.FileNotFound and do_trace) trace("moonstone.toml read error: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (mt_content) |c| allocator.free(c);

    if (mt_content) |c| {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();
        const maybe_res = parser.parseString(c) catch |err| blk: {
            if (do_trace) trace("moonstone.toml parse error: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (maybe_res) |res| {
            defer res.deinit();
            if (res.value.get("registries")) |regs_val| {
                var temp_map = std.StringArrayHashMapUnmanaged(manifest.RegistryConfig).empty;
                defer {
                    var it = temp_map.iterator();
                    while (it.next()) |entry| entry.value_ptr.*.deinit(allocator);
                    temp_map.deinit(allocator);
                }
                manifest.extractRegistriesFromToml(allocator, regs_val, &temp_map) catch |err| {
                    if (do_trace) trace("moonstone.toml registry extraction error: {s}", .{@errorName(err)});
                };
                if (do_trace) trace("moonstone.toml loaded {d} registries", .{temp_map.count()});
                var it = temp_map.iterator();
                while (it.next()) |entry| {
                    const reg_name = entry.key_ptr.*;
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
                        if (do_trace) trace("project registry: name={s} url={s} priority={d}", .{ reg_name, u, cfg.priority });
                    }
                }
            } else if (do_trace) {
                trace("moonstone.toml has no [registries] section", .{});
            }
        }
    }

    // ── 3. Fall back to default ───────────────────────────────────────────
    if (result.items.len == 0) {
        const default_url = @import("build_options").default_registry_url;
        if (do_trace) trace("No custom registries loaded; falling back to default registry {s}", .{default_url});
        try result.append(allocator, .{
            .name = try allocator.dupe(u8, "official"),
            .url = try allocator.dupe(u8, default_url),
            .token = null,
            .priority = 0,
        });
    } else if (do_trace) {
        trace("Final registry list ({d} entries):", .{result.items.len});
        for (result.items) |r| {
            trace("  {s}: {s} (priority {d})", .{ r.name, r.url, r.priority });
        }
    }

    // Sort by priority descending
    std.mem.sort(registry.ResolvedRegistry, result.items, {}, struct {
        fn lessThan(_: void, a: registry.ResolvedRegistry, b: registry.ResolvedRegistry) bool {
            return a.priority > b.priority;
        }
    }.lessThan);

    return try result.toOwnedSlice(allocator);
}
