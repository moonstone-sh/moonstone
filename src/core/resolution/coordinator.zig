const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const registry = @import("../registry/registry.zig");
const driver_mod = @import("../store/driver.zig");
const semver = @import("../domain/semver.zig");
const fs = @import("../platform/fs.zig");

const root = @import("root.zig");
const options_mod = @import("options.zig");
const candidate_mod = @import("candidate.zig");
const request_mod = @import("request.zig");

const moonstone_resolver = @import("sources/moonstone_registry.zig");
const rocks_resolver = @import("sources/luarocks.zig");
const path_resolver = @import("sources/path.zig");
const link_resolver = @import("sources/link.zig");
const artifact_resolver = @import("sources/artifact_hash.zig");

pub const CoordinatorKind = enum {
    moonstone,
    rocks,
    path,
    link,
    artifact,

    pub fn fromString(s: []const u8) !CoordinatorKind {
        if (std.mem.eql(u8, s, "moonstone")) return .moonstone;
        if (std.mem.eql(u8, s, "rocks")) return .rocks;
        if (std.mem.eql(u8, s, "path")) return .path;
        if (std.mem.eql(u8, s, "link")) return .link;
        if (std.mem.eql(u8, s, "artifact")) return .artifact;
        return error.UnknownResolverKind;
    }

    pub fn asString(self: CoordinatorKind) []const u8 {
        return @tagName(self);
    }
};

pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Coordinator {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn resolve(
        self: Coordinator,
        pkg_name: []const u8,
        constraint: []const u8,
        index: driver_mod.StoreDriver,
        registries: []const registry.ResolvedRegistry,
        options: options_mod.ResolveOptions,
        environ_map: *std.process.Environ.Map,
    ) !candidate_mod.Candidate {


        // 1. Try local store first
        if (try self.tryResolveFromStore(pkg_name, constraint, .moonstone, index, options)) |cand| {
            return cand;
        }

        // 1.5 Try links
        if (try self.tryResolveFromLinks(pkg_name, constraint, index, options)) |cand| {
            return cand;
        }

        if (options.offline) return error.OfflineMode;

        // 2. Try Remote Registries
        for (registries) |reg| {
            const res = moonstone_resolver.resolve_remote(self.allocator, self.io, pkg_name, constraint, reg.url, reg.token, options, environ_map) catch |err| {
                if (err == error.PackageNotFound) continue;
                return err;
            };

            const art = res.desc.artifact[res.artifact_idx];
            return candidate_mod.Candidate{
                .name = try self.allocator.dupe(u8, res.desc.package.name),
                .version = try self.allocator.dupe(u8, res.desc.package.version),
                .kind = res.desc.package.kind,
                .artifact_hash = try self.allocator.dupe(u8, art.hash),
                .runtime = try self.allocator.dupe(u8, art.runtime),
                .runtime_artifact_hash = try self.allocator.dupe(u8, art.runtime_artifact_hash),
                .lua_abi = try self.allocator.dupe(u8, art.lua_abi),
                .lua_api = try self.allocator.dupe(u8, art.lua_api),
                .origin = .{
                    .moonstone_registry = .{
                        .url = try self.allocator.dupe(u8, reg.url),
                        .token = if (reg.token) |t| try self.allocator.dupe(u8, t) else null,
                        .descriptor_path = try self.allocator.dupe(u8, res.descriptor_path),
                        .artifact_idx = res.artifact_idx,
                    },
                },
                .remote_desc = res.desc,
                .registry_url = try self.allocator.dupe(u8, reg.url),
                .registry_token = if (reg.token) |t| try self.allocator.dupe(u8, t) else null,
                .descriptor_path = try self.allocator.dupe(u8, res.descriptor_path),
                .artifact_idx = res.artifact_idx,
                .location = .remote,
            };
        }

        return error.PackageNotFound;
    }

    /// Check the local artifact store for a compatible candidate.
    /// Returns null if no compatible artifact is found.
    pub fn tryResolveFromStore(
        self: Coordinator,
        pkg_name: []const u8,
        constraint: []const u8,
        kind: CoordinatorKind,
        index: driver_mod.StoreDriver,
        options: options_mod.ResolveOptions,
    ) !?candidate_mod.Candidate {
        const resolver_str: ?[]const u8 = switch (kind) {
            .moonstone => "moonstone",
            .rocks => "rocks",
            .artifact => null,
            else => return null, // path and link skip store
        };

        const query = driver_mod.ArtifactQuery{
            .name = pkg_name,
            .target = options.target,
        };
        const candidates = try index.findCandidates(query);
        defer {
            for (candidates) |*c| c.deinit(self.allocator);
            self.allocator.free(candidates);
        }

        for (candidates) |cand| {
            if (resolver_str) |rs| {
                if (cand.resolver) |cr| {
                    if (cr.len == 0 and std.mem.eql(u8, rs, "moonstone")) continue;
                    if (cr.len > 0 and !std.mem.eql(u8, cr, rs)) continue;
                } else if (std.mem.eql(u8, rs, "moonstone")) {
                    continue;
                }
            }
            if (!semver.matches(cand.version, constraint)) continue;

            // 2. ABI compatibility (if applicable)
            if (options.runtime) |active_abi| {
                if (cand.kind != .runtime) {
                    // If the candidate declares its own isolated runtime, it doesn't need to match the project runtime
                    const has_isolated_runtime = if (cand.runtime) |r| r.len > 0 else false;
                    if (!has_isolated_runtime) {
                        if (cand.lua_abi) |candidate_abi| {
                            if (!options_mod.runtimeAbiMatches(active_abi, candidate_abi)) continue;
                        }
                    }
                }
            }

            // For native artifacts, runtime_artifact_hash must match if specified
            if (cand.runtime_artifact_hash) |rah| {
                if (rah.len > 0) {
                    if (options.runtime_artifact_hash) |expected_rah| {
                        if (!std.mem.eql(u8, rah, expected_rah)) continue;
                    }
                }
            }

            // Verify the artifact path actually exists on disk
            std.Io.Dir.cwd().access(self.io, cand.path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    // Remove stale index entry so future lookups don't keep hitting it
                    index.delete_artifact(cand.artifact_hash) catch {};
                    continue;
                }
                return err;
            };

            const origin: candidate_mod.Origin = .{ .artifact_hash = try self.allocator.dupe(u8, cand.artifact_hash) };

            return candidate_mod.Candidate{
                .name = try self.allocator.dupe(u8, cand.name),
                .version = try self.allocator.dupe(u8, cand.version),
                .kind = cand.kind,
                .artifact_hash = try self.allocator.dupe(u8, cand.artifact_hash),
                .lua_abi = if (cand.lua_abi) |a| try self.allocator.dupe(u8, a) else null,
                .lua_api = if (cand.lua_api) |a| try self.allocator.dupe(u8, a) else null,
                .runtime = if (cand.runtime) |r| try self.allocator.dupe(u8, r) else null,
                .runtime_artifact_hash = if (cand.runtime_artifact_hash) |h| try self.allocator.dupe(u8, h) else "",
                .local_path = try self.allocator.dupe(u8, cand.path),
                .origin = origin,
                .location = .local_store,
            };
        }

        return null;
    }

    pub fn tryResolveFromLinks(
        self: Coordinator,
        pkg_name: []const u8,
        constraint: []const u8,
        index: driver_mod.StoreDriver,
        options: options_mod.ResolveOptions,
    ) !?candidate_mod.Candidate {
        const links_store_mod = @import("../store/links.zig");
        var ls = links_store_mod.LinkStore.init(@constCast(&index));
        const entries = try ls.findByName(pkg_name);
        defer {
            for (entries) |*e| {
                var mut_e = e.*;
                mut_e.deinit(self.allocator);
            }
            self.allocator.free(entries);
        }

        for (entries) |entry| {
            if (!semver.matches(entry.version, constraint)) continue;

            // Runtime ABI compatibility check
            if (options.runtime != null) {
                if (entry.kind != .runtime) {
                    // Links don't currently store lua_abi in the links table, 
                    // but we could check the manifest if needed. 
                    // For now assume live links are compatible if the user registered them.
                }
            }

            return candidate_mod.Candidate{
                .name = try self.allocator.dupe(u8, entry.name),
                .version = try self.allocator.dupe(u8, entry.version),
                .kind = entry.kind,
                .artifact_hash = try self.allocator.dupe(u8, "link"),
                .local_path = try self.allocator.dupe(u8, entry.path),
                .origin = .{ .link = try self.allocator.dupe(u8, entry.path) },
                .location = .local_store,
            };
        }

        return null;
    }

    pub fn resolveWithKind(
        self: Coordinator,
        pkg_name: []const u8,
        constraint: []const u8,
        index: driver_mod.StoreDriver,
        registries: []const registry.ResolvedRegistry,
        options: options_mod.ResolveOptions,
        kind: CoordinatorKind,
        environ_map: *std.process.Environ.Map,
    ) !candidate_mod.Candidate {
        // Check local store first for resolvers that can produce cached artifacts
        if (try self.tryResolveFromStore(pkg_name, constraint, kind, index, options)) |cand| {
            return cand;
        }

        return switch (kind) {
            .moonstone => self.resolve(pkg_name, constraint, index, registries, options, environ_map),
            .rocks => rocks_resolver.resolve(self.allocator, self.io, pkg_name, constraint, options, environ_map),
            .path => path_resolver.resolve(self.allocator, self.io, pkg_name, constraint, options),
            .link => link_resolver.resolve(self.allocator, self.io, pkg_name, constraint, index, options, environ_map),
            .artifact => artifact_resolver.resolve(self.allocator, self.io, pkg_name, constraint, index, options),
        };
    }

    pub fn resolve_remote(
        self: Coordinator,
        pkg_name: []const u8,
        constraint: []const u8,
        registry_url: []const u8,
        token: ?[]const u8,
        options: options_mod.ResolveOptions,
        environ_map: *std.process.Environ.Map,
    ) !candidate_mod.RemoteResolveResult {
        return try moonstone_resolver.resolve_remote(self.allocator, self.io, pkg_name, constraint, registry_url, token, options, environ_map);
    }
};

// Legacy alias for compatibility during transition
pub const Resolver = Coordinator;
