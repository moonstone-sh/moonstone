const std = @import("std");
const moonstone = @import("moonstone");
const provider_mod = moonstone.artifacts.provider;

test "RemoteArtifactProvider requests keyed by exact artifact_hash" {
    const prov = provider_mod.RemoteArtifactProvider.init("moonstone-registry", "https://registry.moonstone.sh");
    try std.testing.expectEqualStrings("moonstone-registry", prov.name);

    const req = provider_mod.ArtifactRequest{
        .artifact_hash = "b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb",
        .target = "aarch64-macos",
    };

    try std.testing.expectEqualStrings("b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb", req.artifact_hash);
    try std.testing.expectEqualStrings("aarch64-macos", req.target);
}

test "RemoteArtifactProvider returns not_found when url empty or path missing" {
    const allocator = std.testing.allocator;
    const io_val: std.Io = undefined;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const prov = provider_mod.RemoteArtifactProvider.init("test", "");
    const req = provider_mod.ArtifactRequest{
        .artifact_hash = "b3:nonexistent",
        .target = "native",
    };

    var res = try prov.fetchArtifact(allocator, io_val, &env_map, req, "/tmp/nonexistent_staging");
    defer res.deinit(allocator);

    try std.testing.expectEqual(provider_mod.ArtifactFetchStatus.not_found, res.status);
}
