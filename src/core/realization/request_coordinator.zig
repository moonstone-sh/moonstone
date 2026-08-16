const std = @import("std");

/// Coordinates identical, coalescible realization requests within one command
/// invocation. The caller owns the work queue and result storage; this type
/// only assigns one deterministic leader for a canonical request identity.
///
/// Cross-process exclusion remains the store/materializer's responsibility.
/// For LuaRocks source materialization, the identity is the prepared recipe
/// hash, which already includes the source, target, runtime, and recipe facts.
pub const RequestCoordinator = struct {
    allocator: std.mem.Allocator,
    leaders: std.StringHashMapUnmanaged(usize) = .empty,

    pub const Claim = union(enum) {
        leader,
        follower: usize,
    };

    pub fn init(allocator: std.mem.Allocator) RequestCoordinator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RequestCoordinator) void {
        var iterator = self.leaders.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.leaders.deinit(self.allocator);
        self.* = undefined;
    }

    /// Claims one canonical request. The first job becomes its leader; later
    /// callers receive the leader job index and must consume that outcome.
    pub fn claim(self: *RequestCoordinator, key: []const u8, job_index: usize) !Claim {
        if (self.leaders.get(key)) |leader| return .{ .follower = leader };

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.leaders.put(self.allocator, owned_key, job_index);
        return .leader;
    }
};

test "request coordinator assigns one leader per canonical identity" {
    var coordinator = RequestCoordinator.init(std.testing.allocator);
    defer coordinator.deinit();

    try std.testing.expectEqual(RequestCoordinator.Claim.leader, try coordinator.claim("b3:recipe-a", 2));
    try std.testing.expectEqual(RequestCoordinator.Claim{ .follower = 2 }, try coordinator.claim("b3:recipe-a", 7));
    try std.testing.expectEqual(RequestCoordinator.Claim.leader, try coordinator.claim("b3:recipe-b", 7));
}
