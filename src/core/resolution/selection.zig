const std = @import("std");
const semver = @import("../domain/semver.zig");

pub const PackageSelection = struct {
    name: []const u8,
    version: semver.Version,
    source_id: []const u8,

    pub fn deinit(self: PackageSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source_id);
    }
};
