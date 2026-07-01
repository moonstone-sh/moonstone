const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

const SourceKind = moonstone.cache.manifest.SourceKind;

fn writeJsonString(stdout: *std.Io.Writer, value: []const u8) !void {
    try stdout.print("\"", .{});
    for (value) |c| {
        switch (c) {
            '"' => try stdout.print("\\\"", .{}),
            '\\' => try stdout.print("\\\\", .{}),
            '\n' => try stdout.print("\\n", .{}),
            '\r' => try stdout.print("\\r", .{}),
            '\t' => try stdout.print("\\t", .{}),
            else => try stdout.print("{c}", .{c}),
        }
    }
    try stdout.print("\"", .{});
}

fn parseSource(value: []const u8) ?SourceKind {
    if (std.mem.eql(u8, value, "rocks") or std.mem.eql(u8, value, "luarocks")) return .luarocks;
    if (std.mem.eql(u8, value, "registry") or std.mem.eql(u8, value, "moonstone")) return .registry;
    if (std.mem.eql(u8, value, "all")) return null;
    return null;
}

fn initCache(ctx: *router.Context) !moonstone.cache.manifest.ManifestCache {
    const paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
    defer {
        var p = paths;
        p.deinit(ctx.allocator);
    }
    const cfg = moonstone.cache.manifest.getConfig(ctx.allocator, ctx.env, ctx.io);
    return try moonstone.cache.manifest.ManifestCache.init(ctx.allocator, ctx.io, paths, cfg);
}

pub const CacheManifestListCommand = struct {
    pub const name = "list";
    pub const description = "List cached package manifests/indexes";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon cache manifest list [--json]
            \\
            \\List cached LuaRocks manifests and Moonstone registry indexes.
            \\
        , .{});
    }

    pub fn run(self: CacheManifestListCommand, ctx: *router.Context) !void {
        var cache = try initCache(ctx);
        defer cache.deinit();
        const entries = try cache.list();
        defer {
            for (entries) |*entry| entry.deinit(ctx.allocator);
            ctx.allocator.free(entries);
        }

        if (self.json) {
            try ctx.stdout.print("[", .{});
            for (entries, 0..) |entry, i| {
                if (i > 0) try ctx.stdout.print(",", .{});
                try ctx.stdout.print("{{\"source\":", .{});
                try writeJsonString(ctx.stdout, entry.metadata.source.asString());
                try ctx.stdout.print(",\"key\":", .{});
                try writeJsonString(ctx.stdout, entry.metadata.key);
                try ctx.stdout.print(",\"fresh\":{},\"fetched_at\":{d},\"ttl_seconds\":{d},\"path\":", .{ entry.fresh, entry.metadata.fetched_at, entry.metadata.ttl_seconds });
                try writeJsonString(ctx.stdout, entry.metadata.payload_path);
                try ctx.stdout.print("}}", .{});
            }
            try ctx.stdout.print("]\n", .{});
            return;
        }

        try ctx.stdout.print("Source       Fresh  Key\n", .{});
        try ctx.stdout.print("------------------------------------------------------------\n", .{});
        for (entries) |entry| {
            try ctx.stdout.print("{s: <12} {s: <5}  {s}\n", .{ entry.metadata.source.asString(), if (entry.fresh) "yes" else "no", entry.metadata.key });
        }
    }
};

pub const CacheManifestPathCommand = struct {
    pub const name = "path";
    pub const description = "Print manifest cache path";

    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon cache manifest path [rocks|registry]
            \\
        , .{});
    }

    pub fn run(self: CacheManifestPathCommand, ctx: *router.Context) !void {
        var cache = try initCache(ctx);
        defer cache.deinit();
        if (self.positionals.len == 0) {
            try ctx.stdout.print("{s}\n", .{cache.root});
            return;
        }
        const source = parseSource(self.positionals[0]) orelse return error.UnknownCommand;
        const path = try std.fs.path.join(ctx.allocator, &.{ cache.root, source.asString() });
        defer ctx.allocator.free(path);
        try ctx.stdout.print("{s}\n", .{path});
    }
};

pub const CacheManifestClearCommand = struct {
    pub const name = "clear";
    pub const description = "Clear cached manifests/indexes";

    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon cache manifest clear [rocks|registry|all]
            \\
        , .{});
    }

    pub fn run(self: CacheManifestClearCommand, ctx: *router.Context) !void {
        var cache = try initCache(ctx);
        defer cache.deinit();
        const source = if (self.positionals.len == 0) null else parseSource(self.positionals[0]) orelse return error.UnknownCommand;
        cache.clearSource(source);
        try ctx.stdout.print("Manifest cache cleared.\n", .{});
    }
};

pub const CacheManifestRefreshCommand = struct {
    pub const name = "refresh";
    pub const description = "Refresh cached manifests/indexes";

    abi: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon cache manifest refresh [rocks|registry|all] [--abi <5.4>]
            \\
        , .{});
    }

    pub fn run(self: CacheManifestRefreshCommand, ctx: *router.Context) !void {
        const source = if (self.positionals.len == 0) null else parseSource(self.positionals[0]) orelse return error.UnknownCommand;
        var cache = try initCache(ctx);
        defer cache.deinit();
        if (source == null or source.? == .luarocks) {
            cache.clearSource(.luarocks);
            const abi = self.abi orelse "5.4";
            try moonstone.resolution.sources.luarocks.refreshManifest(ctx.allocator, ctx.io, abi, ctx.env, null, null);
            try ctx.stdout.print("LuaRocks manifest refreshed for Lua {s}.\n", .{abi});
        }
        if (source == null or source.? == .registry) {
            cache.clearSource(.registry);
            const registries = try moonstone.registry.resolver.resolve(ctx.allocator, ctx.io, ctx.env);
            defer moonstone.registry.core.deinitResolved(registries, ctx.allocator);
            for (registries) |reg| {
                var client = moonstone.registry.core.RegistryClient.init(ctx.allocator, ctx.io, reg.url, reg.token, ctx.env);
                defer client.deinit();
                var idx = client.fetch_index() catch continue;
                idx.deinit(ctx.allocator);
                if (try client.fetch_private_index()) |private_idx| {
                    var private_mut = private_idx;
                    private_mut.deinit(ctx.allocator);
                }
            }
            try ctx.stdout.print("Moonstone registry indexes refreshed.\n", .{});
        }
    }
};
