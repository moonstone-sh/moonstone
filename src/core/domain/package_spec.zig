const std = @import("std");
const root = @import("../resolution/root.zig");

pub const PackageSpec = struct {
    raw: []const u8,
    resolver: ?root.ResolverKind,
    registry: ?[]const u8,
    name: []const u8,
    constraint: ?[]const u8,

    pub fn deinit(self: PackageSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.constraint) |c| allocator.free(c);
        if (self.registry) |r| allocator.free(r);
    }
};

pub fn parsePackageSpec(allocator: std.mem.Allocator, raw: []const u8) !PackageSpec {
    var result = PackageSpec{
        .raw = raw,
        .resolver = null,
        .registry = null,
        .name = undefined,
        .constraint = null,
    };

    var current = raw;

    // 1. Check for resolver/registry prefix (colon notation)
    if (std.mem.indexOfScalar(u8, current, ':')) |colon_idx| {
        const prefix = current[0..colon_idx];
        if (root.ResolverKind.fromString(prefix)) |kind| {
            result.resolver = kind;
            current = current[colon_idx + 1 ..];
        } else |_| {
            // Check if it's a reserved keyword we don't know about yet but shouldn't use as registry name
            const reserved = &[_][]const u8{ "moonstone", "rocks", "links", "path", "artifact", "git", "http", "https" };
            var is_reserved = false;
            for (reserved) |res| {
                if (std.mem.eql(u8, prefix, res)) {
                    is_reserved = true;
                    break;
                }
            }
            // If it matches a known reserved resolver or common protocol, treat it as a registry reference
            result.registry = try allocator.dupe(u8, prefix);
            current = current[colon_idx + 1 ..];
        }
    }

    // 2. Check for @ constraint (at the end)
    if (std.mem.lastIndexOfScalar(u8, current, '@')) |at_idx| {
        const has_url_scheme = std.mem.indexOf(u8, current[0..at_idx], "://") != null;
        if (!has_url_scheme) {
             result.constraint = try allocator.dupe(u8, current[at_idx + 1 ..]);
             current = current[0..at_idx];
        }
    }

    const name = try allocator.dupe(u8, current);
    if (result.resolver == .rocks) {
        for (name) |*char| char.* = std.ascii.toLower(char.*);
    }
    result.name = name;
    return result;
}

pub fn canonicalOfficialRuntime(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "lua")) return "moonstone/lua";
    if (std.mem.eql(u8, name, "luajit")) return "moonstone/luajit";
    if (std.mem.eql(u8, name, "love")) return "moonstone/love";
    return name;
}

test "parsePackageSpec normalizes explicit LuaRocks names" {
    const allocator = std.testing.allocator;
    const spec = try parsePackageSpec(allocator, "rocks:LuaSocket@^3.1.0-1");
    defer spec.deinit(allocator);

    try std.testing.expectEqual(root.ResolverKind.rocks, spec.resolver.?);
    try std.testing.expectEqualStrings("luasocket", spec.name);
    try std.testing.expectEqualStrings("^3.1.0-1", spec.constraint.?);
}
