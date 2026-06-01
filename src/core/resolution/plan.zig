const std = @import("std");
const manifest = @import("../domain/manifest.zig");

pub const ArtifactPackage = struct {
    artifact_hash: []const u8,
    name: []const u8,
    version: []const u8,
    lua_version: []const u8,           // e.g. lua@5.4.7
    lua_abi: []const u8,               // e.g. lua-5.4
    runtime_artifact_hash: []const u8, // exact binary identity
};

pub const SourcePackage = struct {
    name: []const u8,
    version: []const u8,
    lua_version: []const u8,           // e.g. lua@5.4.7
    lua_abi: []const u8,               // e.g. lua-5.4
    runtime_artifact_hash: []const u8, // exact binary identity
    recipe_hash: []const u8,
};


pub const PathPackage = struct {
    name: []const u8,
    path: []const u8,
};

pub const LinkPackage = struct {
    name: []const u8,
    path: []const u8,
};

pub const ResolvedPackage = union(enum) {
    artifact: ArtifactPackage,
    source: SourcePackage,
    path: PathPackage,
    link: LinkPackage,

    pub fn deinit(self: ResolvedPackage, allocator: std.mem.Allocator) void {
        switch (self) {
            .artifact => |a| {
                allocator.free(a.artifact_hash);
                allocator.free(a.name);
                allocator.free(a.version);
                allocator.free(a.lua_version);
                allocator.free(a.lua_abi);
                allocator.free(a.runtime_artifact_hash);
            },
            .source => |s| {
                allocator.free(s.name);
                allocator.free(s.version);
                allocator.free(s.lua_version);
                allocator.free(s.lua_abi);
                allocator.free(s.runtime_artifact_hash);
                allocator.free(s.recipe_hash);
            },

            .path => |p| {
                allocator.free(p.name);
                allocator.free(p.path);
            },
            .link => |l| {
                allocator.free(l.name);
                allocator.free(l.path);
            },
        }
    }
};

pub const ResolutionPlan = struct {
    packages: []ResolvedPackage,

    pub fn deinit(self: ResolutionPlan, allocator: std.mem.Allocator) void {
        for (self.packages) |pkg| {
            pkg.deinit(allocator);
        }
        allocator.free(self.packages);
    }
};
