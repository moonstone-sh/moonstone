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
    source_kind: []const u8 = &.{},
    source_payload: []const u8 = &.{},
    rockspec: []const u8 = &.{},
    rockspec_hash: []const u8 = &.{},
    rockspec_payload: []const u8 = &.{},
    resolver: []const u8 = &.{},
    link_mode: []const u8 = &.{},
    reproducible: bool = true,
    roles: []const []const u8 = &.{},

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
        if (self.source_kind.len > 0) allocator.free(self.source_kind);
        if (self.source_payload.len > 0) allocator.free(self.source_payload);
        if (self.rockspec.len > 0) allocator.free(self.rockspec);
        if (self.rockspec_hash.len > 0) allocator.free(self.rockspec_hash);
        if (self.rockspec_payload.len > 0) allocator.free(self.rockspec_payload);
        if (self.resolver.len > 0) allocator.free(self.resolver);
        if (self.link_mode.len > 0) allocator.free(self.link_mode);
        for (self.roles) |g| allocator.free(g);
        if (self.roles.len > 0) allocator.free(self.roles);
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
        if (content.len == 0) return LockFile.init(allocator);
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
                    .source_kind = if (t.get("source_kind")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .source_payload = if (t.get("source_payload")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .rockspec = if (t.get("rockspec")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .rockspec_hash = if (t.get("rockspec_hash")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .rockspec_payload = if (t.get("rockspec_payload")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .resolver = if (t.get("resolver")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .link_mode = if (t.get("link_mode")) |s| try allocator.dupe(u8, s.string) else &.{},
                    .reproducible = reproducible,
                    .roles = blk: {
                        if (t.get("roles")) |g| {
                            if (g == .array) {
                                var list = std.ArrayList([]const u8).empty;
                                for (g.array.items) |item| {
                                    if (item == .string) {
                                        try list.append(allocator, try allocator.dupe(u8, item.string));
                                    }
                                }
                                break :blk try list.toOwnedSlice(allocator);
                            }
                        }
                        break :blk &.{};
                    },
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
        \\source_kind = "luarocks_src_rock"
        \\source_payload = "sources/inspect-3.1.3-1.src.rock"
        \\rockspec = "https://luarocks.org/inspect-3.1.3-1.rockspec"
        \\rockspec_hash = "b3:rockspec123"
        \\rockspec_payload = "sources/inspect-3.1.3-1.rockspec"
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
    try std.testing.expectEqualStrings("luarocks_src_rock", lf.packages.items[0].source_kind);
    try std.testing.expectEqualStrings("sources/inspect-3.1.3-1.src.rock", lf.packages.items[0].source_payload);
    try std.testing.expectEqualStrings("https://luarocks.org/inspect-3.1.3-1.rockspec", lf.packages.items[0].rockspec);
    try std.testing.expectEqualStrings("b3:rockspec123", lf.packages.items[0].rockspec_hash);
    try std.testing.expectEqualStrings("sources/inspect-3.1.3-1.rockspec", lf.packages.items[0].rockspec_payload);
    try std.testing.expectEqualStrings("link:my-lib", lf.packages.items[1].source);
    try std.testing.expectEqual(@as(usize, 0), lf.packages.items[1].source_payload.len);
    try std.testing.expectEqual(false, lf.packages.items[1].reproducible);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try lf.serialize(allocator, &aw.writer);
    try aw.writer.flush();

    var lf2 = try LockFile.parse(allocator, aw.written());
    defer lf2.deinit();

    try std.testing.expectEqualStrings(lf.packages.items[0].name, lf2.packages.items[0].name);
    try std.testing.expectEqualStrings(lf.packages.items[0].source_payload, lf2.packages.items[0].source_payload);
    try std.testing.expectEqualStrings(lf.packages.items[0].rockspec_hash, lf2.packages.items[0].rockspec_hash);
    try std.testing.expectEqualStrings(lf.packages.items[0].rockspec_payload, lf2.packages.items[0].rockspec_payload);
    try std.testing.expectEqual(lf.packages.items[1].reproducible, lf2.packages.items[1].reproducible);
}
