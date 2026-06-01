const std = @import("std");
const toml = @import("toml");
const manifest = @import("manifest.zig");
const Kind = manifest.Kind;

pub const LockEntry = struct {
    name: []const u8 = &.{},
    version: []const u8 = &.{},
    kind: Kind = .script,
    source_hash: []const u8 = &.{},
    recipe_hash: []const u8 = &.{},
    artifact_hash: []const u8 = &.{},
    runtime: []const u8 = &.{},
    lua_abi: []const u8 = &.{},
    target: []const u8 = &.{},
    constellation: []const u8 = &.{},
    source: []const u8 = &.{},
    resolver: []const u8 = &.{},
    link_mode: []const u8 = &.{},
    reproducible: bool = true,

    pub fn deinit(self: LockEntry, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.source_hash.len > 0) allocator.free(self.source_hash);
        if (self.recipe_hash.len > 0) allocator.free(self.recipe_hash);
        if (self.artifact_hash.len > 0) allocator.free(self.artifact_hash);
        if (self.runtime.len > 0) allocator.free(self.runtime);
        if (self.lua_abi.len > 0) allocator.free(self.lua_abi);
        if (self.target.len > 0) allocator.free(self.target);
        if (self.constellation.len > 0) allocator.free(self.constellation);
        if (self.source.len > 0) allocator.free(self.source);
        if (self.resolver.len > 0) allocator.free(self.resolver);
        if (self.link_mode.len > 0) allocator.free(self.link_mode);
    }
};

pub const LockFile = struct {
    packages: std.ArrayList(LockEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LockFile {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockFile) void {
        for (self.packages.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.packages.deinit(self.allocator);
    }

    pub fn serialize(self: LockFile, allocator: std.mem.Allocator, writer: anytype) !void {
        const S = struct {
            package: []const LockEntry,
        };

        const s: S = .{
            .package = self.packages.items,
        };

        try toml.serialize(allocator, s, writer);
    }

    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !LockFile {
        var parser = toml.Parser(toml.Table).init(allocator);
        defer parser.deinit();

        var res = try parser.parseString(content);
        defer res.deinit();

        const root = res.value;
        var lf = LockFile.init(allocator);
        errdefer lf.deinit();

        if (root.get("package")) |v| {
            for (v.array.items) |pkg_val| {
                const t = pkg_val.table;
                const reproducible = blk: {
                    const rep = t.get("reproducible");
                    if (rep) |r| {
                        if (r == .boolean) break :blk r.boolean;
                    }
                    break :blk true;
                };
                try lf.packages.append(allocator, .{
                    .name = try allocator.dupe(u8, (t.get("name") orelse return error.MissingName).string),
                    .version = try allocator.dupe(u8, (t.get("version") orelse return error.MissingVersion).string),
                    .kind = try Kind.from_string((t.get("kind") orelse return error.MissingKind).string),
                    .source_hash = if (t.get("source_hash")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .recipe_hash = try allocator.dupe(u8, (t.get("recipe_hash") orelse return error.MissingRecipeHash).string),
                    .artifact_hash = try allocator.dupe(u8, (t.get("artifact_hash") orelse return error.MissingArtifactHash).string),
                    .runtime = try allocator.dupe(u8, (t.get("runtime") orelse return error.MissingRuntime).string),
                    .lua_abi = try allocator.dupe(u8, (t.get("lua_abi") orelse return error.MissingLuaAbi).string),
                    .target = try allocator.dupe(u8, (t.get("target") orelse return error.MissingTarget).string),
                    .constellation = try allocator.dupe(u8, (t.get("constellation") orelse return error.MissingConstellation).string),
                    .source = if (t.get("source")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .resolver = if (t.get("resolver")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .link_mode = if (t.get("link_mode")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .reproducible = reproducible,
                });
            }
        }

        return lf;
    }

    pub fn find(self: *const LockFile, name: []const u8) ?*const LockEntry {
        for (self.packages.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn remove(self: *LockFile, name: []const u8) void {
        var i: usize = 0;
        while (i < self.packages.items.len) {
            if (std.mem.eql(u8, self.packages.items[i].name, name)) {
                const old = self.packages.swapRemove(i);
                old.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }
};

test "lockfile roundtrip" {
    const allocator = std.testing.allocator;
    const content =
        \\[[package]]
        \\name = "inspect"
        \\version = "3.1.3"
        \\kind = "lib"
        \\source_hash = "b3:..."
        \\recipe_hash = "b3:..."
        \\artifact_hash = "b3:..."
        \\runtime = "lua54"
        \\lua_abi = "lua54"
        \\target = "native"
        \\constellation = "default"
        \\source = "registry"
        \\link_mode = ""
        \\reproducible = true
        \\
        \\[[package]]
        \\name = "my-lib"
        \\version = "0.1.0"
        \\kind = "lib"
        \\artifact_hash = "b3:abc123"
        \\source_hash = "b3:src456"
        \\recipe_hash = "b3:rcp789"
        \\runtime = "lua54"
        \\lua_abi = "lua54"
        \\target = "native"
        \\constellation = "default"
        \\source = "link:my-lib"
        \\link_mode = "live"
        \\reproducible = false
        \\
    ;

    var lf = try LockFile.parse(allocator, content);
    defer lf.deinit();

    try std.testing.expectEqual(2, lf.packages.items.len);
    try std.testing.expectEqualStrings("inspect", lf.packages.items[0].name);
    try std.testing.expectEqualStrings("link:my-lib", lf.packages.items[1].source);
    try std.testing.expectEqual(false, lf.packages.items[1].reproducible);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try lf.serialize(allocator, &aw.writer);
    try aw.writer.flush();

    var lf2 = try LockFile.parse(allocator, aw.written());
    defer lf2.deinit();

    try std.testing.expectEqualStrings(lf.packages.items[0].name, lf2.packages.items[0].name);
    try std.testing.expectEqual(lf.packages.items[1].reproducible, lf2.packages.items[1].reproducible);
}
