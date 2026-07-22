const std = @import("std");

pub const ProfilePackageRef = struct {
    package_name: []const u8,
    package_version: []const u8,
    realization_hash: []const u8,

    pub fn deinit(self: ProfilePackageRef, allocator: std.mem.Allocator) void {
        allocator.free(self.package_name);
        allocator.free(self.package_version);
        allocator.free(self.realization_hash);
    }

    pub fn clone(self: ProfilePackageRef, allocator: std.mem.Allocator) !ProfilePackageRef {
        return ProfilePackageRef{
            .package_name = try allocator.dupe(u8, self.package_name),
            .package_version = try allocator.dupe(u8, self.package_version),
            .realization_hash = try allocator.dupe(u8, self.realization_hash),
        };
    }
};

pub const DependencyEdge = struct {
    from_package: []const u8,
    to_package: []const u8,
    constraint: []const u8 = "",

    pub fn deinit(self: DependencyEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.from_package);
        allocator.free(self.to_package);
        if (self.constraint.len > 0) allocator.free(self.constraint);
    }

    pub fn clone(self: DependencyEdge, allocator: std.mem.Allocator) !DependencyEdge {
        return DependencyEdge{
            .from_package = try allocator.dupe(u8, self.from_package),
            .to_package = try allocator.dupe(u8, self.to_package),
            .constraint = if (self.constraint.len > 0) try allocator.dupe(u8, self.constraint) else "",
        };
    }
};

pub const ResolutionProfile = struct {
    id: []const u8,
    target: []const u8,
    runtime: []const u8,
    lua_abi: ?[]const u8 = null,

    packages: []ProfilePackageRef = &.{},
    edges: []DependencyEdge = &.{},

    pub fn deinit(self: ResolutionProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.target);
        allocator.free(self.runtime);
        if (self.lua_abi) |abi| allocator.free(abi);
        for (self.packages) |p| p.deinit(allocator);
        if (self.packages.len > 0) allocator.free(self.packages);
        for (self.edges) |e| e.deinit(allocator);
        if (self.edges.len > 0) allocator.free(self.edges);
    }

    pub fn clone(self: ResolutionProfile, allocator: std.mem.Allocator) !ResolutionProfile {
        var new_pkgs = try allocator.alloc(ProfilePackageRef, self.packages.len);
        for (self.packages, 0..) |p, i| new_pkgs[i] = try p.clone(allocator);

        var new_edges = try allocator.alloc(DependencyEdge, self.edges.len);
        for (self.edges, 0..) |e, i| new_edges[i] = try e.clone(allocator);

        return ResolutionProfile{
            .id = try allocator.dupe(u8, self.id),
            .target = try allocator.dupe(u8, self.target),
            .runtime = try allocator.dupe(u8, self.runtime),
            .lua_abi = if (self.lua_abi) |abi| try allocator.dupe(u8, abi) else null,
            .packages = new_pkgs,
            .edges = new_edges,
        };
    }
};

pub const RuntimeIdentity = struct {
    implementation: []const u8 = "lua",
    version: []const u8 = "5.4",
    artifact_hash: []const u8 = "",

    pub fn deinit(self: RuntimeIdentity, allocator: std.mem.Allocator) void {
        if (self.implementation.len > 0) allocator.free(self.implementation);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.artifact_hash.len > 0) allocator.free(self.artifact_hash);
    }

    pub fn clone(self: RuntimeIdentity, allocator: std.mem.Allocator) !RuntimeIdentity {
        return RuntimeIdentity{
            .implementation = try allocator.dupe(u8, self.implementation),
            .version = try allocator.dupe(u8, self.version),
            .artifact_hash = try allocator.dupe(u8, self.artifact_hash),
        };
    }
};

pub const ProfileIdentity = struct {
    target: []const u8,
    runtime: RuntimeIdentity = .{},
    lua_abi: ?[]const u8 = null,

    pub fn deinit(self: ProfileIdentity, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        self.runtime.deinit(allocator);
        if (self.lua_abi) |abi| allocator.free(abi);
    }

    pub fn clone(self: ProfileIdentity, allocator: std.mem.Allocator) !ProfileIdentity {
        return ProfileIdentity{
            .target = try allocator.dupe(u8, self.target),
            .runtime = try self.runtime.clone(allocator),
            .lua_abi = if (self.lua_abi) |abi| try allocator.dupe(u8, abi) else null,
        };
    }
};

pub fn generateProfileId(allocator: std.mem.Allocator, target: []const u8, runtime: []const u8, lua_abi: ?[]const u8) ![]const u8 {
    const abi_str = lua_abi orelse "5.4";
    return try std.fmt.allocPrint(allocator, "{s}+{s}+{s}", .{ target, runtime, abi_str });
}

pub fn matchesProfile(profile: *const ResolutionProfile, active_target: []const u8, active_runtime: []const u8, active_lua_abi: ?[]const u8) bool {
    const target_match = std.mem.eql(u8, profile.target, active_target) or std.mem.eql(u8, profile.target, "native");
    const runtime_match = std.mem.eql(u8, profile.runtime, active_runtime) or std.mem.indexOf(u8, profile.runtime, active_runtime) != null;
    const abi_match = if (profile.lua_abi) |p_abi| (if (active_lua_abi) |a_abi| std.mem.eql(u8, p_abi, a_abi) else true) else true;
    return target_match and runtime_match and abi_match;
}

pub fn matchesProfileStructured(profile: *const ResolutionProfile, identity: ProfileIdentity) bool {
    const target_match = std.mem.eql(u8, profile.target, identity.target) or std.mem.eql(u8, profile.target, "native");
    const runtime_version_match = std.mem.indexOf(u8, profile.runtime, identity.runtime.version) != null or std.mem.eql(u8, profile.runtime, identity.runtime.version);
    const abi_match = if (profile.lua_abi) |p_abi| (if (identity.lua_abi) |i_abi| std.mem.eql(u8, p_abi, i_abi) else true) else true;
    return target_match and runtime_version_match and abi_match;
}

pub fn selectProfile(profiles: []const ResolutionProfile, active_target: []const u8, active_runtime: []const u8, active_lua_abi: ?[]const u8) ?*const ResolutionProfile {
    for (profiles) |*prof| {
        if (matchesProfile(prof, active_target, active_runtime, active_lua_abi)) {
            return prof;
        }
    }
    return null;
}

pub fn verifyProfilesUnchanged(before: []const ResolutionProfile, after: []const ResolutionProfile) !void {
    if (after.len < before.len) return error.ExistingProfileMutationDetected;
    for (before, 0..) |p_before, i| {
        const p_after = after[i];
        if (!std.mem.eql(u8, p_before.id, p_after.id)) return error.ExistingProfileMutationDetected;
        if (!std.mem.eql(u8, p_before.target, p_after.target)) return error.ExistingProfileMutationDetected;
        if (p_before.packages.len != p_after.packages.len) return error.ExistingProfileMutationDetected;
        for (p_before.packages, 0..) |pkg_b, j| {
            const pkg_a = p_after.packages[j];
            if (!std.mem.eql(u8, pkg_b.package_name, pkg_a.package_name) or
                !std.mem.eql(u8, pkg_b.package_version, pkg_a.package_version) or
                !std.mem.eql(u8, pkg_b.realization_hash, pkg_a.realization_hash))
            {
                return error.ExistingProfileMutationDetected;
            }
        }
    }
}
