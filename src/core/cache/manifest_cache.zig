const std = @import("std");
const fs = @import("../platform/fs.zig");
const hash = @import("../identity/hash.zig");

const ns_per_s = std.time.ns_per_s;

pub const SourceKind = enum {
    luarocks,
    registry,

    pub fn asString(self: SourceKind) []const u8 {
        return switch (self) {
            .luarocks => "luarocks",
            .registry => "registry",
        };
    }

    pub fn fromString(value: []const u8) ?SourceKind {
        if (std.mem.eql(u8, value, "luarocks")) return .luarocks;
        if (std.mem.eql(u8, value, "registry")) return .registry;
        return null;
    }
};

pub const CacheConfig = struct {
    enabled: bool = true,
    ttl_seconds: u64 = 24 * 60 * 60,
};

pub const CacheKey = struct {
    source: SourceKind,
    scope: []const u8,
    name: []const u8,
    extension: []const u8 = "data",

    pub fn display(self: CacheKey, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ self.source.asString(), self.scope, self.name });
    }
};

pub const Metadata = struct {
    source: SourceKind,
    key: []const u8,
    url: []const u8,
    fetched_at: i128,
    ttl_seconds: u64,
    hash: []const u8,
    payload_path: []const u8,

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.url);
        allocator.free(self.hash);
        allocator.free(self.payload_path);
    }

    pub fn isFresh(self: Metadata, io: std.Io) bool {
        const now = nowSeconds(io) catch return false;
        if (now < self.fetched_at) return true;
        return @as(u128, @intCast(now - self.fetched_at)) <= self.ttl_seconds;
    }
};

pub const Entry = struct {
    metadata: Metadata,
    meta_path: []const u8,
    fresh: bool,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        self.metadata.deinit(allocator);
        allocator.free(self.meta_path);
    }
};

pub const ManifestCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    config: CacheConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, paths: fs.MOONSTONE_PATHS, config: CacheConfig) !ManifestCache {
        const root = try std.fs.path.join(allocator, &.{ paths.cache, "manifests" });
        return .{ .allocator = allocator, .io = io, .root = root, .config = config };
    }

    pub fn deinit(self: ManifestCache) void {
        self.allocator.free(self.root);
    }

    pub fn readFresh(self: ManifestCache, key: CacheKey) !?[]u8 {
        if (!self.config.enabled) return null;
        var meta = (try self.readMetadata(key)) orelse return null;
        defer meta.deinit(self.allocator);
        if (!meta.isFresh(self.io)) return null;
        return try self.readPayload(meta);
    }

    pub fn readAny(self: ManifestCache, key: CacheKey) !?[]u8 {
        if (!self.config.enabled) return null;
        var meta = (try self.readMetadata(key)) orelse return null;
        defer meta.deinit(self.allocator);
        return try self.readPayload(meta);
    }

    pub fn write(self: ManifestCache, key: CacheKey, url: []const u8, payload: []const u8) !void {
        if (!self.config.enabled) return;
        const payload_path = try self.payloadPath(key);
        defer self.allocator.free(payload_path);
        const meta_path = try self.metaPath(key);
        defer self.allocator.free(meta_path);

        if (std.fs.path.dirname(payload_path)) |parent| try std.Io.Dir.cwd().createDirPath(self.io, parent);
        const payload_file = try std.Io.Dir.cwd().createFile(self.io, payload_path, .{});
        try payload_file.writeStreamingAll(self.io, payload);
        payload_file.close(self.io);

        const digest = try hash.blake3_hex(self.allocator, payload);
        defer self.allocator.free(digest);
        const prefixed_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{digest});
        defer self.allocator.free(prefixed_hash);
        const display_key = try key.display(self.allocator);
        defer self.allocator.free(display_key);
        const fetched_at = try nowSeconds(self.io);

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        try writer.writer.print(
            "source={s}\nkey={s}\nurl={s}\nfetched_at={d}\nttl_seconds={d}\nhash={s}\npayload_path={s}\n",
            .{ key.source.asString(), display_key, url, fetched_at, self.config.ttl_seconds, prefixed_hash, payload_path },
        );
        if (std.fs.path.dirname(meta_path)) |parent| try std.Io.Dir.cwd().createDirPath(self.io, parent);
        const meta_file = try std.Io.Dir.cwd().createFile(self.io, meta_path, .{});
        try meta_file.writeStreamingAll(self.io, writer.written());
        meta_file.close(self.io);
    }

    pub fn remove(self: ManifestCache, key: CacheKey) void {
        const payload_path = self.payloadPath(key) catch return;
        defer self.allocator.free(payload_path);
        const meta_path = self.metaPath(key) catch return;
        defer self.allocator.free(meta_path);
        std.Io.Dir.cwd().deleteFile(self.io, payload_path) catch {};
        std.Io.Dir.cwd().deleteFile(self.io, meta_path) catch {};
    }

    pub fn clearSource(self: ManifestCache, source: ?SourceKind) void {
        if (source) |s| {
            const source_dir = std.fs.path.join(self.allocator, &.{ self.root, s.asString() }) catch return;
            defer self.allocator.free(source_dir);
            std.Io.Dir.cwd().deleteTree(self.io, source_dir) catch {};
        } else {
            std.Io.Dir.cwd().deleteTree(self.io, self.root) catch {};
        }
    }

    pub fn list(self: ManifestCache) ![]Entry {
        var entries = std.ArrayList(Entry).empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }
        try self.scanMetaDir(self.root, &entries);
        return try entries.toOwnedSlice(self.allocator);
    }

    pub fn payloadPath(self: ManifestCache, key: CacheKey) ![]const u8 {
        const escaped_scope = try escapeKey(self.allocator, key.scope);
        defer self.allocator.free(escaped_scope);
        const escaped_name = try escapeKey(self.allocator, key.name);
        defer self.allocator.free(escaped_name);
        const expected_suffix = try std.fmt.allocPrint(self.allocator, ".{s}", .{key.extension});
        defer self.allocator.free(expected_suffix);
        const file_name = if (std.mem.endsWith(u8, escaped_name, expected_suffix))
            try self.allocator.dupe(u8, escaped_name)
        else
            try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ escaped_name, key.extension });
        defer self.allocator.free(file_name);
        return try std.fs.path.join(self.allocator, &.{ self.root, key.source.asString(), escaped_scope, file_name });
    }

    pub fn metaPath(self: ManifestCache, key: CacheKey) ![]const u8 {
        const payload_path = try self.payloadPath(key);
        defer self.allocator.free(payload_path);
        return try std.fmt.allocPrint(self.allocator, "{s}.meta", .{payload_path});
    }

    fn readPayload(self: ManifestCache, metadata: Metadata) !?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, metadata.payload_path, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn readMetadata(self: ManifestCache, key: CacheKey) !?Metadata {
        const meta_path = try self.metaPath(key);
        defer self.allocator.free(meta_path);
        return try readMetadataFile(self.allocator, self.io, meta_path);
    }

    fn scanMetaDir(self: ManifestCache, path: []const u8, entries: *std.ArrayList(Entry)) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            const child_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            defer self.allocator.free(child_path);
            switch (entry.kind) {
                .directory => try self.scanMetaDir(child_path, entries),
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".meta")) continue;
                    var meta = (try readMetadataFile(self.allocator, self.io, child_path)) orelse continue;
                    errdefer meta.deinit(self.allocator);
                    try entries.append(self.allocator, .{
                        .metadata = meta,
                        .meta_path = try self.allocator.dupe(u8, child_path),
                        .fresh = meta.isFresh(self.io),
                    });
                },
                else => {},
            }
        }
    }
};

fn readMetadataFile(allocator: std.mem.Allocator, io: std.Io, meta_path: []const u8) !?Metadata {
    const content = std.Io.Dir.cwd().readFileAlloc(io, meta_path, allocator, std.Io.Limit.limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    var source: ?SourceKind = null;
    var key: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var fetched_at: ?i128 = null;
    var ttl_seconds: ?u64 = null;
    var hash_value: ?[]const u8 = null;
    var payload_path: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, name, "source")) source = SourceKind.fromString(value);
        if (std.mem.eql(u8, name, "key")) key = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, name, "url")) url = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, name, "fetched_at")) fetched_at = std.fmt.parseInt(i128, value, 10) catch null;
        if (std.mem.eql(u8, name, "ttl_seconds")) ttl_seconds = std.fmt.parseInt(u64, value, 10) catch null;
        if (std.mem.eql(u8, name, "hash")) hash_value = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, name, "payload_path")) payload_path = try allocator.dupe(u8, value);
    }

    return Metadata{
        .source = source orelse return error.InvalidManifestCacheMetadata,
        .key = key orelse try allocator.dupe(u8, ""),
        .url = url orelse try allocator.dupe(u8, ""),
        .fetched_at = fetched_at orelse 0,
        .ttl_seconds = ttl_seconds orelse 0,
        .hash = hash_value orelse try allocator.dupe(u8, ""),
        .payload_path = payload_path orelse try allocator.dupe(u8, ""),
    };
}

pub fn getConfig(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) CacheConfig {
    const paths = fs.resolve_moonstone(allocator, env, io) catch return .{};
    defer {
        var p = paths;
        p.deinit(allocator);
    }
    const config_file_path = std.fs.path.join(allocator, &.{ paths.config, "config.toml" }) catch return .{};
    defer allocator.free(config_file_path);
    const config_content = std.Io.Dir.cwd().readFileAlloc(io, config_file_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch return .{};
    defer allocator.free(config_content);
    var parser = @import("toml").Parser(@import("toml").Table).init(allocator);
    defer parser.deinit();
    const res = parser.parseString(config_content) catch return .{};
    defer res.deinit();

    var cfg = CacheConfig{};
    const table = res.value;
    if (table.get("cache")) |cache_val| switch (cache_val) {
        .table => |cache_table| {
            if (cache_table.get("manifest_cache")) |enabled_val| switch (enabled_val) {
                .boolean => |b| cfg.enabled = b,
                else => {},
            };
            if (cache_table.get("manifest_ttl")) |ttl_val| {
                if (parseDurationSeconds(ttl_val)) |seconds| cfg.ttl_seconds = seconds;
            }
        },
        else => {},
    };
    return cfg;
}

fn parseDurationSeconds(value: @import("toml").Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        .string => |s| parseDurationString(s),
        else => null,
    };
}

fn parseDurationString(input: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    var unit_start = trimmed.len;
    for (trimmed, 0..) |c, i| {
        if (c < '0' or c > '9') {
            unit_start = i;
            break;
        }
    }
    const amount = std.fmt.parseInt(u64, trimmed[0..unit_start], 10) catch return null;
    const unit = std.mem.trim(u8, trimmed[unit_start..], " \t\r\n");
    if (unit.len == 0 or std.mem.eql(u8, unit, "s") or std.mem.eql(u8, unit, "sec") or std.mem.eql(u8, unit, "seconds")) return amount;
    if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "min") or std.mem.eql(u8, unit, "minutes")) return amount * 60;
    if (std.mem.eql(u8, unit, "h") or std.mem.eql(u8, unit, "hour") or std.mem.eql(u8, unit, "hours")) return amount * 60 * 60;
    if (std.mem.eql(u8, unit, "d") or std.mem.eql(u8, unit, "day") or std.mem.eql(u8, unit, "days")) return amount * 24 * 60 * 60;
    return null;
}

fn escapeKey(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789abcdef";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '_');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn nowSeconds(io: std.Io) !i128 {
    return @divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, ns_per_s);
}

test "manifest cache duration parser" {
    try std.testing.expectEqual(@as(?u64, 24 * 60 * 60), parseDurationString("24h"));
    try std.testing.expectEqual(@as(?u64, 2 * 24 * 60 * 60), parseDurationString("2 days"));
    try std.testing.expectEqual(@as(?u64, 30 * 60), parseDurationString("30m"));
}

test "manifest cache writes reads and lists fresh payloads" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "/tmp/moonstone-manifest-cache-unit";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var paths = fs.MOONSTONE_PATHS{
        .data = try allocator.dupe(u8, root),
        .bin = try std.fs.path.join(allocator, &.{ root, "bin" }),
        .store = try std.fs.path.join(allocator, &.{ root, "store" }),
        .index = try std.fs.path.join(allocator, &.{ root, "index" }),
        .tmp = try std.fs.path.join(allocator, &.{ root, "tmp" }),
        .cache = try std.fs.path.join(allocator, &.{ root, "cache" }),
        .shims = try std.fs.path.join(allocator, &.{ root, "shims" }),
        .downloads = try std.fs.path.join(allocator, &.{ root, "downloads" }),
        .config = try std.fs.path.join(allocator, &.{ root, "config" }),
        .projects = try std.fs.path.join(allocator, &.{ root, "projects" }),
    };
    defer paths.deinit(allocator);

    var cache = try ManifestCache.init(allocator, io, paths, .{ .ttl_seconds = 60 });
    defer cache.deinit();
    const key = CacheKey{ .source = .luarocks, .scope = "https://luarocks.org", .name = "manifest-5.4.json", .extension = "json" };
    try cache.write(key, "https://luarocks.org/manifest-5.4.json", "{\"repository\":{}}");

    const payload = (try cache.readFresh(key)).?;
    defer allocator.free(payload);
    try std.testing.expectEqualStrings("{\"repository\":{}}", payload);

    const entries = try cache.list();
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].fresh);
}
