const std = @import("std");

pub const PathKind = enum {
    include,
    library,
};

/// A host-provided path required while materializing a package.
///
/// The package descriptor or source adapter declares the variable; the
/// scheduler resolves it only after the final build environment exists.
pub const PathRequirement = struct {
    dependency: []const u8,
    variable: []const u8,
    kind: PathKind,

    pub fn clone(self: PathRequirement, allocator: std.mem.Allocator) !PathRequirement {
        return .{
            .dependency = try allocator.dupe(u8, self.dependency),
            .variable = try allocator.dupe(u8, self.variable),
            .kind = self.kind,
        };
    }

    pub fn deinit(self: PathRequirement, allocator: std.mem.Allocator) void {
        allocator.free(self.dependency);
        allocator.free(self.variable);
    }
};

pub const Requirement = PathRequirement;

pub fn deinitRequirements(allocator: std.mem.Allocator, requirements: []const PathRequirement) void {
    for (requirements) |requirement| requirement.deinit(allocator);
    allocator.free(requirements);
}

pub fn collectMissing(
    allocator: std.mem.Allocator,
    requirements: []const PathRequirement,
    env: *const std.process.Environ.Map,
) ![]const PathRequirement {
    var missing = std.ArrayList(PathRequirement).empty;
    errdefer missing.deinit(allocator);
    for (requirements) |requirement| {
        const value = env.get(requirement.variable);
        if (value == null or value.?.len == 0) try missing.append(allocator, requirement);
    }
    return missing.toOwnedSlice(allocator);
}

pub const MissingPaths = struct {
    package: []const u8,
    version: []const u8,
    requirements: []const PathRequirement,

    pub fn init(
        allocator: std.mem.Allocator,
        package: []const u8,
        version: []const u8,
        requirements: []const PathRequirement,
    ) !MissingPaths {
        const owned = try allocator.alloc(PathRequirement, requirements.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |requirement| requirement.deinit(allocator);
            allocator.free(owned);
        }
        for (requirements, 0..) |requirement, index| {
            owned[index] = try requirement.clone(allocator);
            initialized += 1;
        }
        const owned_package = try allocator.dupe(u8, package);
        errdefer allocator.free(owned_package);
        const owned_version = try allocator.dupe(u8, version);
        return .{ .package = owned_package, .version = owned_version, .requirements = owned };
    }

    pub fn deinit(self: MissingPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.package);
        allocator.free(self.version);
        deinitRequirements(allocator, self.requirements);
    }
};

test "missing external path diagnostics own independent requirement data" {
    const allocator = std.testing.allocator;
    const requirement = PathRequirement{ .dependency = "FROB", .variable = "FROB_INCDIR", .kind = .include };
    const first = try MissingPaths.init(allocator, "package-a", "1.0.0", &.{requirement});
    defer first.deinit(allocator);
    const second = try MissingPaths.init(allocator, "package-b", "2.0.0", &.{requirement});
    defer second.deinit(allocator);

    try std.testing.expectEqualStrings("package-a", first.package);
    try std.testing.expectEqualStrings("package-b", second.package);
    try std.testing.expect(first.package.ptr != second.package.ptr);
    try std.testing.expect(first.requirements[0].variable.ptr != second.requirements[0].variable.ptr);
}

test "collect missing treats absent and empty values as unresolved" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("EMPTY_LIBDIR", "");
    try env.put("READY_INCDIR", "/sdk/include");

    const requirements = [_]PathRequirement{
        .{ .dependency = "ABSENT", .variable = "ABSENT_INCDIR", .kind = .include },
        .{ .dependency = "EMPTY", .variable = "EMPTY_LIBDIR", .kind = .library },
        .{ .dependency = "READY", .variable = "READY_INCDIR", .kind = .include },
    };
    const missing = try collectMissing(allocator, &requirements, &env);
    defer allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 2), missing.len);
    try std.testing.expectEqualStrings("ABSENT_INCDIR", missing[0].variable);
    try std.testing.expectEqualStrings("EMPTY_LIBDIR", missing[1].variable);
}
