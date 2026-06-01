const std = @import("std");
const package_spec = @import("../domain/package_spec.zig");

pub const ResolveRequest = struct {
    targets: []const package_spec.PackageSpec,

    pub fn deinit(self: ResolveRequest, allocator: std.mem.Allocator) void {
        for (self.targets) |t| t.deinit(allocator);
        allocator.free(self.targets);
    }
};
