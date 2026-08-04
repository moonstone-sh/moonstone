const std = @import("std");
const toml = @import("toml");
const manifest = @import("manifest.zig");
const Kind = manifest.Kind;
const replay_mod = @import("replay_contract.zig");

pub const LockEntry = struct {
    name: []const u8 = &.{},
    version: []const u8 = &.{},
    kind: Kind = .script,
    source_hash: []const u8 = &.{},
    recipe_hash: []const u8 = &.{},
    plan_schema: []const u8 = &.{},
    plan_hash: []const u8 = &.{},
    artifact_hash: []const u8 = &.{},
    runtime: []const u8 = &.{},
    lua_abi: []const u8 = &.{},
    target: []const u8 = &.{},
    constellation: []const u8 = &.{},
    source: []const u8 = &.{},
    source_kind: []const u8 = &.{},
    source_payload: []const u8 = &.{},
    source_url: []const u8 = &.{},
    rockspec: []const u8 = &.{},
    rockspec_hash: []const u8 = &.{},
    rockspec_payload: []const u8 = &.{},
    resolver: []const u8 = &.{},
    registry: []const u8 = &.{},
    link_mode: []const u8 = &.{},
    reproducible: bool = true,
    roles: []const []const u8 = &.{},
    replay_mode: replay_mod.ReplayMode = .artifact_only,
    replay_contract: ?replay_mod.ReplayContract = null,

    pub fn deinit(self: LockEntry, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.source_hash.len > 0) allocator.free(self.source_hash);
        if (self.recipe_hash.len > 0) allocator.free(self.recipe_hash);
        if (self.plan_schema.len > 0) allocator.free(self.plan_schema);
        if (self.plan_hash.len > 0) allocator.free(self.plan_hash);
        if (self.artifact_hash.len > 0) allocator.free(self.artifact_hash);
        if (self.runtime.len > 0) allocator.free(self.runtime);
        if (self.lua_abi.len > 0) allocator.free(self.lua_abi);
        if (self.target.len > 0) allocator.free(self.target);
        if (self.constellation.len > 0) allocator.free(self.constellation);
        if (self.source.len > 0) allocator.free(self.source);
        if (self.source_kind.len > 0) allocator.free(self.source_kind);
        if (self.source_payload.len > 0) allocator.free(self.source_payload);
        if (self.source_url.len > 0) allocator.free(self.source_url);
        if (self.rockspec.len > 0) allocator.free(self.rockspec);
        if (self.rockspec_hash.len > 0) allocator.free(self.rockspec_hash);
        if (self.rockspec_payload.len > 0) allocator.free(self.rockspec_payload);
        if (self.resolver.len > 0) allocator.free(self.resolver);
        if (self.registry.len > 0) allocator.free(self.registry);
        if (self.link_mode.len > 0) allocator.free(self.link_mode);
        for (self.roles) |g| allocator.free(g);
        if (self.roles.len > 0) allocator.free(self.roles);
        if (self.replay_contract) |rc| {
            var mut_rc = rc;
            mut_rc.deinit(allocator);
        }
    }
};

const res_profile = @import("resolution_profile.zig");

pub const LockFile = struct {
    packages: std.ArrayList(LockEntry) = .empty,
    profiles: std.ArrayList(res_profile.ResolutionProfile) = .empty,
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
        for (self.profiles.items) |p| {
            p.deinit(self.allocator);
        }
        self.profiles.deinit(self.allocator);
    }

    pub fn findProfile(self: *const LockFile, target: []const u8, runtime: []const u8, lua_abi: ?[]const u8) ?*const res_profile.ResolutionProfile {
        for (self.profiles.items) |*prof| {
            if (res_profile.matchesProfile(prof, target, runtime, lua_abi)) {
                return prof;
            }
        }
        return null;
    }

    pub fn serialize(self: LockFile, allocator: std.mem.Allocator, writer: anytype) !void {
        // Manual serialization to avoid comptime branch limit in toml.serialize
        // when the LockEntry struct has many fields.
        _ = allocator;
        try writer.print("lockfile_version = 2\n\n", .{});
        for (self.packages.items, 0..) |entry, i| {
            if (i > 0) try writer.print("\n", .{});
            try writer.print("[[package]]\n", .{});
            try writer.print("name = \"{s}\"\n", .{entry.name});
            try writer.print("version = \"{s}\"\n", .{entry.version});
            try writer.print("kind = \"{s}\"\n", .{@tagName(entry.kind)});
            if (entry.source_hash.len > 0) try writer.print("source_hash = \"{s}\"\n", .{entry.source_hash});
            try writer.print("recipe_hash = \"{s}\"\n", .{entry.recipe_hash});
            if (entry.plan_hash.len > 0) try writer.print("plan_hash = \"{s}\"\n", .{entry.plan_hash});
            try writer.print("artifact_hash = \"{s}\"\n", .{entry.artifact_hash});
            try writer.print("replay_mode = \"{s}\"\n", .{entry.replay_mode.toString()});
            try writer.print("runtime = \"{s}\"\n", .{entry.runtime});
            try writer.print("lua_abi = \"{s}\"\n", .{entry.lua_abi});
            try writer.print("target = \"{s}\"\n", .{entry.target});
            try writer.print("constellation = \"{s}\"\n", .{entry.constellation});
            if (entry.source.len > 0) try writer.print("source = \"{s}\"\n", .{entry.source});
            if (entry.source_kind.len > 0) try writer.print("source_kind = \"{s}\"\n", .{entry.source_kind});
            if (entry.source_payload.len > 0) try writer.print("source_payload = \"{s}\"\n", .{entry.source_payload});
            if (entry.source_url.len > 0) try writer.print("source_url = \"{s}\"\n", .{entry.source_url});
            if (entry.rockspec.len > 0) try writer.print("rockspec = \"{s}\"\n", .{entry.rockspec});
            if (entry.rockspec_hash.len > 0) try writer.print("rockspec_hash = \"{s}\"\n", .{entry.rockspec_hash});
            if (entry.rockspec_payload.len > 0) try writer.print("rockspec_payload = \"{s}\"\n", .{entry.rockspec_payload});
            if (entry.resolver.len > 0) try writer.print("resolver = \"{s}\"\n", .{entry.resolver});
            if (entry.registry.len > 0) try writer.print("registry = \"{s}\"\n", .{entry.registry});
            if (entry.link_mode.len > 0) try writer.print("link_mode = \"{s}\"\n", .{entry.link_mode});
            if (!entry.reproducible) try writer.print("reproducible = false\n", .{});
            if (entry.roles.len > 0) {
                try writer.print("roles = [", .{});
                for (entry.roles, 0..) |role, j| {
                    if (j > 0) try writer.print(", ", .{});
                    try writer.print("\"{s}\"", .{role});
                }
                try writer.print("]\n", .{});
            }
        }
        for (self.profiles.items) |profile| {
            try writer.print("\n[[profile]]\nid = \"{s}\"\ntarget = \"{s}\"\nruntime = \"{s}\"\n", .{ profile.id, profile.target, profile.runtime });
            if (profile.lua_abi) |abi| try writer.print("lua_abi = \"{s}\"\n", .{abi});
            try writer.print("packages = [", .{});
            for (profile.packages, 0..) |package, index| {
                if (index > 0) try writer.print(", ", .{});
                try writer.print("{{ name = \"{s}\", version = \"{s}\", realization_hash = \"{s}\" }}", .{ package.package_name, package.package_version, package.realization_hash });
            }
            try writer.print("]\nedges = [", .{});
            for (profile.edges, 0..) |edge, index| {
                if (index > 0) try writer.print(", ", .{});
                try writer.print("{{ from = \"{s}\", to = \"{s}\", constraint = \"{s}\" }}", .{ edge.from_package, edge.to_package, edge.constraint });
            }
            try writer.print("]\n", .{});
        }
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
            if (v != .array) return error.InvalidLockFile;
            for (v.array.items) |pkg_val| {
                const t = pkg_val.table;

                // Helper to get optional string
                const getStr = struct {
                    fn get(table: *toml.Table, key: []const u8) ?[]const u8 {
                        if (table.get(key)) |val| {
                            if (val == .string) return val.string;
                        }
                        return null;
                    }
                }.get;

                const reproducible = blk: {
                    const rep = t.get("reproducible");
                    if (rep) |r| {
                        if (r == .boolean) break :blk r.boolean;
                    }
                    break :blk true;
                };

                const source_kind = getStr(t, "source_kind") orelse "";
                const parsed_replay_mode = if (getStr(t, "replay_mode")) |mode_str|
                    replay_mod.ReplayMode.fromString(mode_str)
                else if (std.mem.eql(u8, source_kind, "copy_lua") or
                    std.mem.eql(u8, source_kind, "builtin") or
                    std.mem.eql(u8, source_kind, "luarocks_src_rock") or
                    std.mem.eql(u8, source_kind, "upstream_archive") or
                    source_kind.len == 0)
                    replay_mod.ReplayMode.portable_source
                else
                    replay_mod.ReplayMode.artifact_only;

                try lf.packages.append(allocator, .{
                    .name = try allocator.dupe(u8, getStr(t, "name") orelse return error.MissingName),
                    .version = try allocator.dupe(u8, getStr(t, "version") orelse return error.MissingVersion),
                    .kind = try Kind.from_string(getStr(t, "kind") orelse return error.MissingKind),
                    .source_hash = if (getStr(t, "source_hash")) |s| try allocator.dupe(u8, s) else &.{},
                    .recipe_hash = try allocator.dupe(u8, getStr(t, "recipe_hash") orelse return error.MissingRecipeHash),
                    .plan_hash = if (getStr(t, "plan_hash")) |p| try allocator.dupe(u8, p) else &.{},
                    .artifact_hash = try allocator.dupe(u8, getStr(t, "artifact_hash") orelse return error.MissingArtifactHash),
                    .runtime = try allocator.dupe(u8, getStr(t, "runtime") orelse return error.MissingRuntime),
                    .lua_abi = try allocator.dupe(u8, getStr(t, "lua_abi") orelse return error.MissingLuaAbi),
                    .target = try allocator.dupe(u8, getStr(t, "target") orelse return error.MissingTarget),
                    .constellation = if (getStr(t, "constellation")) |c| try allocator.dupe(u8, c) else try allocator.dupe(u8, "default"),
                    .source = if (getStr(t, "source")) |s| try allocator.dupe(u8, s) else &.{},
                    .source_kind = if (getStr(t, "source_kind")) |s| try allocator.dupe(u8, s) else &.{},
                    .source_payload = if (getStr(t, "source_payload")) |s| try allocator.dupe(u8, s) else &.{},
                    .source_url = if (getStr(t, "source_url")) |s| try allocator.dupe(u8, s) else &.{},
                    .rockspec = if (getStr(t, "rockspec")) |s| try allocator.dupe(u8, s) else &.{},
                    .rockspec_hash = if (getStr(t, "rockspec_hash")) |s| try allocator.dupe(u8, s) else &.{},
                    .rockspec_payload = if (getStr(t, "rockspec_payload")) |s| try allocator.dupe(u8, s) else &.{},
                    .resolver = if (getStr(t, "resolver")) |s| try allocator.dupe(u8, s) else &.{},
                    .registry = if (getStr(t, "registry")) |s| try allocator.dupe(u8, s) else &.{},
                    .link_mode = if (getStr(t, "link_mode")) |s| try allocator.dupe(u8, s) else &.{},
                    .reproducible = reproducible,
                    .replay_mode = parsed_replay_mode,
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

        if (root.get("profile")) |value| {
            if (value != .array) return error.InvalidLockFile;
            for (value.array.items) |profile_value| {
                if (profile_value != .table) return error.InvalidLockFile;
                const table = profile_value.table;
                const id = table.get("id") orelse return error.InvalidLockFile;
                const target = table.get("target") orelse return error.InvalidLockFile;
                const runtime = table.get("runtime") orelse return error.InvalidLockFile;
                if (id != .string or target != .string or runtime != .string) return error.InvalidLockFile;
                var packages = std.ArrayList(res_profile.ProfilePackageRef).empty;
                errdefer {
                    for (packages.items) |package| package.deinit(allocator);
                    packages.deinit(allocator);
                }
                if (table.get("packages")) |packages_value| {
                    if (packages_value != .array) return error.InvalidLockFile;
                    for (packages_value.array.items) |package_value| {
                        if (package_value != .table) return error.InvalidLockFile;
                        const package_table = package_value.table;
                        const name = package_table.get("name") orelse return error.InvalidLockFile;
                        const version = package_table.get("version") orelse return error.InvalidLockFile;
                        const hash = package_table.get("realization_hash") orelse return error.InvalidLockFile;
                        if (name != .string or version != .string or hash != .string) return error.InvalidLockFile;
                        try packages.append(allocator, .{ .package_name = try allocator.dupe(u8, name.string), .package_version = try allocator.dupe(u8, version.string), .realization_hash = try allocator.dupe(u8, hash.string) });
                    }
                }
                var edges = std.ArrayList(res_profile.DependencyEdge).empty;
                errdefer {
                    for (edges.items) |edge| edge.deinit(allocator);
                    edges.deinit(allocator);
                }
                if (table.get("edges")) |edges_value| {
                    if (edges_value != .array) return error.InvalidLockFile;
                    for (edges_value.array.items) |edge_value| {
                        if (edge_value != .table) return error.InvalidLockFile;
                        const edge_table = edge_value.table;
                        const from = edge_table.get("from") orelse return error.InvalidLockFile;
                        const to = edge_table.get("to") orelse return error.InvalidLockFile;
                        if (from != .string or to != .string) return error.InvalidLockFile;
                        const constraint = if (edge_table.get("constraint")) |item| item.string else "";
                        try edges.append(allocator, .{ .from_package = try allocator.dupe(u8, from.string), .to_package = try allocator.dupe(u8, to.string), .constraint = if (constraint.len > 0) try allocator.dupe(u8, constraint) else "" });
                    }
                }
                try lf.profiles.append(allocator, .{ .id = try allocator.dupe(u8, id.string), .target = try allocator.dupe(u8, target.string), .runtime = try allocator.dupe(u8, runtime.string), .lua_abi = if (table.get("lua_abi")) |abi| try allocator.dupe(u8, abi.string) else null, .packages = try packages.toOwnedSlice(allocator), .edges = try edges.toOwnedSlice(allocator) });
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

    pub fn findIgnoreCase(self: *const LockFile, name: []const u8) ?*const LockEntry {
        for (self.packages.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
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

test "lockfile findIgnoreCase matches LuaRocks canonical casing" {
    const allocator = std.testing.allocator;
    const content =
        \\[[package]]
        \\name = "LuaSec"
        \\version = "1.3.2-1"
        \\kind = "lib"
        \\source_hash = "b3:src"
        \\recipe_hash = "b3:recipe"
        \\artifact_hash = "b3:artifact"
        \\runtime = "5.4"
        \\lua_abi = "5.4"
        \\target = "native"
        \\constellation = "default"
        \\resolver = "rocks"
        \\
    ;

    var lf = try LockFile.parse(allocator, content);
    defer lf.deinit();

    try std.testing.expect(lf.find("luasec") == null);
    const entry = lf.findIgnoreCase("luasec") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("LuaSec", entry.name);
}

test "lockfile source_url round-trips through serialize and parse" {
    const toml_text =
        \\[[package]]
        \\name = "moonstone/lua"
        \\version = "5.4.7"
        \\kind = "runtime"
        \\source_hash = "b3:srchash"
        \\recipe_hash = "b3:recipehash"
        \\artifact_hash = "b3:artihash"
        \\runtime = "lua54"
        \\lua_abi = "lua54"
        \\target = "native"
        \\constellation = "default"
        \\resolver = "moonstone"
        \\source = "registry"
        \\source_kind = "puc_lua_source"
        \\source_payload = "sources/source.tar.gz"
        \\source_url = "https://registry.moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz"
    ;

    var lf = try LockFile.parse(std.testing.allocator, toml_text);
    defer lf.deinit();

    try std.testing.expectEqual(@as(usize, 1), lf.packages.items.len);
    const entry = lf.packages.items[0];
    try std.testing.expectEqualStrings("puc_lua_source", entry.source_kind);
    try std.testing.expectEqualStrings("sources/source.tar.gz", entry.source_payload);
    try std.testing.expectEqualStrings("https://registry.moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz", entry.source_url);

    // Serialize and re-parse
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try lf.serialize(std.testing.allocator, &aw.writer);
    try aw.writer.flush();
    const serialized = aw.writer.buffer[0..aw.writer.end];

    var lf2 = try LockFile.parse(std.testing.allocator, serialized);
    defer lf2.deinit();

    try std.testing.expectEqual(@as(usize, 1), lf2.packages.items.len);
    const entry2 = lf2.packages.items[0];
    try std.testing.expectEqualStrings("puc_lua_source", entry2.source_kind);
    try std.testing.expectEqualStrings("sources/source.tar.gz", entry2.source_payload);
    try std.testing.expectEqualStrings("https://registry.moonstone.sh/registry/v0/blobs/b3/so/ur/cehash.tar.gz", entry2.source_url);

    // Assert: no absolute filesystem paths in serialized lockfile
    try std.testing.expect(std.mem.indexOf(u8, serialized, "/Users/") == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "/home/") == null);
}
