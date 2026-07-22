const std = @import("std");
const moonstone = @import("moonstone");
const locked_pkg = moonstone.domain.locked_package;
const retention_mod = moonstone.artifacts.retention;

test "RealizationAssurance classification" {
    const lua_realization = locked_pkg.TargetRealization{
        .target = "native",
        .assurance = .portable_source,
    };
    try std.testing.expectEqual(locked_pkg.RealizationAssurance.portable_source, lua_realization.assurance);

    const zig_realization = locked_pkg.TargetRealization{
        .target = "aarch64-macos",
        .assurance = .declared_host,
    };
    try std.testing.expectEqual(locked_pkg.RealizationAssurance.declared_host, zig_realization.assurance);
}

test "Registry retention roots and quarantine enforcement" {
    const root1 = retention_mod.RetentionRoot{
        .kind = .published_package_version,
        .id = "b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb",
    };
    const roots = [_]retention_mod.RetentionRoot{root1};

    // 1. Retained artifact survives GC check
    try std.testing.expect(retention_mod.isArtifactRetained(&roots, "b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb"));

    // 2. Unrooted artifact is not retained
    try std.testing.expect(!retention_mod.isArtifactRetained(&roots, "b3:unrooted_hash"));

    // 3. Quarantined artifact is not served even if retained
    const quarantined = [_][]const u8{"b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb"};
    try std.testing.expect(!retention_mod.shouldServeArtifact(&roots, &quarantined, "b3:5ac9feaa83ddf51cad9d0f25e20bbf37aede1dd2f5679e5d6f735c62819444bb"));
}
