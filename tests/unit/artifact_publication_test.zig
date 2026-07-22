const std = @import("std");
const moonstone = @import("moonstone");
const provider_mod = moonstone.artifacts.provider;
const publisher_mod = moonstone.artifacts.publisher;
const transport_mod = moonstone.artifacts.transport;

test "ArtifactRequest requires explicit concrete target" {
    const req = provider_mod.ArtifactRequest{
        .artifact_hash = "b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb",
        .target = "aarch64-macos",
    };

    try std.testing.expectEqualStrings("aarch64-macos", req.target);
    try std.testing.expect(!std.mem.eql(u8, req.target, "native"));
}

test "RemoteArtifactPublisher publishArtifact returns created" {
    const allocator = std.testing.allocator;
    const io_val: std.Io = undefined;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const publisher = publisher_mod.RemoteArtifactPublisher.init("registry", "https://registry.moonstone.sh");
    const req = publisher_mod.ArtifactPublishRequest{
        .artifact_hash = "b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb",
        .target = "aarch64-macos",
        .transport_path = "/tmp/dummy_transport.tar.gz",
    };

    var res = try publisher.publishArtifact(allocator, io_val, &env_map, req);
    defer res.deinit(allocator);

    try std.testing.expectEqual(publisher_mod.ArtifactPublishStatus.created, res.status);
    try std.testing.expectEqualStrings("aarch64-macos", res.target);
}
