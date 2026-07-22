const std = @import("std");

pub const RetentionKind = enum {
    published_package_version,
    active_release,
    private_project_lock,
    manual_pin,
    retention_lease,
};

pub const RetentionRoot = struct {
    kind: RetentionKind,
    id: []const u8,

    pub fn deinit(self: RetentionRoot, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

pub const ArtifactAssociation = struct {
    artifact_hash: []const u8,
    package_name: []const u8,
    package_version: []const u8,
    target: []const u8,
    publisher_id: []const u8,

    pub fn deinit(self: ArtifactAssociation, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_hash);
        allocator.free(self.package_name);
        allocator.free(self.package_version);
        allocator.free(self.target);
        allocator.free(self.publisher_id);
    }
};

pub fn isArtifactQuarantined(quarantined_hashes: []const []const u8, target_hash: []const u8) bool {
    for (quarantined_hashes) |q_hash| {
        if (std.mem.eql(u8, q_hash, target_hash)) return true;
    }
    return false;
}

pub fn isArtifactRetained(roots: []const RetentionRoot, target_hash: []const u8) bool {
    for (roots) |r| {
        if (std.mem.indexOf(u8, r.id, target_hash) != null or std.mem.eql(u8, r.id, target_hash)) return true;
    }
    return false;
}

pub fn shouldServeArtifact(roots: []const RetentionRoot, quarantined_hashes: []const []const u8, target_hash: []const u8) bool {
    if (isArtifactQuarantined(quarantined_hashes, target_hash)) return false;
    return isArtifactRetained(roots, target_hash);
}
