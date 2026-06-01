const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const Recipe = manifest.Recipe;

pub fn blake3_hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var hash_val: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &hash_val, .{});
    const hex = std.fmt.bytesToHex(hash_val, .lower);
    return try allocator.dupe(u8, &hex);
}

pub fn source_hash(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return blake3_hex(allocator, data);
}

pub fn recipe_hash(allocator: std.mem.Allocator, recipe: Recipe) ![]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});

    // Hash fields in a stable order
    try hasher.writer().print("schema_version={d}\n", .{recipe.schema_version});
    try hasher.writer().print("name={s}\n", .{recipe.name});
    try hasher.writer().print("version={s}\n", .{recipe.version});
    try hasher.writer().print("source_hash={s}\n", .{recipe.source_hash});
    try hasher.writer().print("materializer_kind={s}\n", .{recipe.materializer_kind});
    try hasher.writer().print("materializer_version={s}\n", .{recipe.materializer_version});
    try hasher.writer().print("runtime={s}\n", .{recipe.runtime});
    try hasher.writer().print("lua_abi={s}\n", .{recipe.lua_abi});
    try hasher.writer().print("target={s}\n", .{recipe.target});

    // Hash dependencies in sorted order
    var dep_keys = std.ArrayList([]const u8).empty;
    defer dep_keys.deinit(allocator);
    var it = recipe.dependency_artifact_hashes.iterator();
    while (it.next()) |entry| {
        try dep_keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, dep_keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (dep_keys.items) |key| {
        const val = recipe.dependency_artifact_hashes.get(key).?;
        try hasher.writer().print("dep:{s}={s}\n", .{ key, val });
    }

    if (recipe.command) |c| try hasher.writer().print("command={s}\n", .{c});
    if (recipe.args) |args| {
        for (args, 0..) |arg, i| {
            try hasher.writer().print("arg:{d}={s}\n", .{ i, arg });
        }
    }
    if (recipe.env) |env| {
        var env_keys = std.ArrayList([]const u8).empty;
        defer env_keys.deinit(allocator);
        var env_it = env.iterator();
        while (env_it.next()) |entry| {
            try env_keys.append(allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, env_keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        for (env_keys.items) |key| {
            const val = env.get(key).?;
            try hasher.writer().print("env:{s}={s}\n", .{ key, val });
        }
    }
    if (recipe.output_collection_rules) |o| try hasher.writer().print("output_rules={s}\n", .{o});

    var hash_val: [32]u8 = undefined;
    hasher.final(&hash_val);
    const hex = std.fmt.bytesToHex(hash_val, .lower);
    return try allocator.dupe(u8, &hex);
}

const ArtifactEntry = struct {
    rel_path: []const u8,
    kind: enum { file, symlink, directory },
    mode: u32,
    content_hash: [32]u8, // Only for files
    target: []const u8, // Only for symlinks

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.target);

        self.* = undefined;
    }
};

pub fn artifact_hash(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var entries = std.ArrayList(ArtifactEntry).empty;
    defer {
        for (entries.items) |*e| {
            e.deinit(allocator);
        }
        entries.deinit(allocator);
    }


    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        const rel_path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(rel_path);

        const stat = try dir.statFile(io, entry.path, .{});

        var artifact_entry = ArtifactEntry{
            .rel_path = rel_path,
            .kind = switch (entry.kind) {
                .file => .file,
                .sym_link => .symlink,
                .directory => .directory,
                else => continue, // Skip others
            },
            .mode = @as(u32, @intFromEnum(stat.permissions)),
            .content_hash = undefined,
            .target = &.{},
        };

        if (artifact_entry.kind == .file) {
            const content = try dir.readFileAlloc(io, entry.path, allocator, std.Io.Limit.limited(100 * 1024 * 1024));
            defer allocator.free(content);
            std.crypto.hash.Blake3.hash(content, &artifact_entry.content_hash, .{});
        } else if (artifact_entry.kind == .symlink) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = try dir.readLink(io, entry.path, &buf);
            artifact_entry.target = try allocator.dupe(u8, buf[0..len]);
        }

        try entries.append(allocator, artifact_entry);
    }

    // Sort entries by relative path for canonicalization
    std.mem.sort(ArtifactEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ArtifactEntry, b: ArtifactEntry) bool {
            return std.mem.lessThan(u8, a.rel_path, b.rel_path);
        }
    }.lessThan);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("moonstone-artifact-v0\n");

    for (entries.items) |e| {
        const formatted = switch (e.kind) {
            .file => blk: {
                const hex = std.fmt.bytesToHex(e.content_hash, .lower);
                break :blk try std.fmt.allocPrint(allocator, "file {s} mode={o} hash={s}\n", .{
                    e.rel_path,
                    e.mode & 0o777,
                    &hex,
                });
            },
            .symlink => try std.fmt.allocPrint(allocator, "symlink {s} -> {s}\n", .{ e.rel_path, e.target }),
            .directory => try std.fmt.allocPrint(allocator, "dir {s}\n", .{e.rel_path}),
        };
        defer allocator.free(formatted);
        hasher.update(formatted);
    }

    var hash_val: [32]u8 = undefined;
    hasher.final(&hash_val);
    const hex = std.fmt.bytesToHex(hash_val, .lower);
    return try allocator.dupe(u8, &hex);
}

test "blake3_hex works" {
    const allocator = std.testing.allocator;
    const h = try blake3_hex(allocator, "hello");
    defer allocator.free(h);
    // echo -n "hello" | b3sum --no-names
    try std.testing.expectEqualStrings("ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f", h);
}

pub fn blake3_file(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file_content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(50 * 1024 * 1024));
    defer allocator.free(file_content);
    const hex = try blake3_hex(allocator, file_content);
    defer allocator.free(hex);
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{hex});
}
