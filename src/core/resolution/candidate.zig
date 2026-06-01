const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const root = @import("root.zig");

pub const Origin = union(enum) {
    moonstone_registry: struct {
        url: []const u8,
        token: ?[]const u8,
        descriptor_path: []const u8,
        artifact_idx: usize,
    },
    luarocks: struct {
        url: []const u8,
        rockspec_path: []const u8,
    },
    path: []const u8,
    link: []const u8,
    artifact_hash: []const u8,

    pub fn deinit(self: Origin, allocator: std.mem.Allocator) void {
        switch (self) {
            .moonstone_registry => |r| {
                allocator.free(r.url);
                if (r.token) |t| allocator.free(t);
                allocator.free(r.descriptor_path);
            },
            .luarocks => |r| {
                allocator.free(r.url);
                allocator.free(r.rockspec_path);
            },
            .path => |p| allocator.free(p),
            .link => |l| allocator.free(l),
            .artifact_hash => |h| allocator.free(h),
        }
    }

    pub fn clone(self: Origin, allocator: std.mem.Allocator) !Origin {
        return switch (self) {
            .moonstone_registry => |r| .{
                .moonstone_registry = .{
                    .url = try allocator.dupe(u8, r.url),
                    .token = if (r.token) |t| try allocator.dupe(u8, t) else null,
                    .descriptor_path = try allocator.dupe(u8, r.descriptor_path),
                    .artifact_idx = r.artifact_idx,
                },
            },
            .luarocks => |r| .{
                .luarocks = .{
                    .url = try allocator.dupe(u8, r.url),
                    .rockspec_path = try allocator.dupe(u8, r.rockspec_path),
                },
            },
            .path => |p| .{ .path = try allocator.dupe(u8, p) },
            .link => |l| .{ .link = try allocator.dupe(u8, l) },
            .artifact_hash => |h| .{ .artifact_hash = try allocator.dupe(u8, h) },
        };
    }
};

pub const Location = union(enum) {
    local_store,
    remote,
    local_path: []const u8,

    pub fn deinit(self: Location, allocator: std.mem.Allocator) void {
        switch (self) {
            .local_path => |p| allocator.free(p),
            else => {},
        }
    }

    pub fn clone(self: Location, allocator: std.mem.Allocator) !Location {
        return switch (self) {
            .local_store => .local_store,
            .remote => .remote,
            .local_path => |p| .{ .local_path = try allocator.dupe(u8, p) },
        };
    }
};

pub const Candidate = struct {
    name: []const u8,
    version: []const u8,
    kind: manifest.Kind,
    origin: Origin,
    location: Location = .remote,

    // Legacy support fields (will be removed as pipeline matures)
    artifact_hash: []const u8 = "",
    lua_version: ?[]const u8 = null,    // e.g. lua@5.4.7
    lua_abi: ?[]const u8 = null,        // e.g. lua-5.4
    runtime_artifact_hash: []const u8 = "", // exact binary identity
    local_path: ?[]const u8 = null,
    remote_desc: ?manifest.RemotePackageDescriptor = null,
    registry_name: ?[]const u8 = null,
    registry_url: ?[]const u8 = null,
    registry_token: ?[]const u8 = null,
    descriptor_path: ?[]const u8 = null,
    artifact_idx: ?usize = null,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.artifact_hash);
        if (self.lua_version) |v| allocator.free(v);
        if (self.lua_abi) |a| allocator.free(a);
        allocator.free(self.runtime_artifact_hash);
        if (self.local_path) |p| allocator.free(p);
        if (self.remote_desc) |d| {
            var mut_d = d;
            mut_d.deinit(allocator);
        }
        if (self.registry_name) |n| allocator.free(n);
        if (self.registry_url) |u| allocator.free(u);
        if (self.registry_token) |t| allocator.free(t);
        if (self.descriptor_path) |p| allocator.free(p);
        self.origin.deinit(allocator);
        self.location.deinit(allocator);
    }

    pub fn clone(self: Candidate, allocator: std.mem.Allocator) !Candidate {
        return Candidate{
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, self.version),
            .kind = self.kind,
            .origin = try self.origin.clone(allocator),
            .location = try self.location.clone(allocator),
            .artifact_hash = try allocator.dupe(u8, self.artifact_hash),
            .lua_version = if (self.lua_version) |v| try allocator.dupe(u8, v) else null,
            .lua_abi = if (self.lua_abi) |a| try allocator.dupe(u8, a) else null,
            .runtime_artifact_hash = try allocator.dupe(u8, self.runtime_artifact_hash),
            .local_path = if (self.local_path) |p| try allocator.dupe(u8, p) else null,
            .remote_desc = if (self.remote_desc) |d| try d.clone(allocator) else null,
            .registry_name = if (self.registry_name) |n| try allocator.dupe(u8, n) else null,
            .registry_url = if (self.registry_url) |u| try allocator.dupe(u8, u) else null,
            .registry_token = if (self.registry_token) |t| try allocator.dupe(u8, t) else null,
            .descriptor_path = if (self.descriptor_path) |p| try allocator.dupe(u8, p) else null,
            .artifact_idx = self.artifact_idx,
        };
    }
};


// Compatibility shim
pub const ResolvedArtifact = Candidate;

pub const RemoteResolveResult = struct {
    desc: manifest.RemotePackageDescriptor,
    artifact_idx: usize,
    descriptor_path: []const u8,
};
