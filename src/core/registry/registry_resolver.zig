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

/// Read project registries from moonstone.toml and return an ordered list of
/// registry URLs sorted by priority (highest first). Ties (two registries
/// declared at the same priority) resolve by declaration order in
/// moonstone.toml's `[[registries]]` array -- the earlier entry wins. This
/// order is what an unprefixed package spec (no `name:` prefix and no
/// `registry = "..."` field) walks when it consults "every registry of this
/// resolver kind": the first registry in this list that has a satisfying
/// version wins, so a higher-priority registry can deliberately shadow a
/// package that also exists in a lower-priority one. Global config
/// registries are intentionally not resolution fallbacks: projects declare
/// their exact transports for reproducible installs.
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

    // ── 1. Read moonstone.toml registries ──────────────────────────────────
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
                        try result.append(allocator, .{
                            .name = try allocator.dupe(u8, reg_name),
                            .resolver = try allocator.dupe(u8, cfg.resolver),
                            .url = u,
                            .token = null,
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

    // ── 3. Compatibility fallback for the official registry ─────────────
    // New projects declare `moonstone` explicitly. Retain the fallback only
    // for legacy manifests which do not, so a declared URL is authoritative.
    var has_declared_moonstone = false;
    for (result.items) |entry| {
        if (std.mem.eql(u8, entry.name, "moonstone")) {
            has_declared_moonstone = true;
            break;
        }
    }
    if (!has_declared_moonstone) {
        const default_url = environ_map.get("MOONSTONE_REGISTRY_PATH") orelse @import("build_options").default_registry_url;
        try result.append(allocator, .{
            .name = try allocator.dupe(u8, "moonstone"),
            .resolver = try allocator.dupe(u8, "moonstone"),
            .url = try allocator.dupe(u8, default_url),
            .token = null,
            .priority = 0,
        });
    }
    if (do_trace) {
        trace("Final registry list ({d} entries):", .{result.items.len});
        for (result.items) |r| {
            trace("  {s}: {s} (priority {d})", .{ r.name, r.url, r.priority });
        }
    }

    try sortByPriorityThenDeclarationOrder(allocator, result.items);

    return try result.toOwnedSlice(allocator);
}

/// Sort resolved registries by priority descending. Two registries declared
/// at the same priority are ordered by their declaration order in
/// moonstone.toml -- `items` must already be in that order (the order
/// `[[registries]]` entries were appended in, above) when this is called:
/// whichever registry comes first in the array wins ties.
///
/// This is an explicit secondary sort key rather than relying on
/// `std.mem.sort`'s stability alone, so the tie-break cannot silently
/// regress if a future change swaps in an unstable sort.
///
/// A higher-priority registry can therefore "shadow" a package that also
/// exists in a lower-priority registry of the same resolver kind -- this is
/// intentional: priority is an explicit choice the project author makes in
/// moonstone.toml, not an accident of iteration order.
fn sortByPriorityThenDeclarationOrder(allocator: std.mem.Allocator, items: []registry.ResolvedRegistry) !void {
    const IndexedEntry = struct {
        declared_index: usize,
        entry: registry.ResolvedRegistry,
    };
    const indexed = try allocator.alloc(IndexedEntry, items.len);
    defer allocator.free(indexed);
    for (items, 0..) |entry, i| indexed[i] = .{ .declared_index = i, .entry = entry };

    std.mem.sort(IndexedEntry, indexed, {}, struct {
        fn lessThan(_: void, a: IndexedEntry, b: IndexedEntry) bool {
            if (a.entry.priority != b.entry.priority) return a.entry.priority > b.entry.priority;
            return a.declared_index < b.declared_index;
        }
    }.lessThan);

    for (indexed, 0..) |item, i| items[i] = item.entry;
}

fn testRegistry(name: []const u8, priority: i32) registry.ResolvedRegistry {
    return .{
        .name = name,
        .resolver = "moonstone",
        .url = "file:///dev/null",
        .token = null,
        .priority = priority,
    };
}

test "sortByPriorityThenDeclarationOrder orders by priority descending" {
    const allocator = std.testing.allocator;
    var items = [_]registry.ResolvedRegistry{
        testRegistry("low", 0),
        testRegistry("high", 100),
        testRegistry("mid", 50),
    };
    try sortByPriorityThenDeclarationOrder(allocator, &items);

    try std.testing.expectEqualStrings("high", items[0].name);
    try std.testing.expectEqualStrings("mid", items[1].name);
    try std.testing.expectEqualStrings("low", items[2].name);
}

test "sortByPriorityThenDeclarationOrder breaks equal-priority ties by declaration order" {
    const allocator = std.testing.allocator;
    // "zeta" is declared before "alpha" here; equal priority must preserve
    // that order rather than falling back to something else (e.g.
    // alphabetical, or whatever an unstable sort happens to produce).
    var items = [_]registry.ResolvedRegistry{
        testRegistry("zeta", 10),
        testRegistry("alpha", 10),
        testRegistry("beta", 10),
    };
    try sortByPriorityThenDeclarationOrder(allocator, &items);

    try std.testing.expectEqualStrings("zeta", items[0].name);
    try std.testing.expectEqualStrings("alpha", items[1].name);
    try std.testing.expectEqualStrings("beta", items[2].name);
}

test "sortByPriorityThenDeclarationOrder combines priority with declaration-order ties" {
    const allocator = std.testing.allocator;
    var items = [_]registry.ResolvedRegistry{
        testRegistry("low-first", 0),
        testRegistry("high-first", 10),
        testRegistry("low-second", 0),
        testRegistry("high-second", 10),
    };
    try sortByPriorityThenDeclarationOrder(allocator, &items);

    try std.testing.expectEqualStrings("high-first", items[0].name);
    try std.testing.expectEqualStrings("high-second", items[1].name);
    try std.testing.expectEqualStrings("low-first", items[2].name);
    try std.testing.expectEqualStrings("low-second", items[3].name);
}
