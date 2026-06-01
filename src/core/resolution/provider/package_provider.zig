const std = @import("std");
const semver = @import("../../domain/semver.zig");
const manifest = @import("../../domain/manifest.zig");
const root = @import("../root.zig");
const term_mod = @import("../solver/term.zig");

/// Request for artifact retrieval. resolver and artifact_hash allow
/// lockfile-driven exact lookups; when absent the provider falls back
/// to name/version/resolver matching.
pub const ArtifactRequest = struct {
    name: []const u8,
    version: []const u8,
    resolver: ?root.ResolverKind = null,
    artifact_hash: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    lua_abi: ?[]const u8 = null,
    runtime_artifact_hash: ?[]const u8 = null,
};

/// Abstract interface for fetching package metadata.
/// This allows the solver to query registries, luarocks, and local paths uniformly.
pub const PackageProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getVersions: *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const semver.Version,
        getDependencies: *const fn (ctx: *anyopaque, name: []const u8, version: semver.Version) anyerror![]const term_mod.Term,
        getArtifact: *const fn (ctx: *anyopaque, request: ArtifactRequest) anyerror!?root.ResolveResult,
    };

    pub fn getVersions(self: PackageProvider, name: []const u8) ![]const semver.Version {
        return self.vtable.getVersions(self.ptr, name);
    }

    pub fn getDependencies(self: PackageProvider, name: []const u8, version: semver.Version) ![]const term_mod.Term {
        return self.vtable.getDependencies(self.ptr, name, version);
    }

    pub fn getArtifact(self: PackageProvider, request: ArtifactRequest) !?root.ResolveResult {
        return self.vtable.getArtifact(self.ptr, request);
    }
};
