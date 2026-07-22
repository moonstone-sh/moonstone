const std = @import("std");

pub const ArtifactPublishStatus = enum {
    created,
    already_present,
    unauthorized,
    forbidden,
    quota_exceeded,
    conflict,
    unavailable,
};

pub const ArtifactPublishRequest = struct {
    artifact_hash: []const u8,
    artifact_schema: []const u8 = "moonstone:artifact-tree:v1",
    target: []const u8,
    transport_schema: []const u8 = "moonstone:artifact-transport:v1",
    transport_path: []const u8,
    compressed_size: u64 = 0,
    uncompressed_size: u64 = 0,
};

pub const ArtifactPublishResult = struct {
    status: ArtifactPublishStatus,
    artifact_hash: []const u8,
    target: []const u8,
    reused_existing: bool = false,

    pub fn deinit(self: *ArtifactPublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_hash);
        allocator.free(self.target);
    }
};

pub const RemoteArtifactPublisher = struct {
    name: []const u8 = "default",
    registry_url: []const u8 = "",
    auth_token: ?[]const u8 = null,

    pub fn init(name: []const u8, registry_url: []const u8) RemoteArtifactPublisher {
        return .{
            .name = name,
            .registry_url = registry_url,
        };
    }

    pub fn publishArtifact(
        self: RemoteArtifactPublisher,
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *std.process.Environ.Map,
        req: ArtifactPublishRequest,
    ) !ArtifactPublishResult {
        _ = io;
        _ = env;
        if (self.registry_url.len == 0) {
            return ArtifactPublishResult{
                .status = .unavailable,
                .artifact_hash = try allocator.dupe(u8, req.artifact_hash),
                .target = try allocator.dupe(u8, req.target),
            };
        }

        return ArtifactPublishResult{
            .status = .created,
            .artifact_hash = try allocator.dupe(u8, req.artifact_hash),
            .target = try allocator.dupe(u8, req.target),
            .reused_existing = false,
        };
    }
};
