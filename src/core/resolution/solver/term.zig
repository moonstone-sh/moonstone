const std = @import("std");
const semver = @import("../../domain/semver.zig");
const root = @import("../root.zig");

/// A term is a package name and a version range.
pub const Term = struct {
    name: []const u8,
    range: semver.VersionRange,
    registry: ?[]const u8 = null,
    resolver: ?root.ResolverKind = null,

    pub fn deinit(self: Term, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.registry) |r| allocator.free(r);
        self.range.deinit(allocator);
    }

    pub fn clone(self: Term, allocator: std.mem.Allocator) !Term {
        return Term{
            .name = try allocator.dupe(u8, self.name),
            .range = try self.range.clone(allocator),
            .registry = if (self.registry) |r| try allocator.dupe(u8, r) else null,
            .resolver = self.resolver,
        };
    }
};
