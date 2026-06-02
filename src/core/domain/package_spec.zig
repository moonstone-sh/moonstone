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

    // 1. Check for resolver prefix
    if (std.mem.indexOfScalar(u8, current, ':')) |colon_idx| {
        const prefix = current[0..colon_idx];
        if (root.ResolverKind.fromString(prefix)) |kind| {
            result.resolver = kind;
            current = current[colon_idx + 1 ..];
        } else |_| {
            result.registry = try allocator.dupe(u8, prefix);
            current = current[colon_idx + 1 ..];
        }
    }

    // 2. Check for @ constraint
    if (std.mem.lastIndexOfScalar(u8, current, '@')) |at_idx| {
        const is_scoped_name = std.mem.startsWith(u8, current, "@") and std.mem.indexOfScalar(u8, current, '/') != null;
        const has_url_scheme = std.mem.indexOf(u8, current[0..at_idx], "://") != null;
        if (!has_url_scheme and (!is_scoped_name or at_idx > std.mem.indexOfScalar(u8, current, '/').?)) {
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
    if (std.mem.eql(u8, name, "lua")) return "@moonstone/lua";
    if (std.mem.eql(u8, name, "luajit")) return "@moonstone/luajit";
    if (std.mem.eql(u8, name, "love")) return "@moonstone/love";
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
