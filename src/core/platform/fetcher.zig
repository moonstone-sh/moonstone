const std = @import("std");

pub const Fetcher = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Fetcher {
        return .{ .allocator = allocator };
    }

    pub fn fetch(self: Fetcher, url: []const u8) ![]const u8 {
        _ = self;
        _ = url;
        // TODO: Implement HTTP/Local fetching
        return error.NotImplemented;
    }
};
