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
const moonstone_registry_resolver = @import("../sources/moonstone_registry.zig");
const path_resolver = @import("../sources/path.zig");
const links_mod = @import("../../store/links.zig");
const platform_target = @import("../../platform/target.zig");
const package_spec = @import("../../domain/package_spec.zig");
const metadata_prefetch = @import("../metadata_prefetch.zig");
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

/// Supplies a host-executable Lua interpreter when a foreign target needs to
/// evaluate LuaRocks metadata. The provider owns the returned path's lifetime.
pub const LuaMetadataInterpreterProvider = *const fn (context: ?*anyopaque) anyerror![]const u8;

pub const RegistryProvider = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    registries: []const registry.ResolvedRegistry,
    options: root.ResolveOptions,
    env: ?*std.process.Environ.Map,
    lua_exe: ?[]const u8 = null,
    lua_metadata_interpreter_provider: ?LuaMetadataInterpreterProvider = null,
    lua_metadata_interpreter_context: ?*anyopaque = null,
    rocks_metadata_prefetch: ?*const metadata_prefetch.RocksMetadataPrefetch = null,
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
        lua_metadata_interpreter_provider: ?LuaMetadataInterpreterProvider,
        lua_metadata_interpreter_context: ?*anyopaque,
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
            .lua_metadata_interpreter_provider = lua_metadata_interpreter_provider,
            .lua_metadata_interpreter_context = lua_metadata_interpreter_context,
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

    /// Resolves the host interpreter used to parse LuaRocks metadata once.
    /// Prefetch workers receive this resolved value so they never mutate the
    /// provider while PubGrub is reading from it.
    pub fn luaMetadataInterpreter(self: *RegistryProvider) !?[]const u8 {
        if (self.lua_exe) |lua_exe| return lua_exe;
        const provider = self.lua_metadata_interpreter_provider orelse return null;
        const lua_exe = try provider(self.lua_metadata_interpreter_context);
        self.lua_exe = lua_exe;
        return lua_exe;
    }

    fn registryUrlFor(self: *const RegistryProvider, identity: ?[]const u8, resolver_name: []const u8) ?[]const u8 {
        const wanted = identity orelse resolver_name;
        for (self.registries) |reg| {
            if (std.mem.eql(u8, reg.name, wanted) and std.mem.eql(u8, reg.resolver, resolver_name)) return reg.url;
        }
        return null;
    }

    /// The concrete endpoint used by LuaRocks metadata requests. Keeping this
    /// normalization shared makes prefetch keys equal synchronous fallback
    /// lookups, including an explicit MOONSTONE_LUAROCKS_URL override.
    pub fn luarocksMetadataBaseFor(self: *const RegistryProvider, identity: ?[]const u8) []const u8 {
        return self.registryUrlFor(identity, "rocks") orelse
            if (self.env) |env| env.get("MOONSTONE_LUAROCKS_URL") orelse "https://luarocks.org" else "https://luarocks.org";
    }

    pub fn setRocksMetadataPrefetch(self: *RegistryProvider, prefetch: ?*const metadata_prefetch.RocksMetadataPrefetch) void {
        self.rocks_metadata_prefetch = prefetch;
    }

    pub fn get_artifact(self: *RegistryProvider, request: package_provider.ArtifactRequest) anyerror!?candidate_mod.Candidate {
        const request_is_rocks = request.resolver == .rocks;
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
                    const v = parseResolverVersion(c.version, request_is_rocks) catch null;
                    const req_v = parseResolverVersion(request.version, request_is_rocks) catch null;
                    if (v != null and req_v != null and (compareResolverVersion(v.?, req_v.?, request_is_rocks) == 0 or (request_is_rocks and !req_v.?.revision and v.?.compareLuaRocksUpstream(req_v.?) == 0))) {
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
                            .lua_api = if (c.lua_api) |a| try self.allocator.dupe(u8, a) else null,
                            .runtime = if (c.runtime) |r| try self.allocator.dupe(u8, r) else null,
                            .runtime_artifact_hash = if (c.runtime_artifact_hash) |h| try self.allocator.dupe(u8, h) else "",
                            .local_path = try self.allocator.dupe(u8, c.path),
                            .origin = origin,
                            .location = .local_store,
                        };
                    }
                }
            }
        }

        // 2. Check pinned/remote-resolved artifacts
        const req_version = parseResolverVersion(request.version, request_is_rocks) catch return null;
        for (self.artifacts.items) |*art| {
            if (packageNamesMatch(art.name, request.name)) {
                const art_is_rocks = art.origin == .luarocks or request_is_rocks;
                const v = parseResolverVersion(art.version, art_is_rocks) catch continue;
                if (compareResolverVersion(v, req_version, art_is_rocks) == 0 or luarocksVersionsMatch(art.version, request.version)) {
                    // Flesh out remote_desc if missing
                    if (art.location == .remote and art.origin == .moonstone_registry and art.remote_desc == null) {
                        const r = art.origin.moonstone_registry;
                        var client = registry.RegistryClient.init(self.allocator, self.io, r.url, r.token, self.env);
                        defer client.deinit();
                        var desc = try client.fetch_descriptor(r.descriptor_path);
                        const arena = self.arena.allocator();
                        const selected_artifact_idx = selectArtifactForRuntime(desc, self.options) orelse return null;
                        const selected_artifact = desc.artifact[selected_artifact_idx];
                        art.artifact_idx = selected_artifact_idx;
                        art.artifact_hash = try arena.dupe(u8, selected_artifact.hash);
                        art.lua_abi = try arena.dupe(u8, selected_artifact.lua_abi);
                        art.lua_api = try arena.dupe(u8, selected_artifact.lua_api);
                        art.runtime = try arena.dupe(u8, selected_artifact.runtime);
                        art.runtime_artifact_hash = try arena.dupe(u8, selected_artifact.runtime_artifact_hash);
                        art.remote_desc = try desc.clone(arena);
                        desc.deinit(self.allocator);
                    }
                    if (request.artifact_hash) |expected_hash| {
                        if (!std.mem.eql(u8, art.artifact_hash, expected_hash)) continue;
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
        var resolver_str: ?[]const u8 = if (request.resolver) |resolver| switch (resolver) {
            .moonstone => "moonstone",
            .rocks => "rocks",
            .artifact => null,
            .path => return null,
            .link => return null,
        } else null;
        if (resolver_str == null) {
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
        }
        if (resolver_str == null) {
            if (self.findStoreDependencyOrigin(request.name, null)) |origin| {
                resolver_str = resolverKindToStoreString(origin.child_resolver);
            }
        }
        const query = storeQueryForName(request.name, resolver_str, self.options.target);
        const candidates = try self.index.findCandidates(query);
        defer {
            for (candidates) |*c| c.deinit(self.allocator);
            self.allocator.free(candidates);
        }

        for (candidates) |c| {
            if (candidateHasMalformedRuntimeMetadata(c)) continue;
            if (request.artifact_hash) |expected_hash| {
                if (!std.mem.eql(u8, c.artifact_hash, expected_hash)) continue;
            }
            if (resolver_str) |rs| {
                if (c.resolver) |cr| {
                    if (cr.len == 0 and !std.mem.eql(u8, rs, "moonstone")) continue;
                    if (cr.len > 0 and !std.mem.eql(u8, cr, rs)) continue;
                } else if (!std.mem.eql(u8, rs, "moonstone")) {
                    continue;
                }
            }
            const candidate_is_rocks = if (c.resolver) |resolver_name| std.mem.eql(u8, resolver_name, "rocks") else request_is_rocks;
            const v = parseResolverVersion(c.version, candidate_is_rocks) catch continue;
            if (compareResolverVersion(v, req_version, candidate_is_rocks) == 0 or (candidate_is_rocks and !req_version.revision and v.compareLuaRocksUpstream(req_version) == 0)) {
                if (!storeCandidateCompatible(c, self.options)) continue;

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
                    .lua_api = if (c.lua_api) |a| try self.allocator.dupe(u8, a) else null,
                    .runtime = if (c.runtime) |r| try self.allocator.dupe(u8, r) else null,
                    .runtime_artifact_hash = if (c.runtime_artifact_hash) |h| try self.allocator.dupe(u8, h) else "",
                    .local_path = try self.allocator.dupe(u8, c.path),
                    .origin = origin,
                    .location = .local_store,
                };
            }
        }

        // 4. Check remote registries as fallback for transitive dependencies
        if (!self.options.offline and (resolver_str == null or std.mem.eql(u8, resolver_str.?, "moonstone"))) {
            const exact_version_constraint = try std.fmt.allocPrint(self.allocator, "={s}", .{request.version});
            defer self.allocator.free(exact_version_constraint);
            for (self.registries) |reg| {
                if (!std.mem.eql(u8, reg.resolver, "moonstone")) continue;
                var remote = moonstone_registry_resolver.resolve_remote(
                    self.allocator,
                    self.io,
                    request.name,
                    exact_version_constraint,
                    reg.url,
                    reg.token,
                    self.options,
                    self.env,
                ) catch continue;
                defer remote.desc.deinit(self.allocator);
                defer self.allocator.free(remote.descriptor_path);

                const selected_artifact = remote.desc.artifact[remote.artifact_idx];
                if (request.artifact_hash) |expected_hash| {
                    if (!std.mem.eql(u8, selected_artifact.hash, expected_hash)) continue;
                }

                return candidate_mod.Candidate{
                    .name = try self.allocator.dupe(u8, remote.desc.package.name),
                    .version = try self.allocator.dupe(u8, remote.desc.package.version),
                    .kind = remote.desc.package.kind,
                    .artifact_hash = try self.allocator.dupe(u8, selected_artifact.hash),
                    .lua_abi = try self.allocator.dupe(u8, selected_artifact.lua_abi),
                    .lua_api = try self.allocator.dupe(u8, selected_artifact.lua_api),
                    .runtime = try self.allocator.dupe(u8, selected_artifact.runtime),
                    .runtime_artifact_hash = try self.allocator.dupe(u8, selected_artifact.runtime_artifact_hash),
                    .remote_desc = try remote.desc.clone(self.allocator),
                    .registry_name = try self.allocator.dupe(u8, reg.name),
                    .registry_url = try self.allocator.dupe(u8, reg.url),
                    .registry_token = if (reg.token) |t| try self.allocator.dupe(u8, t) else null,
                    .descriptor_path = try self.allocator.dupe(u8, remote.descriptor_path),
                    .artifact_idx = remote.artifact_idx,
                    .origin = .{
                        .moonstone_registry = .{
                            .url = try self.allocator.dupe(u8, reg.url),
                            .token = if (reg.token) |t| try self.allocator.dupe(u8, t) else null,
                            .descriptor_path = try self.allocator.dupe(u8, remote.descriptor_path),
                            .artifact_idx = remote.artifact_idx,
                        },
                    },
                };
            }
        }

        // Fresh LuaRocks resolution deliberately returns a selected source
        // request rather than materializing inside PubGrub solution
        // extraction. `moon sync` realizes these candidates after the whole
        // graph is accepted, through its bounded realization scheduler.
        // Locked replay is provenance-driven. This generic provider has no
        // locked rockspec/source URLs, so it must not materialize Rocks by
        // rediscovering package metadata; locked_realizer owns that path.
        if (!self.options.offline and self.env != null) {
            var is_rocks = request.resolver == .rocks;
            if (!is_rocks) {
                if (self.findStoreDependencyOrigin(request.name, .rocks)) |_| {
                    is_rocks = true;
                }
            }
            if (is_rocks) {
                if (self.options.locked) return null;
                const base = self.env.?.get("MOONSTONE_LUAROCKS_URL") orelse self.registryUrlFor(null, "rocks") orelse "https://luarocks.org";
                return candidate_mod.Candidate{
                    .name = try self.allocator.dupe(u8, request.name),
                    .version = try self.allocator.dupe(u8, request.version),
                    .kind = .lib,
                    .artifact_hash = try self.allocator.dupe(u8, ""),
                    .lua_abi = if (self.options.runtime) |abi| try self.allocator.dupe(u8, abi) else null,
                    .runtime_artifact_hash = if (self.options.runtime_artifact_hash) |artifact_hash| try self.allocator.dupe(u8, artifact_hash) else try self.allocator.dupe(u8, ""),
                    .registry_name = try self.allocator.dupe(u8, "rocks"),
                    .registry_url = try self.allocator.dupe(u8, base),
                    .origin = .{ .luarocks = .{
                        .url = try self.allocator.dupe(u8, base),
                        .rockspec_path = try self.allocator.dupe(u8, ""),
                    } },
                    .location = .remote,
                };
            }
        }

        return null;
    }

    fn luarocksVersionsMatch(candidate: []const u8, requested: []const u8) bool {
        const cand_v = semver.Version.parseLuaRocks(candidate) catch return false;
        const req_v = semver.Version.parseLuaRocks(requested) catch return false;
        if (req_v.revision) {
            return cand_v.compareLuaRocks(req_v) == 0;
        }
        return cand_v.compareLuaRocksUpstream(req_v) == 0;
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
            if (packageNamesMatch(art.name, name)) {
                const v = if (art.origin == .luarocks)
                    try semver.Version.parseLuaRocksCloned(arena, art.version)
                else
                    try semver.Version.parseCloned(arena, art.version);
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
        var direct_target_range: ?semver.VersionRange = null;
        for (self.targets) |target| {
            if (packageNamesMatch(target.name, name)) {
                direct_target_range = target.range;
                break;
            }
        }
        var local_target_satisfies_constraint = false;
        const may_check_store = if (res_constraint) |rc| rc != .path and rc != .link else true;
        if (may_check_store) {
            var resolver_filter: ?[]const u8 = null;
            if (res_constraint) |rc| {
                resolver_filter = resolverKindToStoreString(rc);
            }
            const query = storeQueryForName(name, resolver_filter, self.options.target);
            const local_candidates = self.index.findCandidates(query) catch |err| blk: {
                if (err == error.SQLitePrepareError) break :blk @as([]driver_mod.Candidate, &.{});
                return err;
            };
            defer {
                for (local_candidates) |*c| c.deinit(self.allocator);
                self.allocator.free(local_candidates);
            }

            for (local_candidates) |cand| {
                if (candidateHasMalformedRuntimeMetadata(cand)) continue;
                // `--update` refreshes resolver metadata as well as versions.
                // Keep cached candidates for normal/offline resolution, but
                // let Moonstone registry and LuaRocks candidates be revisited
                // online so their declared closures cannot remain stale.
                if (!self.options.prefer_local and !self.options.offline and res_constraint != null and
                    (res_constraint.? == .moonstone or res_constraint.? == .rocks)) continue;
                if (resolver_filter) |rf| {
                    if (cand.resolver) |cr| {
                        if (cr.len == 0 and !std.mem.eql(u8, rf, "moonstone")) continue;
                        if (cr.len > 0 and !std.mem.eql(u8, cr, rf)) continue;
                    } else if (!std.mem.eql(u8, rf, "moonstone")) {
                        continue;
                    }
                }
                if (res_constraint) |rc| {
                    if (rc == .link and !std.mem.eql(u8, cand.artifact_hash, "link")) continue;
                    if (rc == .path and !std.mem.eql(u8, cand.artifact_hash, "path")) continue;
                    if (rc == .artifact and (std.mem.eql(u8, cand.artifact_hash, "link") or std.mem.eql(u8, cand.artifact_hash, "path"))) continue;
                }
                if (!storeCandidateCompatible(cand, self.options)) continue;

                if (res_constraint) |_| {
                    var already_present = false;
                    for (versions.items) |v| {
                        const candidate_is_rocks = res_constraint == .rocks or
                            (if (cand.resolver) |resolver_name| std.mem.eql(u8, resolver_name, "rocks") else false);
                        const parsed_v = parseResolverVersion(cand.version, candidate_is_rocks) catch continue;
                        if (compareResolverVersion(v, parsed_v, candidate_is_rocks) == 0) {
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

                // Store entries are usable only after their manifest has been
                // committed. Prune interrupted/partial directories here so
                // dependency expansion never fails on a missing manifest.
                if (!std.mem.eql(u8, cand.artifact_hash, "link") and !std.mem.eql(u8, cand.artifact_hash, "path")) {
                    const manifest_path = try std.fs.path.join(self.allocator, &.{ cand.path, "manifest.toml" });
                    defer self.allocator.free(manifest_path);
                    std.Io.Dir.cwd().access(self.io, manifest_path, .{}) catch |err| {
                        if (err == error.FileNotFound) {
                            self.index.delete_artifact(cand.artifact_hash) catch {};
                            continue;
                        }
                        return err;
                    };
                }

                const candidate_is_rocks = res_constraint == .rocks or
                    (if (cand.resolver) |resolver_name| std.mem.eql(u8, resolver_name, "rocks") else false);
                const v = if (candidate_is_rocks)
                    try semver.Version.parseLuaRocksCloned(arena, cand.version)
                else
                    try semver.Version.parseCloned(arena, cand.version);
                if (direct_target_range) |range| {
                    local_target_satisfies_constraint = local_target_satisfies_constraint or range.contains(v);
                }
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
                    .lua_api = if (cand.lua_api) |a| try arena.dupe(u8, a) else null,
                    .runtime = if (cand.runtime) |r| try arena.dupe(u8, r) else null,
                    .runtime_artifact_hash = if (cand.runtime_artifact_hash) |h| try arena.dupe(u8, h) else "",
                    .origin = origin,
                    .location = .local_store,
                });

                try versions.append(self.allocator, v);
            }
        }

        // Prefer a local direct dependency only while it still satisfies the
        // manifest constraint. This keeps existing locks stable without
        // hiding a newer remote candidate required by a changed constraint.
        if (self.options.prefer_local and local_target_satisfies_constraint) {
            return try versions.toOwnedSlice(self.allocator);
        }

        // 3. Resolve LuaRocks packages online
        if (!self.options.offline and res_constraint != null and res_constraint.? == .rocks and self.env != null) {
            const base = self.luarocksMetadataBaseFor(reg_constraint);
            const prefetched_versions = if (self.rocks_metadata_prefetch) |prefetch|
                prefetch.findVersions(name, base, self.options.target orelse "", self.options.runtime orelse "")
            else
                null;

            const discovered_versions = if (prefetched_versions) |cached|
                cached
            else blk: {
                var opts = self.options;
                opts.lua_exe = try self.luaMetadataInterpreter();
                break :blk rocks_resolver.discoverVersions(self.allocator, self.io, name, opts, self.env.?, base) catch |err| {
                    if (err == error.PackageNotFound or err == error.FileNotFound or err == error.RocksVersionDiscoveryFailed) {
                        break :blk @as([]semver.Version, &.{});
                    }
                    return err;
                };
            };
            defer if (prefetched_versions == null) {
                for (discovered_versions) |version| version.deinit(self.allocator);
                self.allocator.free(discovered_versions);
            };

            for (discovered_versions) |version| {
                var already_present = false;
                for (versions.items) |existing| {
                    if (existing.compareLuaRocks(version) == 0) {
                        already_present = true;
                        break;
                    }
                }
                if (!already_present) try versions.append(self.allocator, try version.clone(self.allocator));
            }
        }

        // 4. Check remote registries
        if (!self.options.offline and (res_constraint == null or res_constraint.? == .moonstone)) {
            for (self.registries) |reg| {
                if (!std.mem.eql(u8, reg.resolver, "moonstone")) continue;
                if (reg_constraint) |rc| if (!std.mem.eql(u8, reg.name, rc)) continue;

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

                            try self.artifacts.append(arena, .{
                                .name = try arena.dupe(u8, pkg.name),
                                .kind = pkg.kind,
                                .artifact_hash = try arena.dupe(u8, ""),
                                .version = try arena.dupe(u8, pkg.version),
                                .registry_name = try arena.dupe(u8, reg.name),
                                .registry_url = try arena.dupe(u8, reg.url),
                                .registry_token = if (reg.token) |t| try arena.dupe(u8, t) else null,
                                .descriptor_path = try arena.dupe(u8, pkg.descriptor),
                                .artifact_idx = null,
                                .remote_desc = null,
                                .origin = .{
                                    .moonstone_registry = .{
                                        .url = try arena.dupe(u8, reg.url),
                                        .token = if (reg.token) |t| try arena.dupe(u8, t) else null,
                                        .descriptor_path = try arena.dupe(u8, pkg.descriptor),
                                        .artifact_idx = 0,
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
        const selected_target = options.target orelse blk: {
            const host = get_host_target_sync(allocator) catch return null;
            break :blk host;
        };
        defer if (options.target == null) allocator.free(selected_target);

        const allows_native = if (options.target == null) true else blk: {
            const host = get_host_target_sync(allocator) catch break :blk false;
            defer allocator.free(host);
            break :blk std.mem.eql(u8, selected_target, host);
        };

        for (desc.artifact, 0..) |art, i| {
            if (artifactMatchesRuntimeAbi(desc.package.kind, art, options) and (std.mem.eql(u8, art.target, selected_target) or std.mem.eql(u8, art.target, "any") or (allows_native and std.mem.eql(u8, art.target, "native")))) {
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
        return platform_target.hostTarget(allocator);
    }

    fn artifactMatchesRuntimeAbi(kind: manifest.Kind, art: manifest.RemoteArtifact, options: root.ResolveOptions) bool {
        // If it's a runtime artifact, it doesn't need to match the project's active ABI
        if (kind == .runtime) return true;

        // If the artifact declares its own isolated runtime, it doesn't need to match the project runtime
        if (isResolvableRuntimeSpec(art.runtime)) return true;

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
            if (!packageNamesMatch(art.name, name)) continue;
            const art_is_rocks = art.origin == .luarocks;
            const v = parseResolverVersion(art.version, art_is_rocks) catch continue;
            if (compareResolverVersion(version, v, art_is_rocks) == 0 or (art_is_rocks and !version.revision and version.compareLuaRocksUpstream(v) == 0)) {
                if (art.origin == .moonstone_registry and art.remote_desc == null) {
                    const r = art.origin.moonstone_registry;
                    var client = registry.RegistryClient.init(self.allocator, self.io, r.url, r.token, self.env);
                    defer client.deinit();
                    var desc = try client.fetch_descriptor(r.descriptor_path);
                    const selected_artifact_idx = selectArtifactForRuntime(desc, self.options) orelse continue;
                    const selected_artifact = desc.artifact[selected_artifact_idx];
                    art.artifact_idx = selected_artifact_idx;
                    art.artifact_hash = try arena.dupe(u8, selected_artifact.hash);
                    art.lua_abi = try arena.dupe(u8, selected_artifact.lua_abi);
                    art.lua_api = try arena.dupe(u8, selected_artifact.lua_api);
                    art.runtime = try arena.dupe(u8, selected_artifact.runtime);
                    art.runtime_artifact_hash = try arena.dupe(u8, selected_artifact.runtime_artifact_hash);
                    art.remote_desc = try desc.clone(arena);
                    desc.deinit(self.allocator);
                }
                artifact = art.*;
                break;
            }
        }

        // -- Metadata-only LuaRocks transitive dependency discovery -------
        // PubGrub needs rockspec dependency terms, not a materialized CAS
        // artifact. Building here makes rejected/backtracked candidates leave
        // side effects; use the normalized rockspec intent instead.
        var rocks_dependency_resolver: ?root.ResolverKind = null;
        var rocks_dependency_registry: ?[]const u8 = null;
        if (artifact) |art| switch (art.origin) {
            .luarocks => {
                rocks_dependency_resolver = .rocks;
                rocks_dependency_registry = art.registry_name;
            },
            else => {},
        };
        if (rocks_dependency_resolver == null) {
            for (self.targets) |t| {
                if (std.mem.eql(u8, t.name, name)) {
                    rocks_dependency_resolver = t.resolver;
                    rocks_dependency_registry = t.registry;
                    break;
                }
            }
        }
        if (rocks_dependency_resolver == null) {
            if (self.findStoreDependencyOrigin(name, null)) |origin| {
                rocks_dependency_resolver = origin.child_resolver;
                rocks_dependency_registry = origin.child_registry;
            }
        }

        if (rocks_dependency_resolver == .rocks and self.env != null and !self.options.offline) {
            const v_str = try version.toString(self.allocator);
            defer self.allocator.free(v_str);

            const base = self.luarocksMetadataBaseFor(rocks_dependency_registry);
            const prefetched_dependencies = if (self.rocks_metadata_prefetch) |prefetch|
                prefetch.findDependencies(name, v_str, base, self.options.target orelse "", self.options.runtime orelse "")
            else
                null;
            var loaded_dependencies: ?rocks_resolver.RockspecDependencies = null;
            defer if (loaded_dependencies) |*dependencies| dependencies.deinit(self.allocator);

            const dependencies = prefetched_dependencies orelse blk: {
                var opts = self.options;
                opts.lua_exe = try self.luaMetadataInterpreter();
                loaded_dependencies = rocks_resolver.query_dependencies(
                    self.allocator,
                    self.io,
                    name,
                    v_str,
                    opts,
                    self.env.?,
                    base,
                ) catch |err| {
                    if (err == error.PackageNotFound or err == error.RockspecNotFound or
                        err == error.FileNotFound or err == error.RocksVersionDiscoveryFailed)
                    {
                        return try terms.toOwnedSlice(self.allocator);
                    }
                    return err;
                };
                break :blk &loaded_dependencies.?;
            };

            const dependency_sets = [_]struct {
                values: []const []const u8,
                role: DependencyRole,
            }{
                .{ .values = dependencies.runtime, .role = .runtime },
                .{ .values = dependencies.build, .role = .build },
            };
            for (dependency_sets) |set| for (set.values) |dependency| {
                var parsed = try @import("../../luarocks/rockspec.zig").parse_dependency_string(self.allocator, dependency);
                defer parsed.deinit(self.allocator);
                if (std.ascii.eqlIgnoreCase(parsed.name, "lua")) continue;
                try self.store_dependency_origins.append(self.allocator, .{
                    .child_name = try self.allocator.dupe(u8, parsed.name),
                    .child_constraint = try self.allocator.dupe(u8, parsed.constraint orelse "*"),
                    .child_resolver = .rocks,
                    .child_registry = if (rocks_dependency_registry) |registry_name| try self.allocator.dupe(u8, registry_name) else null,
                    .child_role = set.role,
                    .parent_name = try self.allocator.dupe(u8, name),
                    .parent_version = try self.allocator.dupe(u8, v_str),
                    .parent_resolver = .rocks,
                    .parent_manifest_path = try self.allocator.dupe(u8, "<rockspec metadata>"),
                });

                try terms.append(self.allocator, .{
                    .name = try arena.dupe(u8, parsed.name),
                    .range = try semver.VersionRange.parseLuaRocks(arena, parsed.constraint orelse "*"),
                    .registry = if (rocks_dependency_registry) |registry_name| try arena.dupe(u8, registry_name) else null,
                    .resolver = .rocks,
                    .role = set.role,
                });
            };

            return try terms.toOwnedSlice(self.allocator);
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
                    const child_resolver = try resolverForPackageSpec(self.registries, spec);

                    // PubGrub asks for available versions by package name, so
                    // retain the resolver selected by this remote descriptor.
                    // Without this origin, a descriptor dependency such as
                    // rocks:dkjson is looked up in the Moonstone registry
                    // instead of LuaRocks.
                    try self.store_dependency_origins.append(self.allocator, .{
                        .child_name = try self.allocator.dupe(u8, spec.name),
                        .child_constraint = try self.allocator.dupe(u8, spec.constraint orelse "*"),
                        .child_resolver = child_resolver,
                        .child_registry = if (spec.registry) |registry_name| try self.allocator.dupe(u8, registry_name) else null,
                        .child_role = dep.role,
                        .parent_name = try self.allocator.dupe(u8, art.name),
                        .parent_version = try self.allocator.dupe(u8, art.version),
                        .parent_resolver = .moonstone,
                        .parent_manifest_path = try self.allocator.dupe(u8, art.descriptor_path orelse "<registry descriptor>"),
                    });

                    try terms.append(self.allocator, .{
                        .name = try arena.dupe(u8, spec.name),
                        .range = if (child_resolver == .rocks)
                            try semver.VersionRange.parseLuaRocks(arena, spec.constraint orelse "*")
                        else
                            try semver.VersionRange.parse(arena, spec.constraint orelse "*"),
                        .registry = if (spec.registry) |registry_name| try arena.dupe(u8, registry_name) else null,
                        .resolver = child_resolver,
                        .role = dep.role,
                    });
                }

                // Add runtime dependency if specified in the artifact
                if (art.artifact_idx) |idx| {
                    const selected_art = desc.artifact[idx];
                    if (isResolvableRuntimeSpec(selected_art.runtime)) {
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
                        const child_resolver = try resolverForPackageSpec(self.registries, spec);

                        var child_name = dep.name;
                        var child_constraint = dep.constraint;
                        var child_registry: ?[]const u8 = null;
                        if (spec.resolver != null or spec.registry != null) {
                            child_name = spec.name;
                            child_constraint = spec.constraint orelse "*";
                        }

                        if (child_resolver == .path) {
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
                            .child_resolver = child_resolver,
                            .child_registry = if (child_registry) |registry_name| try self.allocator.dupe(u8, registry_name) else null,
                            .child_role = dep.role,
                            .parent_name = try self.allocator.dupe(u8, art.name),
                            .parent_version = try self.allocator.dupe(u8, art.version),
                            .parent_resolver = if (std.mem.eql(u8, art.artifact_hash, "link")) .link else .path,
                            .parent_manifest_path = try self.allocator.dupe(u8, manifest_path),
                        });

                        try terms.append(self.allocator, .{
                            .name = try arena.dupe(u8, child_name),
                            .range = if (child_resolver == .rocks)
                                try semver.VersionRange.parseLuaRocks(arena, child_constraint)
                            else
                                try semver.VersionRange.parse(arena, child_constraint),
                            .registry = if (child_registry) |registry_name| try arena.dupe(u8, registry_name) else null,
                            .resolver = child_resolver,
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

                    if (isResolvableRuntimeSpec(sm.compat.runtime_version)) {
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
                            .range = if (dep_resolver == .rocks)
                                try semver.VersionRange.parseLuaRocks(arena, dep.constraint)
                            else
                                try semver.VersionRange.parse(arena, dep.constraint),
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

fn parseResolverVersion(text: []const u8, is_rocks: bool) !semver.Version {
    return if (is_rocks) semver.Version.parseLuaRocks(text) else semver.Version.parse(text);
}

fn compareResolverVersion(left: semver.Version, right: semver.Version, is_rocks: bool) i8 {
    return if (is_rocks) left.compareLuaRocks(right) else left.compare(right);
}

fn packageNamesMatch(index_name: []const u8, requested_name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(index_name, requested_name)) return true;

    const canonical_req = if (std.mem.eql(u8, requested_name, "lua")) @as([]const u8, "moonstone/lua") else if (std.mem.eql(u8, requested_name, "luajit")) @as([]const u8, "moonstone/luajit") else if (std.mem.eql(u8, requested_name, "love")) @as([]const u8, "moonstone/love") else requested_name;

    const canonical_idx = if (std.mem.eql(u8, index_name, "lua")) @as([]const u8, "moonstone/lua") else if (std.mem.eql(u8, index_name, "luajit")) @as([]const u8, "moonstone/luajit") else if (std.mem.eql(u8, index_name, "love")) @as([]const u8, "moonstone/love") else index_name;

    return std.mem.eql(u8, canonical_idx, canonical_req);
}

fn resolverKindToStoreString(kind: ?root.ResolverKind) ?[]const u8 {
    const resolved = kind orelse return null;
    return switch (resolved) {
        .moonstone => "moonstone",
        .rocks => "rocks",
        .artifact => null,
        .path => null,
        .link => null,
    };
}

fn storeQueryForName(name: []const u8, resolver: ?[]const u8, target: ?[]const u8) driver_mod.ArtifactQuery {
    return .{
        .name = name,
        .case_insensitive_name = if (resolver) |r| std.mem.eql(u8, r, "rocks") else false,
        .resolver = resolver,
        .target = target,
    };
}

fn storeCandidateCompatible(candidate: driver_mod.Candidate, options: root.ResolveOptions) bool {
    if (options.runtime) |active_abi| {
        if (candidate.kind != .runtime) {
            const has_isolated_runtime = if (candidate.runtime) |runtime| runtime.len > 0 else false;
            if (!has_isolated_runtime) {
                if (candidate.lua_abi) |candidate_abi| {
                    if (!root.options.runtimeAbiMatches(active_abi, candidate_abi)) return false;
                }
            }
        }
    }

    if (candidate.runtime_artifact_hash) |runtime_artifact_hash| {
        if (runtime_artifact_hash.len > 0) {
            if (options.runtime_artifact_hash) |expected_runtime_artifact_hash| {
                if (!std.mem.eql(u8, runtime_artifact_hash, expected_runtime_artifact_hash)) return false;
            }
        }
    }

    return true;
}

fn isResolvableRuntimeSpec(runtime_spec: []const u8) bool {
    if (runtime_spec.len == 0) return false;
    if (std.mem.eql(u8, runtime_spec, "lua@unknown")) return false;
    if (std.mem.startsWith(u8, runtime_spec, "table:")) return false;
    return true;
}

fn resolverForPackageSpec(registries: []const registry.ResolvedRegistry, spec: package_spec.PackageSpec) !?root.ResolverKind {
    if (spec.resolver) |resolver_kind| return resolver_kind;

    const identity = spec.registry orelse return null;
    if (std.mem.eql(u8, identity, "moonstone")) return .moonstone;
    if (std.mem.eql(u8, identity, "rocks")) return .rocks;

    for (registries) |reg| {
        if (std.mem.eql(u8, reg.name, identity)) {
            return try root.ResolverKind.fromString(reg.resolver);
        }
    }
    return error.RegistryNotFound;
}

test "resolverForPackageSpec maps built-in registry namespaces" {
    const allocator = std.testing.allocator;
    const rocks_spec = try package_spec.parsePackageSpec(allocator, "rocks:dkjson@^2.9-1");
    defer rocks_spec.deinit(allocator);
    const moonstone_spec = try package_spec.parsePackageSpec(allocator, "moonstone/ballad@^0.2.41");
    defer moonstone_spec.deinit(allocator);

    try std.testing.expectEqual(root.ResolverKind.rocks, (try resolverForPackageSpec(&.{}, rocks_spec)).?);
    try std.testing.expectEqual(@as(?root.ResolverKind, null), try resolverForPackageSpec(&.{}, moonstone_spec));
}

fn candidateHasMalformedRuntimeMetadata(candidate: driver_mod.Candidate) bool {
    if (candidate.kind == .runtime) return false;
    if (candidate.runtime) |runtime| {
        if (std.mem.startsWith(u8, runtime, "table:")) return true;
    }
    return false;
}
