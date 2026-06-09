const std = @import("std");
const semver = @import("../../domain/semver.zig");
const package_provider = @import("package_provider.zig");
const registry = @import("../../registry/registry.zig");
const driver_mod = @import("../../store/driver.zig");
const root = @import("../root.zig");
const manifest = @import("../../domain/manifest.zig");
const term_mod = @import("../solver/term.zig");
const candidate_mod = @import("../candidate.zig");
const rocks_resolver = @import("../sources/luarocks.zig");
const path_resolver = @import("../sources/path.zig");
const links_mod = @import("../../store/links.zig");
const package_spec = @import("../../domain/package_spec.zig");
const DependencyRole = @import("../../domain/dependency_role.zig").DependencyRole;

pub const StoreDependencyOrigin = struct {
    child_name: []const u8,
    child_constraint: []const u8,
    child_resolver: ?root.ResolverKind,
    child_registry: ?[]const u8 = null,
    child_role: @import("../../domain/dependency_role.zig").DependencyRole = .runtime,

    parent_name: []const u8,
    parent_version: []const u8,
    parent_resolver: ?root.ResolverKind,

    parent_manifest_path: []const u8,
};

pub const OfflineMissingDiagnostic = struct {
    child_name: []const u8,
    child_constraint: []const u8,
    child_resolver: ?root.ResolverKind,

    parent_name: []const u8,
    parent_version: []const u8,
    parent_resolver: ?root.ResolverKind,

    parent_manifest_path: []const u8,
};

pub const LinkedRuntimeDiagnostic = struct {
    package_name: []const u8,
    package_version: []const u8,
    required_abi: []const u8,
    active_abi: []const u8,
    manifest_path: []const u8,
    suggested_role: ?[]const u8 = null,
};

pub const RegistryProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    registries: []const registry.ResolvedRegistry,
    options: root.ResolveOptions,
    env: ?*std.process.Environ.Map,
    lua_exe: ?[]const u8 = null,
    targets: []const term_mod.Term = &.{},

    // Arena for all package metadata (versions, strings, descriptors, artifacts)
    arena: std.heap.ArenaAllocator,
    artifacts: std.ArrayListUnmanaged(candidate_mod.Candidate) = .empty,

    // Origins of dependencies introduced by store manifests (recorded in getDependencies)
    store_dependency_origins: std.ArrayListUnmanaged(StoreDependencyOrigin) = .empty,

    // Diagnostic set when offline + zero versions + store origin exists
    offline_diagnostic: ?OfflineMissingDiagnostic = null,
    linked_runtime_diagnostic: ?LinkedRuntimeDiagnostic = null,

    pub fn init(
        self: *RegistryProvider,
        allocator: std.mem.Allocator,
        io: std.Io,
        index: driver_mod.StoreDriver,
        registries: []const registry.ResolvedRegistry,
        options: root.ResolveOptions,
        env: ?*std.process.Environ.Map,
        lua_exe: ?[]const u8,
        targets: []const term_mod.Term,
    ) void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .index = index,
            .registries = registries,
            .options = options,
            .env = env,
            .lua_exe = lua_exe,
            .targets = targets,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .artifacts = .empty,
            .store_dependency_origins = .empty,
            .offline_diagnostic = null,
            .linked_runtime_diagnostic = null,
        };
    }

    pub fn deinit(self: *RegistryProvider) void {
        for (self.store_dependency_origins.items) |origin| {
            self.allocator.free(origin.child_name);
            self.allocator.free(origin.child_constraint);
            if (origin.child_registry) |registry_name| self.allocator.free(registry_name);
            self.allocator.free(origin.parent_name);
            self.allocator.free(origin.parent_version);
            self.allocator.free(origin.parent_manifest_path);
        }
        self.store_dependency_origins.deinit(self.allocator);
        if (self.offline_diagnostic) |diag| {
            self.allocator.free(diag.child_name);
            self.allocator.free(diag.child_constraint);
            self.allocator.free(diag.parent_name);
            self.allocator.free(diag.parent_version);
            self.allocator.free(diag.parent_manifest_path);
        }
        if (self.linked_runtime_diagnostic) |diag| {
            self.allocator.free(diag.package_name);
            self.allocator.free(diag.package_version);
            self.allocator.free(diag.required_abi);
            self.allocator.free(diag.active_abi);
            self.allocator.free(diag.manifest_path);
            if (diag.suggested_role) |sr| self.allocator.free(sr);
        }
        // All metadata is in the arena, just deinit it once.
        self.arena.deinit();
    }
    pub fn get_artifact(self: *RegistryProvider, request: package_provider.ArtifactRequest) anyerror!?candidate_mod.Candidate {
        // 1. If artifact_hash is provided, do strict exact lookup first.
        if (request.artifact_hash) |hash| {
            var maybe_cand = self.index.get_candidate_by_hash(hash) catch null;
            if (maybe_cand) |*c| {
                var should_deinit = true;
                defer {
                    if (should_deinit) c.deinit(self.allocator);
                }
                const matches_request = std.mem.eql(u8, c.name, request.name) or std.mem.eql(u8, request.name, "lua");
                if (matches_request) {
                    const v = semver.Version.parse(c.version) catch null;
                    const req_v = semver.Version.parse(request.version) catch null;
                    if (v != null and req_v != null and v.?.compare(req_v.?) == 0) {
                        // Verify the artifact path actually exists on disk
                        std.Io.Dir.cwd().access(self.io, c.path, .{}) catch |err| {
                            if (err == error.FileNotFound) {
                                self.index.delete_artifact(c.artifact_hash) catch {};
                                return null;
                            }
                            return err;
                        };

                        const origin = if (std.mem.eql(u8, c.artifact_hash, "link"))
                            candidate_mod.Origin{ .link = try self.allocator.dupe(u8, c.path) }
                        else if (std.mem.eql(u8, c.artifact_hash, "path"))
                            candidate_mod.Origin{ .path = try self.allocator.dupe(u8, c.path) }
                        else
                            candidate_mod.Origin{ .artifact_hash = try self.allocator.dupe(u8, c.artifact_hash) };

                        should_deinit = false;
                        return candidate_mod.Candidate{
                            .name = try self.allocator.dupe(u8, c.name),
                            .version = try self.allocator.dupe(u8, c.version),
                            .kind = c.kind,
                            .artifact_hash = try self.allocator.dupe(u8, c.artifact_hash),
                            .lua_abi = if (c.lua_abi) |a| try self.allocator.dupe(u8, a) else null,
                            .local_path = try self.allocator.dupe(u8, c.path),
                            .origin = origin,
                            .location = .local_store,
                        };
                    }
                }
            }
            return null;
        }

        // 2. Check pinned/remote-resolved artifacts
        const req_version = semver.Version.parse(request.version) catch return null;
        for (self.artifacts.items) |*art| {
            if (packageNamesMatch(art.name, request.name)) {
                const v = semver.Version.parse(art.version) catch continue;
                if (v.compare(req_version) == 0 or luarocksVersionsMatch(art.version, request.version)) {
                    // Flesh out remote_desc if missing
                    if (art.location == .remote and art.origin == .moonstone_registry and art.remote_desc == null) {
                        const r = art.origin.moonstone_registry;
                        var client = registry.RegistryClient.init(self.allocator, self.io, r.url, r.token, self.env);
                        defer client.deinit();
                        var desc = try client.fetch_descriptor(r.descriptor_path);
                        const arena = self.arena.allocator();
                        art.remote_desc = try desc.clone(arena);
                        desc.deinit(self.allocator);
                    }
                    var artifact = art.*;
                    return try artifact.clone(self.allocator);
                }
            }
        }

        if (std.mem.eql(u8, request.name, "lua")) {
            for (self.artifacts.items) |*art| {
                if (art.kind != .runtime) continue;
                const v = semver.Version.parse(art.version) catch continue;
                if (v.compare(req_version) == 0) {
                    var artifact = art.*;
                    return try artifact.clone(self.allocator);
                }
            }
        }

        // 3. Check store index
        var resolver_str: ?[]const u8 = null;
        for (self.targets) |t| {
            if (std.mem.eql(u8, t.name, request.name)) {
                if (t.resolver) |r| {
                    resolver_str = switch (r) {
                        .moonstone => "moonstone",
                        .rocks => "rocks",
                        .artifact => null,
                        .path => return null,
                        .link => return null,
                    };
                }
                break;
            }
        }

        const query = driver_mod.ArtifactQuery{ .name = request.name };
        const candidates = try self.index.findCandidates(query);
        defer {
            for (candidates) |*c| c.deinit(self.allocator);
            self.allocator.free(candidates);
        }

        for (candidates) |c| {
            if (resolver_str) |rs| {
                if (c.resolver) |cr| {
                    if (cr.len == 0 and std.mem.eql(u8, rs, "moonstone")) continue;
                    if (cr.len > 0 and !std.mem.eql(u8, cr, rs)) continue;
                } else if (std.mem.eql(u8, rs, "moonstone")) {
                    continue;
                }
            }
            const v = semver.Version.parse(c.version) catch continue;
            if (v.compare(req_version) == 0) {
                if (self.options.runtime) |active_abi| {
                    if (c.kind != .runtime) {
                        const has_isolated_runtime = if (c.runtime) |r| r.len > 0 else false;
                        if (!has_isolated_runtime) {
                            if (c.lua_abi) |candidate_abi| {
                                if (!root.options.runtimeAbiMatches(active_abi, candidate_abi)) continue;
                            }
                        }
                    }
                }

                // Verify the artifact path actually exists on disk
                std.Io.Dir.cwd().access(self.io, c.path, .{}) catch |err| {
                    if (err == error.FileNotFound) {
                        self.index.delete_artifact(c.artifact_hash) catch {};
                        continue;
                    }
                    return err;
                };

                const origin = if (std.mem.eql(u8, c.artifact_hash, "link"))
                    candidate_mod.Origin{ .link = try self.allocator.dupe(u8, c.path) }
                else if (std.mem.eql(u8, c.artifact_hash, "path"))
                    candidate_mod.Origin{ .path = try self.allocator.dupe(u8, c.path) }
                else
                    candidate_mod.Origin{ .artifact_hash = try self.allocator.dupe(u8, c.artifact_hash) };

                return candidate_mod.Candidate{
                    .name = try self.allocator.dupe(u8, c.name),
                    .version = try self.allocator.dupe(u8, c.version),
                    .kind = c.kind,
                    .artifact_hash = try self.allocator.dupe(u8, c.artifact_hash),
                    .lua_abi = if (c.lua_abi) |a| try self.allocator.dupe(u8, a) else null,
                    .local_path = try self.allocator.dupe(u8, c.path),
                    .origin = origin,
                    .location = .local_store,
                };
            }
        }

        return null;
    }

    fn luarocksVersionsMatch(candidate: []const u8, requested: []const u8) bool {
        const requested_revision = std.mem.lastIndexOfScalar(u8, requested, '+') orelse return false;
        if (std.mem.lastIndexOfScalar(u8, candidate, '-')) |candidate_revision| {
            return std.mem.eql(u8, candidate[0..candidate_revision], requested[0..requested_revision]) and
                std.mem.eql(u8, candidate[candidate_revision + 1 ..], requested[requested_revision + 1 ..]);
        }
        return false;
    }

    pub fn get_provider(self: *RegistryProvider) package_provider.PackageProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .getVersions = getVersions,
                .getDependencies = getDependencies,
                .getArtifact = getArtifact,
            },
        };
    }

    fn getArtifact(ctx: *anyopaque, request: package_provider.ArtifactRequest) anyerror!?root.ResolveResult {
        const self: *RegistryProvider = @ptrCast(@alignCast(ctx));
        return self.get_artifact(request);
    }

    fn getVersions(ctx: *anyopaque, name: []const u8) anyerror![]const semver.Version {
        const self: *RegistryProvider = @ptrCast(@alignCast(ctx));
        const arena = self.arena.allocator();
        var versions = std.ArrayList(semver.Version).empty;
        errdefer versions.deinit(self.allocator);

        var reg_constraint: ?[]const u8 = null;
        var res_constraint: ?root.CoordinatorKind = null;

        for (self.targets) |t| {
            if (std.mem.eql(u8, t.name, name)) {
                reg_constraint = t.registry;
                res_constraint = t.resolver;
                break;
            }
        }

        if (res_constraint == null) {
            if (self.findStoreDependencyOrigin(name, null)) |origin| {
                res_constraint = origin.child_resolver;
                reg_constraint = origin.child_registry;
            }
        }

        if (res_constraint == .path) {
            const path = reg_constraint orelse return error.MissingPathDependency;
            const candidate = try path_resolver.resolve(arena, self.io, path, "*", self.options);
            try self.artifacts.append(arena, candidate);
            try versions.append(self.allocator, try semver.Version.parseCloned(arena, candidate.version));
        }

        // 1. Check already known artifacts
        for (self.artifacts.items) |art| {
            if (std.mem.eql(u8, art.name, name)) {
                const v = try semver.Version.parseCloned(arena, art.version);
                try versions.append(self.allocator, v);
            }
        }

        // 1.5 Check link store
        if (res_constraint == null or res_constraint.? == .link) {
            var ls = links_mod.LinkStore.init(@constCast(&self.index));
            const entries = try ls.findByName(name);
            defer {
                for (entries) |*e| {
                    var mut_e = e.*;
                    mut_e.deinit(self.allocator);
                }
                self.allocator.free(entries);
            }

            for (entries) |entry| {
                const v = try semver.Version.parseCloned(arena, entry.version);

                // Check if already present
                var already_present = false;
                for (versions.items) |v_existing| {
                    if (v_existing.compare(v) == 0) {
                        already_present = true;
                        break;
                    }
                }
                if (already_present) continue;

                try self.artifacts.append(arena, .{
                    .name = try arena.dupe(u8, entry.name),
                    .kind = entry.kind,
                    .artifact_hash = try arena.dupe(u8, "link"),
                    .version = try arena.dupe(u8, entry.version),
                    .local_path = try arena.dupe(u8, entry.path),
                    .origin = .{ .link = try arena.dupe(u8, entry.path) },
                    .location = .local_store,
                });

                try versions.append(self.allocator, v);
            }
        }

        // 2. Check local store
        const may_check_store = if (res_constraint) |rc| rc != .path and rc != .link else true;
        if (may_check_store) {
            const query = driver_mod.ArtifactQuery{ .name = name };
            var resolver_filter: ?[]const u8 = null;
            if (res_constraint) |rc| {
                resolver_filter = switch (rc) {
                    .moonstone => "moonstone",
                    .rocks => "rocks",
                    .artifact => null,
                    .path => null,
                    .link => null,
                };
            }
            const local_candidates = self.index.findCandidates(query) catch |err| blk: {
                if (err == error.SQLitePrepareError) break :blk @as([]driver_mod.Candidate, &.{});
                return err;
            };
            defer {
                for (local_candidates) |*c| c.deinit(self.allocator);
                self.allocator.free(local_candidates);
            }

            for (local_candidates) |cand| {
                if (resolver_filter) |rf| {
                    if (cand.resolver) |cr| {
                        if (cr.len == 0 and std.mem.eql(u8, rf, "moonstone")) continue;
                        if (cr.len > 0 and !std.mem.eql(u8, cr, rf)) continue;
                    } else if (std.mem.eql(u8, rf, "moonstone")) {
                        continue;
                    }
                }
                if (res_constraint) |rc| {
                    if (rc == .link and !std.mem.eql(u8, cand.artifact_hash, "link")) continue;
                    if (rc == .path and !std.mem.eql(u8, cand.artifact_hash, "path")) continue;
                    if (rc == .artifact and (std.mem.eql(u8, cand.artifact_hash, "link") or std.mem.eql(u8, cand.artifact_hash, "path"))) continue;
                }
                if (self.options.runtime) |active_abi| {
                    if (cand.kind != .runtime) {
                        const has_isolated_runtime = if (cand.runtime) |r| r.len > 0 else false;
                        if (!has_isolated_runtime) {
                            if (cand.lua_abi) |candidate_abi| {
                                if (!root.options.runtimeAbiMatches(active_abi, candidate_abi)) continue;
                            }
                        }
                    }
                }

                if (res_constraint) |_| {
                    var already_present = false;
                    for (versions.items) |v| {
                        const parsed_v = semver.Version.parse(cand.version) catch continue;
                        if (v.compare(parsed_v) == 0) {
                            already_present = true;
                            break;
                        }
                    }
                    if (already_present) continue;
                }

                std.Io.Dir.cwd().access(self.io, cand.path, .{}) catch |err| {
                    if (err == error.FileNotFound) {
                        self.index.delete_artifact(cand.artifact_hash) catch {};
                        continue;
                    }
                    return err;
                };

                const v = try semver.Version.parseCloned(arena, cand.version);
                const origin = if (std.mem.eql(u8, cand.artifact_hash, "link"))
                    candidate_mod.Origin{ .link = try arena.dupe(u8, cand.path) }
                else if (std.mem.eql(u8, cand.artifact_hash, "path"))
                    candidate_mod.Origin{ .path = try arena.dupe(u8, cand.path) }
                else
                    candidate_mod.Origin{ .artifact_hash = try arena.dupe(u8, cand.artifact_hash) };

                try self.artifacts.append(arena, .{
                    .name = try arena.dupe(u8, cand.name),
                    .kind = cand.kind,
                    .artifact_hash = try arena.dupe(u8, cand.artifact_hash),
                    .version = try arena.dupe(u8, cand.version),
                    .local_path = try arena.dupe(u8, cand.path),
                    .lua_abi = if (cand.lua_abi) |a| try arena.dupe(u8, a) else null,
                    .origin = origin,
                    .location = .local_store,
                });

                try versions.append(self.allocator, v);
            }
        }

        // 3. Resolve LuaRocks packages online
        if (!self.options.offline and res_constraint != null and res_constraint.? == .rocks and self.env != null) {
            var already_present = false;
            for (versions.items) |_| {
                already_present = true;
                break;
            }

            if (!already_present) {
                var opts = self.options;
                opts.lua_exe = self.lua_exe;
                const cand_opt: ?candidate_mod.Candidate = rocks_resolver.resolve(self.allocator, self.io, name, "*", opts, self.env.?) catch |err| blk: {
                    if (err == error.PackageNotFound or err == error.FileNotFound or err == error.RocksVersionDiscoveryFailed or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) {
                        break :blk null;
                    }
                    return err;
                };
                var cand = cand_opt orelse return try versions.toOwnedSlice(self.allocator);
                defer cand.deinit(self.allocator);

                cand.location = .local_store;
                const version = try semver.Version.parseCloned(arena, cand.version);
                try self.artifacts.append(arena, try cand.clone(arena));
                try versions.append(self.allocator, version);
            }
        }

        // 4. Check remote registries
        if (!self.options.offline and (res_constraint == null or res_constraint.? == .moonstone)) {
            for (self.registries) |reg| {
                if (reg_constraint) |rc| {
                    if (std.mem.eql(u8, rc, "moonstone")) {
                        // All
                    } else if (!std.mem.eql(u8, reg.name, rc)) {
                        continue;
                    }
                }

                var client = registry.RegistryClient.init(self.allocator, self.io, reg.url, reg.token, self.env);
                defer client.deinit();
                const idx = client.fetch_index() catch continue;
                defer idx.deinit(self.allocator);
                const private_idx = client.fetch_private_index() catch null;
                defer if (private_idx) |private| private.deinit(self.allocator);

                for (0..2) |index_number| {
                    const packages = if (index_number == 0) idx.package else if (private_idx) |private| private.package else continue;
                    for (packages) |pkg| {
                        if (packageNamesMatch(pkg.name, name)) {
                            const v = try semver.Version.parseCloned(arena, pkg.version);

                            if (res_constraint) |_| {
                                var already_present = false;
                                for (versions.items) |v_existing| {
                                    if (v_existing.compare(v) == 0) {
                                        already_present = true;
                                        break;
                                    }
                                }
                                if (already_present) continue;
                            }

                            var desc = client.fetch_descriptor(pkg.descriptor) catch continue;
                            defer desc.deinit(self.allocator);
                            const selected_artifact_idx = selectArtifactForRuntime(desc, self.options) orelse continue;
                            const selected_artifact = desc.artifact[selected_artifact_idx];
                            const desc_clone = try desc.clone(arena);

                            try self.artifacts.append(arena, .{
                                .name = try arena.dupe(u8, pkg.name),
                                .kind = pkg.kind,
                                .artifact_hash = try arena.dupe(u8, selected_artifact.hash),
                                .version = try arena.dupe(u8, pkg.version),
                                .lua_abi = try arena.dupe(u8, selected_artifact.lua_abi),
                                .registry_url = try arena.dupe(u8, reg.url),
                                .registry_token = if (reg.token) |t| try arena.dupe(u8, t) else null,
                                .descriptor_path = try arena.dupe(u8, pkg.descriptor),
                                .artifact_idx = selected_artifact_idx,
                                .remote_desc = desc_clone,
                                .origin = .{
                                    .moonstone_registry = .{
                                        .url = try arena.dupe(u8, reg.url),
                                        .token = if (reg.token) |t| try arena.dupe(u8, t) else null,
                                        .descriptor_path = try arena.dupe(u8, pkg.descriptor),
                                        .artifact_idx = selected_artifact_idx,
                                    },
                                },
                            });

                            try versions.append(self.allocator, v);
                        }
                    }
                }
            }
        }

        if (versions.items.len == 0 and self.options.offline) {
            if (self.findStoreDependencyOrigin(name, res_constraint)) |origin| {
                if (self.offline_diagnostic) |old| {
                    self.allocator.free(old.child_name);
                    self.allocator.free(old.child_constraint);
                    self.allocator.free(old.parent_name);
                    self.allocator.free(old.parent_version);
                    self.allocator.free(old.parent_manifest_path);
                }
                self.offline_diagnostic = .{
                    .child_name = try self.allocator.dupe(u8, origin.child_name),
                    .child_constraint = try self.allocator.dupe(u8, origin.child_constraint),
                    .child_resolver = origin.child_resolver,
                    .parent_name = try self.allocator.dupe(u8, origin.parent_name),
                    .parent_version = try self.allocator.dupe(u8, origin.parent_version),
                    .parent_resolver = origin.parent_resolver,
                    .parent_manifest_path = try self.allocator.dupe(u8, origin.parent_manifest_path),
                };
            }
        }

        return try versions.toOwnedSlice(self.allocator);
    }

    fn resolverMatches(requested: ?root.ResolverKind, origin: ?root.ResolverKind) bool {
        if (requested == null) return true;
        if (origin == null) return false;
        return requested.? == origin.?;
    }

    fn findStoreDependencyOrigin(self: *RegistryProvider, name: []const u8, resolver: ?root.ResolverKind) ?StoreDependencyOrigin {
        for (self.store_dependency_origins.items) |origin| {
            if (std.mem.eql(u8, origin.child_name, name)) {
                if (resolverMatches(resolver, origin.child_resolver)) {
                    return origin;
                }
            }
        }
        return null;
    }

    fn selectArtifactForRuntime(desc: manifest.RemotePackageDescriptor, options: root.ResolveOptions) ?usize {
        const allocator = std.heap.page_allocator;
        const host = get_host_target_sync(allocator) catch return null;
        defer allocator.free(host);

        for (desc.artifact, 0..) |art, i| {
            if (artifactMatchesRuntimeAbi(desc.package.kind, art, options) and (std.mem.eql(u8, art.target, host) or std.mem.eql(u8, art.target, "any") or std.mem.eql(u8, art.target, "native"))) {
                return i;
            }
        }

        for (desc.artifact, 0..) |art, i| {
            if (artifactMatchesRuntimeAbi(desc.package.kind, art, options) and std.mem.eql(u8, art.target, "source")) {
                return i;
            }
        }

        return null;
    }

    fn get_host_target_sync(allocator: std.mem.Allocator) ![]const u8 {
        const builtin = @import("builtin");
        const arch = switch (builtin.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => return error.UnsupportedArch,
        };
        const os = switch (builtin.os.tag) {
            .linux => "linux-gnu",
            .macos => "macos",
            .windows => "windows-msvc",
            .freebsd => "freebsd",
            else => return error.UnsupportedOS,
        };
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os });
    }

    fn artifactMatchesRuntimeAbi(kind: manifest.Kind, art: manifest.RemoteArtifact, options: root.ResolveOptions) bool {
        // If it's a runtime artifact, it doesn't need to match the project's active ABI
        if (kind == .runtime) return true;

        // If the artifact declares its own isolated runtime, it doesn't need to match the project runtime
        if (art.runtime.len > 0) return true;

        if (options.runtime) |active_abi| {
            return root.options.runtimeAbiMatches(active_abi, art.lua_abi);
        }
        return true;
    }

    fn targetRole(self: *RegistryProvider, name: []const u8) DependencyRole {
        for (self.targets) |target| {
            if (std.ascii.eqlIgnoreCase(target.name, name)) return target.role;
        }
        return .runtime;
    }

    fn linkedPackageUsesIsolatedRuntime(role: DependencyRole, kind: manifest.Kind) bool {
        const policy = role.getProjectionPolicy();
        _ = kind;
        return policy.expose_tool_scope or policy.expose_helper_scope;
    }

    fn getDependencies(ctx: *anyopaque, name: []const u8, version: semver.Version) anyerror![]const term_mod.Term {
        const self: *RegistryProvider = @ptrCast(@alignCast(ctx));
        const arena = self.arena.allocator();
        var terms = std.ArrayList(term_mod.Term).empty;

        var artifact: ?candidate_mod.Candidate = null;
        for (self.artifacts.items) |*art| {
            if (!std.mem.eql(u8, art.name, name)) continue;
            const v = semver.Version.parse(art.version) catch continue;
            if (version.compare(v) == 0) {
                if (art.origin == .moonstone_registry and art.remote_desc == null) {
                    const r = art.origin.moonstone_registry;
                    var client = registry.RegistryClient.init(self.allocator, self.io, r.url, r.token, self.env);
                    defer client.deinit();
                    var desc = try client.fetch_descriptor(r.descriptor_path);
                    art.remote_desc = try desc.clone(arena);
                    desc.deinit(self.allocator);
                }
                artifact = art.*;
                break;
            }
        }

        if (artifact) |art| {
            if (art.remote_desc) |desc| {
                for (desc.compat.runtimes) |rt| {
                    var rt_name = rt;
                    var rt_ver: []const u8 = "*";
                    if (std.mem.indexOfScalar(u8, rt, '@')) |pos| {
                        rt_name = rt[0..pos];
                        rt_ver = rt[pos + 1 ..];
                    }
                    if (std.mem.eql(u8, rt_ver, "unknown")) continue;

                    try terms.append(self.allocator, .{
                        .name = try arena.dupe(u8, rt_name),
                        .range = try semver.VersionRange.parse(arena, rt_ver),
                        .resolver = .moonstone,
                    });
                }

                for (desc.dependencies) |dep| {
                    const raw_spec = try dep.toSpecString(arena);
                    const spec = try package_spec.parsePackageSpec(self.allocator, raw_spec);
                    defer spec.deinit(self.allocator);
                    try terms.append(self.allocator, .{
                        .name = try arena.dupe(u8, spec.name),
                        .range = try semver.VersionRange.parse(arena, spec.constraint orelse "*"),
                        .registry = if (spec.registry) |registry_name| try arena.dupe(u8, registry_name) else null,
                        .resolver = spec.resolver,
                    });
                }

                // Add runtime dependency if specified in the artifact
                if (art.artifact_idx) |idx| {
                    const selected_art = desc.artifact[idx];
                    if (selected_art.runtime.len > 0) {
                        const spec = try package_spec.parsePackageSpec(self.allocator, selected_art.runtime);
                        defer spec.deinit(self.allocator);
                        try terms.append(self.allocator, .{
                            .name = try arena.dupe(u8, spec.name),
                            .range = try semver.VersionRange.parse(arena, spec.constraint orelse "*"),
                            .registry = if (spec.registry) |registry_name| try arena.dupe(u8, registry_name) else null,
                            .resolver = spec.resolver,
                        });
                    }
                }

                return try terms.toOwnedSlice(self.allocator);
            }

            if (std.mem.eql(u8, art.artifact_hash, "link") or std.mem.eql(u8, art.artifact_hash, "path")) {
                if (art.local_path) |lp| {
                    const manifest_path = try std.fs.path.join(self.allocator, &.{ lp, "moonstone.toml" });
                    defer self.allocator.free(manifest_path);
                    const content = try std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
                    defer self.allocator.free(content);
                    var mt = try manifest.MoonstoneToml.parse(self.allocator, content);
                    defer mt.deinit(self.allocator);

                    if (self.options.runtime) |active_abi| {
                        const role = self.targetRole(art.name);
                        if (!linkedPackageUsesIsolatedRuntime(role, mt.package.kind) and !root.options.runtimeAbiMatches(active_abi, mt.runtime.abi)) {
                            const suggested_role: ?[]const u8 = if (mt.package.kind == .script or mt.package.kind == .bin)
                                try self.allocator.dupe(u8, "tool")
                            else
                                null;
                            self.linked_runtime_diagnostic = .{
                                .package_name = try self.allocator.dupe(u8, art.name),
                                .package_version = try self.allocator.dupe(u8, art.version),
                                .required_abi = try self.allocator.dupe(u8, mt.runtime.abi),
                                .active_abi = try self.allocator.dupe(u8, active_abi),
                                .manifest_path = try self.allocator.dupe(u8, manifest_path),
                                .suggested_role = suggested_role,
                            };
                            return error.LinkedRuntimeAbiMismatch;
                        }
                    }

                    for (mt.dependencies.items) |dep| {
                        const raw_spec = try dep.toSpecString(self.allocator);
                        defer self.allocator.free(raw_spec);
                        const spec = try package_spec.parsePackageSpec(self.allocator, raw_spec);
                        defer spec.deinit(self.allocator);

                        var child_name = dep.name;
                        var child_constraint = dep.constraint;
                        var child_registry: ?[]const u8 = null;
                        if (spec.resolver != null or spec.registry != null) {
                            child_name = spec.name;
                            child_constraint = spec.constraint orelse "*";
                        }

                        if (spec.resolver == .path) {
                            const child_path = if (std.fs.path.isAbsolute(spec.name))
                                try arena.dupe(u8, spec.name)
                            else
                                try std.fs.path.join(arena, &.{ lp, spec.name });
                            const child = try path_resolver.resolve(arena, self.io, child_path, child_constraint, self.options);
                            child_name = child.name;
                            child_registry = child_path;
                            try self.artifacts.append(arena, child);
                        } else if (spec.registry) |registry_name| {
                            child_registry = registry_name;
                        }

                        try self.store_dependency_origins.append(self.allocator, .{
                            .child_name = try self.allocator.dupe(u8, child_name),
                            .child_constraint = try self.allocator.dupe(u8, child_constraint),
                            .child_resolver = spec.resolver,
                            .child_registry = if (child_registry) |registry_name| try self.allocator.dupe(u8, registry_name) else null,
                            .child_role = dep.role,
                            .parent_name = try self.allocator.dupe(u8, art.name),
                            .parent_version = try self.allocator.dupe(u8, art.version),
                            .parent_resolver = if (std.mem.eql(u8, art.artifact_hash, "link")) .link else .path,
                            .parent_manifest_path = try self.allocator.dupe(u8, manifest_path),
                        });

                        try terms.append(self.allocator, .{
                            .name = try arena.dupe(u8, child_name),
                            .range = try semver.VersionRange.parse(arena, child_constraint),
                            .registry = if (child_registry) |registry_name| try arena.dupe(u8, registry_name) else null,
                            .resolver = spec.resolver,
                            .role = dep.role,
                        });
                    }
                    return try terms.toOwnedSlice(self.allocator);
                }
            }

            if (art.location == .local_store) {
                if (art.local_path) |lp| {
                    const manifest_path = try std.fs.path.join(self.allocator, &.{ lp, "manifest.toml" });
                    defer self.allocator.free(manifest_path);
                    const content = try std.Io.Dir.cwd().readFileAlloc(self.io, manifest_path, self.allocator, std.Io.Limit.limited(10 * 1024 * 1024));
                    defer self.allocator.free(content);
                    var sm = try manifest.StoreManifest.parse(self.allocator, content);
                    defer sm.deinit(self.allocator);

                    if (sm.compat.runtime_version.len > 0) {
                        var rt_name = sm.compat.runtime_version;
                        var rt_ver: []const u8 = "*";
                        if (std.mem.indexOfScalar(u8, rt_name, '@')) |pos| {
                            rt_ver = rt_name[pos + 1 ..];
                            rt_name = rt_name[0..pos];
                        }
                        if (!std.mem.eql(u8, rt_ver, "unknown")) {
                            try terms.append(self.allocator, .{
                                .name = try arena.dupe(u8, rt_name),
                                .range = try semver.VersionRange.parse(arena, rt_ver),
                                .resolver = .moonstone,
                            });
                        }
                    }

                    const parent_resolver: ?root.ResolverKind = if (sm.origin.resolver.len > 0)
                        root.CoordinatorKind.fromString(sm.origin.resolver) catch null
                    else if (art.origin == .moonstone_registry)
                        .moonstone
                    else if (art.origin == .luarocks)
                        .rocks
                    else
                        null;

                    for (sm.dependencies) |dep| {
                        const dep_resolver = if (dep.resolver) |r|
                            if (std.mem.eql(u8, r, "rocks")) root.CoordinatorKind.rocks else if (std.mem.eql(u8, r, "moonstone")) root.CoordinatorKind.moonstone else root.CoordinatorKind.moonstone
                        else
                            root.CoordinatorKind.moonstone;

                        try self.store_dependency_origins.append(self.allocator, .{
                            .child_name = try self.allocator.dupe(u8, dep.name),
                            .child_constraint = try self.allocator.dupe(u8, dep.constraint),
                            .child_resolver = dep_resolver,
                            .child_role = dep.role,
                            .parent_name = try self.allocator.dupe(u8, art.name),
                            .parent_version = try self.allocator.dupe(u8, art.version),
                            .parent_resolver = parent_resolver,
                            .parent_manifest_path = try self.allocator.dupe(u8, manifest_path),
                        });

                        try terms.append(self.allocator, .{
                            .name = try arena.dupe(u8, dep.name),
                            .range = try semver.VersionRange.parse(arena, dep.constraint),
                            .resolver = dep_resolver,
                            .role = dep.role,
                        });
                    }
                    return try terms.toOwnedSlice(self.allocator);
                }
            }
        }

        return try terms.toOwnedSlice(self.allocator);
    }
};

fn packageNamesMatch(index_name: []const u8, requested_name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(index_name, requested_name)) return true;

    const canonical_req = if (std.mem.eql(u8, requested_name, "lua")) @as([]const u8, "moonstone/lua") else if (std.mem.eql(u8, requested_name, "luajit")) @as([]const u8, "moonstone/luajit") else if (std.mem.eql(u8, requested_name, "love")) @as([]const u8, "moonstone/love") else requested_name;

    const canonical_idx = if (std.mem.eql(u8, index_name, "lua")) @as([]const u8, "moonstone/lua") else if (std.mem.eql(u8, index_name, "luajit")) @as([]const u8, "moonstone/luajit") else if (std.mem.eql(u8, index_name, "love")) @as([]const u8, "moonstone/love") else index_name;

    return std.mem.eql(u8, canonical_idx, canonical_req);
}
