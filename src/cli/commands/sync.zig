const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const sync_command = SyncCommand;

fn solutionContainsPackage(solution: *const std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact), name: []const u8) bool {
    for (solution.keys()) |candidate_name| {
        if (std.ascii.eqlIgnoreCase(candidate_name, name)) return true;
    }
    return false;
}

fn solutionFetchSwapRemovePackage(solution: *std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact), name: []const u8) ?std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).KV {
    for (solution.keys()) |candidate_name| {
        if (std.ascii.eqlIgnoreCase(candidate_name, name)) return solution.fetchSwapRemove(candidate_name);
    }
    return null;
}
fn projectedArtifactFromPkg(
    allocator: std.mem.Allocator,
    mt: *const moonstone.domain.manifest.MoonstoneToml,
    pkg: *const moonstone.resolution.candidate.ResolvedArtifact,
    art_path: ?[]const u8,
    artifact_hash: []const u8,
    role: moonstone.domain.manifest.DependencyRole,
) !moonstone.project.linker.ProjectedArtifact {
    var constraint: []const u8 = &.{};
    var resolver: ?[]const u8 = null;
    for (mt.dependencies.items) |dep| {
        if (std.mem.eql(u8, dep.name, pkg.name)) {
            constraint = try allocator.dupe(u8, dep.constraint);
            if (dep.resolver) |r| resolver = try allocator.dupe(u8, r);
            break;
        }
    }
    const pa_path = if (art_path) |p| try allocator.dupe(u8, p) else null;
    return .{
        .name = try allocator.dupe(u8, pkg.name),
        .version = try allocator.dupe(u8, pkg.version),
        .constraint = constraint,
        .resolver = resolver,
        .role = role,
        .artifact_hash = try allocator.dupe(u8, artifact_hash),
        .lua_abi = if (pkg.lua_abi) |abi| try allocator.dupe(u8, abi) else null,
        .lua_api = if (pkg.lua_api) |api| try allocator.dupe(u8, api) else null,
        .target = try allocator.dupe(u8, "native"),
        .path = pa_path,
    };
}

const SyncReport = struct {
    requested_targets: usize = 0,
    resolved_packages: usize = 0,
    store_hits: usize = 0,
    downloads: usize = 0,
    materializations: usize = 0,
    path_link_projections: usize = 0,
    linked: usize = 0,
    env_refreshed: bool = false,
    resolve_ms: i128 = 0,
    materialize_ms: i128 = 0,
    link_ms: i128 = 0,
    total_ms: i128 = 0,
};

const JsonStderrSilencer = struct {
    io: std.Io,
    saved_fd: ?std.posix.fd_t = null,
    devnull_fd: ?std.posix.fd_t = null,

    pub fn init(io: std.Io, enabled: bool) !JsonStderrSilencer {
        var self = JsonStderrSilencer{ .io = io };
        if (!enabled) return self;

        const saved = std.c.dup(std.posix.STDERR_FILENO);
        if (saved < 0) return error.StderrRedirectFailed;
        self.saved_fd = @intCast(saved);

        const devnull = std.posix.openatZ(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch |err| {
            self.closeFd(self.saved_fd.?);
            self.saved_fd = null;
            return err;
        };
        self.devnull_fd = devnull;

        if (std.c.dup2(devnull, std.posix.STDERR_FILENO) < 0) {
            self.closeFd(devnull);
            self.closeFd(self.saved_fd.?);
            self.devnull_fd = null;
            self.saved_fd = null;
            return error.StderrRedirectFailed;
        }

        return self;
    }

    pub fn deinit(self: *JsonStderrSilencer) void {
        if (self.saved_fd) |fd| {
            _ = std.c.dup2(fd, std.posix.STDERR_FILENO);
            self.closeFd(fd);
            self.saved_fd = null;
        }
        if (self.devnull_fd) |fd| {
            self.closeFd(fd);
            self.devnull_fd = null;
        }
    }

    fn closeFd(self: JsonStderrSilencer, fd: std.posix.fd_t) void {
        const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
        file.close(self.io);
    }
};

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

fn elapsedMs(io: std.Io, start_ns: i128) i128 {
    return @divFloor(nowNs(io) - start_ns, std.time.ns_per_ms);
}

pub const SyncCommand = struct {
    pub const name = "sync";
    pub const description = "Synchronize the current project environment";

    positionals: []const []const u8 = &.{},
    locked: bool = false,
    check: bool = false,
    offline: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon sync [flags]
            \\
            \\Synchronizes the project environment with moonstone.toml and moonstone.lock.
            \\
            \\Flags:
            \\  --locked     Error if moonstone.lock is out of sync
            \\  --check      Validate lockfile/env without modifying files
            \\  --offline    Do not connect to remote registries
            \\
        , .{});
    }

    pub fn run(self: SyncCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;
        const started_ns = nowNs(io);

        var stderr_silencer = try JsonStderrSilencer.init(io, self.json);
        defer stderr_silencer.deinit();

        var report = SyncReport{};
        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| if (!self.check) {
            try e.emit(io, .START, name, "sync.begin", .{
                .locked = self.locked,
                .offline = self.offline,
            });
        };

        const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
        defer project_root.deinit(allocator);

        const mt_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return error.NoProjectFound;
            return err;
        };
        defer allocator.free(mt_content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, mt_content);
        defer mt.deinit(allocator);

        if (mt.runtimeName().len == 0) {
            ctx.error_detail = .{ .message = .{ .msg = "moonstone.toml is missing [runtime]. Run `moon use lua@5.4` or `moon use luajit@2.1` to select one." } };
            return error.MissingRuntime;
        }

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        if (self.locked) {
            const lock_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.lock", allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) return error.LockfileOutOfSync;
                return err;
            };
            defer allocator.free(lock_content);

            var locked_preflight = try moonstone.domain.lockfile.LockFile.parse(allocator, lock_content);
            defer locked_preflight.deinit();

            if (!lockedDependenciesMatch(mt.dependencies.items, &locked_preflight)) return error.LockfileOutOfSync;
        }

        if (self.check) {
            return try self.runCheck(ctx, &mt, &idx);
        }

        const registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        defer moonstone.registry.core.deinitResolved(registries, allocator);

        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
        };

        // 1. Determine active runtime
        const resolve_started_ns = nowNs(io);
        const pkg_name = moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName());
        const pkg_ver = mt.runtimeConstraint();

        var coordinator = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
        var rt_res = try coordinator.resolve(pkg_name, pkg_ver, idx, registries, .{
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
            .offline = self.offline,
        }, env);
        defer rt_res.deinit(allocator);
        const active_lua_abi = mt.runtimeAbi();

        if (emitter) |e| {
            try e.emit(io, .STATUS, rt_res.name, "runtime.resolved", .{
                .name = rt_res.name,
                .version = rt_res.version,
            });
        } else {
            try stdout.print("Using runtime: {s}@{s}\n", .{ rt_res.name, rt_res.version });
        }

        var mat = moonstone.materialization.materializer.Materializer{
            .allocator = allocator,
            .io = io,
            .environ_map = env,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        };

        const rt_mat_res = switch (rt_res.location) {
            .local_store, .local_path => moonstone.materialization.materializer.MaterializeResult{
                .path = try allocator.dupe(u8, rt_res.local_path.?),
                .artifact_hash = try allocator.dupe(u8, rt_res.artifact_hash),
            },
            .remote => switch (rt_res.origin) {
                .moonstone_registry => |r| try mat.materialize_remote(
                    r.url,
                    r.token,
                    r.descriptor_path,
                    rt_res.remote_desc.?,
                    r.artifact_idx,
                ),
                else => return error.UnsupportedOriginForRuntime,
            },
        };
        defer rt_mat_res.deinit(allocator);
        switch (rt_res.location) {
            .local_path => report.path_link_projections += 1,
            .local_store => report.store_hits += 1,
            .remote => switch (rt_res.origin) {
                .moonstone_registry => {
                    report.downloads += 1;
                    report.materializations += 1;
                },
                else => {},
            },
        }

        mat.runtime_path = rt_mat_res.path;

        const rt_recipe_options = moonstone.store.facade.RecipeOptions{
            .kind = @tagName(rt_res.kind),
            .name = rt_res.name,
            .version = rt_res.version,
            .source_hash = if (rt_res.remote_desc) |rd| rd.artifact[rt_res.artifact_idx orelse 0].hash else "",
            .materializer = if (rt_res.remote_desc) |rd| (if (rd.artifact[0].materialize) |m| m.kind else "prebuilt") else "prebuilt",
            .strategy = if (rt_res.remote_desc) |rd| (if (rd.artifact[0].materialize) |m| m.strategy orelse "default" else "local") else "local",
            .lua_abi = active_lua_abi,
            .target = "native",
        };

        const rt_recipe_hash = try moonstone.store.facade.computeRecipeHash(allocator, rt_recipe_options);
        defer allocator.free(rt_recipe_hash);

        // 2. Solve dependencies
        var targets = std.ArrayList(moonstone.resolution.solver.term.Term).empty;
        defer {
            for (targets.items) |t| {
                var mut_t = t;
                mut_t.deinit(allocator);
            }
            targets.deinit(allocator);
        }

        // Add runtime to targets
        try targets.append(allocator, .{
            .name = try allocator.dupe(u8, rt_res.name),
            .range = try moonstone.domain.semver.VersionRange.parse(allocator, rt_res.version),
            .resolver = .moonstone,
        });

        // Add explicit dependencies
        for (mt.dependencies.items) |dep| {
            const raw_spec = try dep.toSpecString(allocator);
            defer allocator.free(raw_spec);
            const spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, raw_spec);
            defer spec.deinit(allocator);

            try targets.append(allocator, .{
                .name = try allocator.dupe(u8, if (spec.resolver == .rocks) spec.name else dep.name),
                .range = try moonstone.domain.semver.VersionRange.parse(allocator, spec.constraint orelse "*"),
                .resolver = spec.resolver,
                .registry = if (spec.registry) |r| try allocator.dupe(u8, r) else if (spec.resolver == .path) try allocator.dupe(u8, spec.name) else null,
                .role = dep.role,
            });
        }

        var provider_impl = try allocator.create(moonstone.resolution.provider.graph_provider.RegistryProvider);
        provider_impl.init(allocator, io, idx, registries, .{
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
            .offline = self.offline,
            .runtime = active_lua_abi,
            .runtime_artifact_hash = rt_res.artifact_hash,
            .runtime_path = rt_mat_res.path,
        }, env, null, targets.items);
        defer {
            provider_impl.deinit();
            allocator.destroy(provider_impl);
        }

        // Add runtime artifact to provider to keep it pinned
        {
            const arena = provider_impl.arena.allocator();
            try provider_impl.artifacts.append(arena, .{
                .name = try arena.dupe(u8, rt_res.name),
                .kind = rt_res.kind,
                .artifact_hash = try arena.dupe(u8, rt_mat_res.artifact_hash),
                .version = try arena.dupe(u8, rt_res.version),
                .local_path = try arena.dupe(u8, rt_mat_res.path),
                .origin = try rt_res.origin.clone(arena),
                .remote_desc = if (rt_res.remote_desc) |rd| try rd.clone(arena) else null,
            });
        }

        // Read lockfile early so --locked can bypass the solver
        var existing_lock = blk: {
            const lock_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.lock", allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) break :blk moonstone.domain.lockfile.LockFile.init(allocator);
                return err;
            };
            defer allocator.free(lock_content);
            break :blk try moonstone.domain.lockfile.LockFile.parse(allocator, lock_content);
        };
        defer existing_lock.deinit();

        var solution: std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact) = .empty;
        defer {
            var sit = solution.iterator();
            while (sit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            solution.deinit(allocator);
        }

        if (self.locked) {
            // Lockfile replay mode: bypass PubGrub and retrieve exact artifacts by hash
            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.locked_replay", .{ .packages = existing_lock.packages.items.len });
            } else {
                try stdout.print("Replaying lockfile...\n", .{});
            }

            for (existing_lock.packages.items) |entry| {
                const is_link = std.mem.eql(u8, entry.artifact_hash, "link");
                const is_path = std.mem.eql(u8, entry.artifact_hash, "path");

                if (is_link or is_path) {
                    // Link/path entries are reconstructed directly from lockfile metadata
                    const source_path = if (entry.source.len > 0) entry.source else "";
                    const candidate = moonstone.resolution.candidate.Candidate{
                        .name = try allocator.dupe(u8, entry.name),
                        .version = try allocator.dupe(u8, entry.version),
                        .kind = entry.kind,
                        .artifact_hash = try allocator.dupe(u8, entry.artifact_hash),
                        .lua_abi = if (entry.lua_abi.len > 0) try allocator.dupe(u8, entry.lua_abi) else null,
                        .local_path = if (source_path.len > 0) try allocator.dupe(u8, source_path) else null,
                        .origin = if (is_link)
                            .{ .link = try allocator.dupe(u8, source_path) }
                        else
                            .{ .path = try allocator.dupe(u8, source_path) },
                        .location = .{ .local_path = try allocator.dupe(u8, source_path) },
                    };
                    try solution.put(allocator, try allocator.dupe(u8, entry.name), candidate);
                    continue;
                }

                const resolver_kind: ?moonstone.resolution.coordinator.CoordinatorKind = if (entry.resolver.len > 0)
                    moonstone.resolution.coordinator.CoordinatorKind.fromString(entry.resolver) catch null
                else
                    null;

                const req = moonstone.resolution.provider.package_provider.ArtifactRequest{
                    .name = entry.name,
                    .version = entry.version,
                    .resolver = resolver_kind,
                    .artifact_hash = if (entry.artifact_hash.len > 0) entry.artifact_hash else null,
                    .runtime = if (entry.runtime.len > 0) entry.runtime else null,
                    .lua_abi = if (entry.lua_abi.len > 0) entry.lua_abi else null,
                    .runtime_artifact_hash = if (entry.recipe_hash.len > 0) entry.recipe_hash else null,
                };

                const maybe_art = try provider_impl.get_artifact(req);
                const art = maybe_art orelse {
                    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                    ctx.error_detail = .{
                        .locked_artifact_missing = .{
                            .name = try ctx.allocator.dupe(u8, entry.name),
                            .version = try ctx.allocator.dupe(u8, entry.version),
                            .resolver = if (entry.resolver.len > 0) try ctx.allocator.dupe(u8, entry.resolver) else null,
                            .artifact_hash = try ctx.allocator.dupe(u8, entry.artifact_hash),
                        },
                    };
                    return error.LockedArtifactMissing;
                };
                errdefer art.deinit(allocator);

                try solution.put(allocator, try allocator.dupe(u8, entry.name), try art.clone(allocator));
            }

            report.requested_targets = existing_lock.packages.items.len;
            report.resolved_packages = solution.count();
            report.resolve_ms = elapsedMs(io, resolve_started_ns);
            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.complete", .{
                    .requested_targets = report.requested_targets,
                    .resolved_packages = report.resolved_packages,
                    .elapsed_ms = report.resolve_ms,
                });
            }
        } else {
            var solver = moonstone.resolution.solver.pubgrub.Solver.init(allocator, provider_impl.get_provider(), .{});
            defer solver.deinit();

            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.begin", .{ .targets = targets.items.len });
            } else {
                try stdout.print("Solving dependencies...\n", .{});
            }
            solution = solver.solve(targets.items) catch |err| blk: {
                if (err == error.ArtifactNotFound) break :blk std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).empty;
                if (err == error.NoSolution) {
                    if (provider_impl.offline_diagnostic) |diag| {
                        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                        ctx.error_detail = .{
                            .offline_transitive_missing = .{
                                .child_name = try ctx.allocator.dupe(u8, diag.child_name),
                                .child_resolver = if (diag.child_resolver) |r|
                                    try ctx.allocator.dupe(u8, r.asString())
                                else
                                    null,
                                .child_constraint = try ctx.allocator.dupe(u8, diag.child_constraint),
                                .parent_name = try ctx.allocator.dupe(u8, diag.parent_name),
                                .parent_version = try ctx.allocator.dupe(u8, diag.parent_version),
                                .parent_resolver = if (diag.parent_resolver) |r|
                                    try ctx.allocator.dupe(u8, r.asString())
                                else
                                    null,
                                .parent_manifest_path = try ctx.allocator.dupe(u8, diag.parent_manifest_path),
                            },
                        };
                        return error.OfflineTransitiveArtifactMissing;
                    }
                    if (!self.json) try stdout.print("Error: No solution found for dependencies.\n", .{});
                    return err;
                }
                if (err == error.LinkedRuntimeAbiMismatch) {
                    if (provider_impl.linked_runtime_diagnostic) |diag| {
                        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                        ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}", .{ diag.package_name, diag.package_version, diag.required_abi, diag.active_abi, diag.manifest_path }) } };
                    }
                }
                return err;
            };
            for (mt.dependencies.items) |dep| {
                const raw_spec = try dep.toSpecString(allocator);
                defer allocator.free(raw_spec);
                const spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, raw_spec);
                defer spec.deinit(allocator);

                const dep_name = if (spec.resolver == .rocks) spec.name else dep.name;

                const force_direct = spec.resolver != null or spec.registry != null;
                if (solutionContainsPackage(&solution, dep_name) and !force_direct) continue;

                var direct_kinds_buf: [4]moonstone.resolution.coordinator.CoordinatorKind = undefined;
                var direct_kinds_len: usize = 0;
                if (spec.resolver) |resolver_kind| {
                    direct_kinds_buf[direct_kinds_len] = resolver_kind;
                    direct_kinds_len += 1;
                } else {
                    const default_order = if (mt.resolution) |r| r.default_order else @as([]const []const u8, &[_][]const u8{ "moonstone", "rocks" });
                    for (default_order) |r_name| {
                        if (moonstone.resolution.coordinator.CoordinatorKind.fromString(r_name)) |kind| {
                            direct_kinds_buf[direct_kinds_len] = kind;
                            direct_kinds_len += 1;
                        } else |_| continue;
                    }
                }

                var resolved_direct_opt: ?moonstone.resolution.candidate.ResolvedArtifact = null;
                const resolver_query_name = if (spec.resolver) |resolver_kind| switch (resolver_kind) {
                    .path, .link, .artifact => spec.name,
                    else => dep_name,
                } else dep_name;
                for (direct_kinds_buf[0..direct_kinds_len]) |kind| {
                    resolved_direct_opt = coordinator.resolveWithKind(resolver_query_name, spec.constraint orelse "*", idx, registries, .{
                        .offline = self.offline,
                        .runtime = active_lua_abi,
                        .runtime_artifact_hash = rt_res.artifact_hash,
                        .runtime_path = rt_mat_res.path,
                        .on_event = @import("command.zig").onResolveEvent,
                        .on_event_context = &resolve_cb_ctx,
                    }, kind, env) catch |err| {
                        if (err == error.PackageNotFound or err == error.FileNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
                        return err;
                    };
                    if (resolved_direct_opt != null) break;
                }
                if (resolved_direct_opt == null) {
                    if (spec.registry) |registry_name| {
                        for (registries) |reg| {
                            if (!std.mem.eql(u8, reg.name, registry_name)) continue;
                            const remote = coordinator.resolve_remote(dep_name, spec.constraint orelse "*", reg.url, reg.token, .{
                                .offline = self.offline,
                                .runtime = active_lua_abi,
                                .runtime_artifact_hash = rt_res.artifact_hash,
                                .runtime_path = rt_mat_res.path,
                                .on_event = @import("command.zig").onResolveEvent,
                                .on_event_context = &resolve_cb_ctx,
                            }, env) catch continue;
                            resolved_direct_opt = .{
                                .name = try allocator.dupe(u8, dep_name),
                                .version = try allocator.dupe(u8, remote.desc.package.version),
                                .kind = remote.desc.package.kind,
                                .artifact_hash = try allocator.dupe(u8, remote.desc.artifact[remote.artifact_idx].hash),
                                .lua_abi = try allocator.dupe(u8, remote.desc.artifact[remote.artifact_idx].lua_abi),
                                .remote_desc = remote.desc,
                                .registry_url = try allocator.dupe(u8, reg.url),
                                .registry_token = if (reg.token) |t| try allocator.dupe(u8, t) else null,
                                .descriptor_path = remote.descriptor_path,
                                .artifact_idx = remote.artifact_idx,
                                .origin = .{ .moonstone_registry = .{
                                    .url = try allocator.dupe(u8, reg.url),
                                    .token = if (reg.token) |t| try allocator.dupe(u8, t) else null,
                                    .descriptor_path = try allocator.dupe(u8, remote.descriptor_path),
                                    .artifact_idx = remote.artifact_idx,
                                } },
                            };
                            break;
                        }
                    }
                }
                var resolved_direct = resolved_direct_opt orelse {
                    if (spec.resolver) |resolver_kind| switch (resolver_kind) {
                        .path, .link, .artifact => if (solutionContainsPackage(&solution, dep_name)) continue,
                        else => {},
                    };
                    return error.PackageNotFound;
                };
                errdefer resolved_direct.deinit(allocator);

                if (solutionFetchSwapRemovePackage(&solution, dep_name)) |old| {
                    allocator.free(old.key);
                    old.value.deinit(allocator);
                }
                try solution.put(allocator, try allocator.dupe(u8, dep_name), resolved_direct);
            }

            report.requested_targets = targets.items.len;
            report.resolved_packages = solution.count();
            report.resolve_ms = elapsedMs(io, resolve_started_ns);
            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.complete", .{
                    .requested_targets = report.requested_targets,
                    .resolved_packages = report.resolved_packages,
                    .elapsed_ms = report.resolve_ms,
                });
            }
        }
        report.requested_targets = targets.items.len;
        report.resolved_packages = solution.count();
        report.resolve_ms = elapsedMs(io, resolve_started_ns);
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "resolution.complete", .{
                .requested_targets = report.requested_targets,
                .resolved_packages = report.resolved_packages,
                .elapsed_ms = report.resolve_ms,
            });
        }

        // Compute dependency groups for each resolved package
        var package_roles = std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)).empty;
        defer {
            var git = package_roles.iterator();
            while (git.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |g| allocator.free(g);
                entry.value_ptr.deinit(allocator);
            }
            package_roles.deinit(allocator);
        }

        const GroupCtx = struct {
            allocator: std.mem.Allocator,
            groups: *std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)),

            fn addGroup(gctx: *@This(), grp_pkg_name: []const u8, group: []const u8) !void {
                const gop = try gctx.groups.getOrPut(gctx.allocator, grp_pkg_name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try gctx.allocator.dupe(u8, grp_pkg_name);
                    gop.value_ptr.* = std.ArrayList([]const u8).empty;
                }
                for (gop.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing, group)) return;
                }
                try gop.value_ptr.append(gctx.allocator, try gctx.allocator.dupe(u8, group));
            }
        };

        var group_ctx = GroupCtx{ .allocator = allocator, .groups = &package_roles };

        // Step 1: Mark direct root dependencies
        for (mt.dependencies.items) |dep| {
            const raw_spec = try dep.toSpecString(allocator);
            defer allocator.free(raw_spec);
            const spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, raw_spec);
            defer spec.deinit(allocator);
            const dep_pkg_name = if (spec.resolver == .rocks) spec.name else dep.name;
            const group_name = @tagName(dep.role);
            try group_ctx.addGroup(dep_pkg_name, group_name);
        }

        // Step 2: Build dependency graph from resolved packages
        var dep_graph = std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)).empty;
        defer {
            var dit = dep_graph.iterator();
            while (dit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |d| allocator.free(d);
                entry.value_ptr.deinit(allocator);
            }
            dep_graph.deinit(allocator);
        }

        {
            var sol_it = solution.iterator();
            while (sol_it.next()) |entry| {
                const sol_pkg_name = entry.key_ptr.*;
                const pkg = entry.value_ptr.*;

                const deps = deps_blk: {
                    var deps = std.ArrayList([]const u8).empty;
                    errdefer {
                        for (deps.items) |d| allocator.free(d);
                        deps.deinit(allocator);
                    }

                    if (pkg.remote_desc) |desc| {
                        for (desc.dependencies) |dep| {
                            const dep_name = dep.name;
                            try deps.append(allocator, try allocator.dupe(u8, dep_name));
                        }
                    } else if (pkg.local_path) |lp| {
                        if (std.mem.eql(u8, pkg.artifact_hash, "link") or std.mem.eql(u8, pkg.artifact_hash, "path")) {
                            const manifest_path = try std.fs.path.join(allocator, &.{ lp, "moonstone.toml" });
                            defer allocator.free(manifest_path);
                            var content: ?[]const u8 = null;
                            if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
                                content = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
                            } else |err| {
                                if (err != error.FileNotFound) return err;
                            }
                            if (content) |c| {
                                defer allocator.free(c);
                                var lmt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, c);
                                defer lmt.deinit(allocator);
                                for (lmt.dependencies.items) |dep| {
                                    const raw_spec = try dep.toSpecString(allocator);
                                    defer allocator.free(raw_spec);
                                    const dspec = try moonstone.domain.package_spec.parsePackageSpec(allocator, raw_spec);
                                    defer dspec.deinit(allocator);
                                    const dname = if (dspec.resolver == .rocks) dspec.name else dep.name;
                                    try deps.append(allocator, try allocator.dupe(u8, dname));
                                }
                            }
                        } else {
                            const manifest_path = try std.fs.path.join(allocator, &.{ lp, "manifest.toml" });
                            defer allocator.free(manifest_path);
                            var content: ?[]const u8 = null;
                            if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
                                content = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
                            } else |err| {
                                if (err != error.FileNotFound) return err;
                            }
                            if (content) |c| {
                                defer allocator.free(c);
                                var sm = try moonstone.domain.manifest.StoreManifest.parse(allocator, c);
                                defer sm.deinit(allocator);
                                for (sm.dependencies) |dep| {
                                    try deps.append(allocator, try allocator.dupe(u8, dep.name));
                                }
                            }
                        }
                    }
                    break :deps_blk deps;
                };

                const gop = try dep_graph.getOrPut(allocator, sol_pkg_name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try allocator.dupe(u8, sol_pkg_name);
                }
                gop.value_ptr.* = deps;
            }
        }

        // Step 3: Propagate groups via BFS
        {
            var queue = std.ArrayList(struct { name: []const u8, group: []const u8 }).empty;
            defer {
                for (queue.items) |item| {
                    allocator.free(item.name);
                    allocator.free(item.group);
                }
                queue.deinit(allocator);
            }

            var rgit = package_roles.iterator();
            while (rgit.next()) |entry| {
                for (entry.value_ptr.items) |g| {
                    try queue.append(allocator, .{
                        .name = try allocator.dupe(u8, entry.key_ptr.*),
                        .group = try allocator.dupe(u8, g),
                    });
                }
            }

            var visited = std.StringArrayHashMapUnmanaged(void).empty;
            defer {
                var vit = visited.iterator();
                while (vit.next()) |ventry| allocator.free(ventry.key_ptr.*);
                visited.deinit(allocator);
            }

            while (queue.items.len > 0) {
                const current = queue.swapRemove(0);
                defer {
                    allocator.free(current.name);
                    allocator.free(current.group);
                }

                const vkey = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ current.name, current.group });
                defer allocator.free(vkey);
                if (visited.contains(vkey)) continue;
                try visited.put(allocator, try allocator.dupe(u8, vkey), {});

                try group_ctx.addGroup(current.name, current.group);

                if (dep_graph.get(current.name)) |children| {
                    for (children.items) |child| {
                        try queue.append(allocator, .{
                            .name = try allocator.dupe(u8, child),
                            .group = try allocator.dupe(u8, current.group),
                        });
                    }
                }
            }
        }

        // 3. Materialize all chosen artifacts
        const materialize_started_ns = nowNs(io);
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "materialization.begin", .{ .packages = report.resolved_packages });
        }
        var live_links = std.ArrayList(moonstone.project.linker.LiveLink).empty;
        defer {
            for (live_links.items) |ll| {
                allocator.free(ll.name);
                allocator.free(ll.source_path);
                allocator.free(ll.mode);
                allocator.free(ll.pkg_name);
                allocator.free(ll.pkg_version);
            }
            live_links.deinit(allocator);
        }

        var projected_artifacts = std.ArrayList(moonstone.project.linker.ProjectedArtifact).empty;
        defer {
            for (projected_artifacts.items) |pa| {
                allocator.free(pa.name);
                allocator.free(pa.version);
                allocator.free(pa.constraint);
                if (pa.resolver) |r| allocator.free(r);
                allocator.free(pa.artifact_hash);
                if (pa.lua_abi) |a| allocator.free(a);
                if (pa.lua_api) |a| allocator.free(a);
                if (pa.target) |t| allocator.free(t);
                if (pa.path) |p| allocator.free(p);
            }
            projected_artifacts.deinit(allocator);
        }

        const is_rt_live = std.mem.eql(u8, rt_mat_res.artifact_hash, "link") or std.mem.eql(u8, rt_mat_res.artifact_hash, "path");
        if (is_rt_live) {
            try live_links.append(allocator, .{
                .name = try allocator.dupe(u8, rt_res.name),
                .source_path = try allocator.dupe(u8, rt_mat_res.path),
                .mode = try allocator.dupe(u8, if (std.mem.eql(u8, rt_mat_res.artifact_hash, "link")) "link" else "path"),
                .pkg_name = try allocator.dupe(u8, rt_res.name),
                .pkg_version = try allocator.dupe(u8, rt_res.version),
                .pkg_kind = .runtime,
            });
        } else {
            try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &rt_res, rt_mat_res.path, rt_mat_res.artifact_hash, .runtime));
        }

        var next_lock = moonstone.domain.lockfile.LockFile.init(allocator);
        defer next_lock.deinit();

        var sit = solution.iterator();
        while (sit.next()) |entry| {
            const pkg_name_sol = entry.key_ptr.*;
            const pkg = entry.value_ptr.*;

            if (pkg.local_path) |lp| {
                // If it's a link or path, handle it separately
                const is_link = std.mem.eql(u8, pkg.artifact_hash, "link");
                const is_path = std.mem.eql(u8, pkg.artifact_hash, "path");

                if (is_link or is_path) {
                    try live_links.append(allocator, .{
                        .name = try allocator.dupe(u8, pkg_name_sol),
                        .source_path = try allocator.dupe(u8, lp),
                        .mode = try allocator.dupe(u8, if (is_link) "link" else "path"),
                        .pkg_name = try allocator.dupe(u8, pkg.name),
                        .pkg_version = try allocator.dupe(u8, pkg.version),
                        .pkg_kind = pkg.kind,
                    });
                    report.path_link_projections += 1;
                    continue;
                }

                if (pkg.artifact_hash.len > 0) {
                    if (std.mem.eql(u8, pkg.name, rt_res.name)) {
                        continue;
                    } else if (self.locked) {
                        const lock_entry = existing_lock.find(pkg.name) orelse return error.LockfileOutOfSync;
                        if (!std.mem.eql(u8, lock_entry.version, pkg.version)) return error.LockfileOutOfSync;
                        if (!std.mem.eql(u8, lock_entry.artifact_hash, pkg.artifact_hash)) return error.LockfileOutOfSync;
                    } else {
                        const recipe_hash = if (pkg.remote_desc) |rd| rd.artifact[pkg.artifact_idx orelse 0].recipe_hash else "";
                        var entry_roles = std.ArrayList([]const u8).empty;
                        defer {
                            for (entry_roles.items) |g| allocator.free(g);
                            entry_roles.deinit(allocator);
                        }
                        if (package_roles.get(pkg.name)) |glist| {
                            for (glist.items) |g| {
                                try entry_roles.append(allocator, try allocator.dupe(u8, g));
                            }
                        }
                        try next_lock.packages.append(allocator, .{
                            .name = try allocator.dupe(u8, pkg.name),
                            .version = try allocator.dupe(u8, pkg.version),
                            .kind = pkg.kind,
                            .source_hash = &.{},
                            .recipe_hash = try allocator.dupe(u8, recipe_hash),
                            .artifact_hash = try allocator.dupe(u8, pkg.artifact_hash),
                            .runtime = try allocator.dupe(u8, active_lua_abi),
                            .lua_abi = try allocator.dupe(u8, pkg.lua_abi orelse active_lua_abi),
                            .target = try allocator.dupe(u8, "native"),
                            .constellation = try allocator.dupe(u8, "default"),
                            .resolver = try allocator.dupe(u8, switch (pkg.origin) {
                                .luarocks => "rocks",
                                .moonstone_registry => "moonstone",
                                .link => "link",
                                .path => "path",
                                else => "store",
                            }),
                            .source = if (pkg.registry_url) |url| try allocator.dupe(u8, url) else &.{},
                            .roles = try entry_roles.toOwnedSlice(allocator),
                        });
                    }
                    if (package_roles.get(pkg.name)) |glist| {
                        for (glist.items) |g| {
                            const role = moonstone.domain.manifest.DependencyRole.fromString(g) orelse .runtime;
                            try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &pkg, pkg.local_path, pkg.artifact_hash, role));
                        }
                    } else {
                        try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &pkg, pkg.local_path, pkg.artifact_hash, .runtime));
                    }
                    report.store_hits += 1;
                    continue;
                }
            }

            // Materialize remote or store-existing
            switch (pkg.location) {
                .remote => switch (pkg.origin) {
                    .moonstone_registry => {
                        report.downloads += 1;
                        report.materializations += 1;
                    },
                    else => {},
                },
                .local_store => report.store_hits += 1,
                .local_path => {},
            }
            const m_res = switch (pkg.location) {
                .remote => switch (pkg.origin) {
                    .moonstone_registry => |r| try mat.materialize_remote(
                        r.url,
                        r.token,
                        r.descriptor_path,
                        pkg.remote_desc.?,
                        r.artifact_idx,
                    ),
                    else => return error.UnsupportedMaterializationOrigin,
                },
                .local_store, .local_path => moonstone.materialization.materializer.MaterializeResult{
                    .path = try allocator.dupe(u8, pkg.local_path.?),
                    .artifact_hash = try allocator.dupe(u8, pkg.artifact_hash),
                },
            };
            defer m_res.deinit(allocator);

            if (self.locked) {
                const lock_entry = existing_lock.find(pkg.name) orelse return error.LockfileOutOfSync;
                if (!std.mem.eql(u8, lock_entry.version, pkg.version)) return error.LockfileOutOfSync;
                if (!std.mem.eql(u8, lock_entry.artifact_hash, m_res.artifact_hash)) return error.LockfileOutOfSync;
            } else if (!std.mem.eql(u8, pkg.name, rt_res.name)) {
                const recipe_hash = if (pkg.remote_desc) |rd| rd.artifact[pkg.artifact_idx orelse 0].recipe_hash else "";
                var entry_roles = std.ArrayList([]const u8).empty;
                defer {
                    for (entry_roles.items) |g| allocator.free(g);
                    entry_roles.deinit(allocator);
                }
                if (package_roles.get(pkg.name)) |glist| {
                    for (glist.items) |g| {
                        try entry_roles.append(allocator, try allocator.dupe(u8, g));
                    }
                }
                try next_lock.packages.append(allocator, .{
                    .name = try allocator.dupe(u8, pkg.name),
                    .version = try allocator.dupe(u8, pkg.version),
                    .kind = pkg.kind,
                    .source_hash = &.{},
                    .recipe_hash = try allocator.dupe(u8, recipe_hash),
                    .artifact_hash = try allocator.dupe(u8, m_res.artifact_hash),
                    .runtime = try allocator.dupe(u8, active_lua_abi),
                    .lua_abi = try allocator.dupe(u8, pkg.lua_abi orelse active_lua_abi),
                    .target = try allocator.dupe(u8, "native"),
                    .constellation = try allocator.dupe(u8, "default"),
                    .resolver = try allocator.dupe(u8, switch (pkg.origin) {
                        .luarocks => "rocks",
                        .moonstone_registry => "moonstone",
                        .link => "link",
                        .path => "path",
                        else => "store",
                    }),
                    .source = if (pkg.registry_url) |url| try allocator.dupe(u8, url) else &.{},
                    .roles = try entry_roles.toOwnedSlice(allocator),
                });
            }
            if (!std.mem.eql(u8, pkg.name, rt_res.name)) {
                if (package_roles.get(pkg.name)) |glist| {
                    for (glist.items) |g| {
                        const role = moonstone.domain.manifest.DependencyRole.fromString(g) orelse .runtime;
                        try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &pkg, m_res.path, m_res.artifact_hash, role));
                    }
                } else {
                    try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &pkg, m_res.path, m_res.artifact_hash, .runtime));
                }
            }
        }
        report.materialize_ms = elapsedMs(io, materialize_started_ns);
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "materialization.complete", .{
                .store_hits = report.store_hits,
                .downloads = report.downloads,
                .materializations = report.materializations,
                .path_link_projections = report.path_link_projections,
                .elapsed_ms = report.materialize_ms,
            });
        }

        if (!self.locked) {
            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try next_lock.serialize(allocator, &aw.writer);

            const lock_file = try std.Io.Dir.cwd().createFile(io, "moonstone.lock", .{});
            defer lock_file.close(io);
            try lock_file.writeStreamingAll(io, aw.written());
        }

        // 5. Link environment
        const link_started_ns = nowNs(io);
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "env.link.begin", .{ .artifacts = projected_artifacts.items.len, .links = live_links.items.len });
        } else {
            try stdout.print("Linking project environment...\n", .{});
        }
        try moonstone.project.linker.link_project_env_at(allocator, io, std.Io.Dir.cwd(), idx, projected_artifacts.items, live_links.items, ".moonstone/env", env);
        report.linked = projected_artifacts.items.len + live_links.items.len;
        report.env_refreshed = true;
        report.link_ms = elapsedMs(io, link_started_ns);
        report.total_ms = elapsedMs(io, started_ns);

        if (emitter) |e| {
            try e.terminate(io, name, "sync.complete", .{
                .summary = report,
            });
        } else {
            try stdout.print("Project environment synchronized.\n", .{});
        }
    }

    fn runCheck(self: SyncCommand, ctx: *router.Context, mt: *moonstone.domain.manifest.MoonstoneToml, idx: *moonstone.store.driver.StoreDriver) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, name, "check.begin", .{});
        } else {
            try stdout.print("Checking Moonstone project...\n", .{});
        }

        var issues: usize = 0;

        var lf = blk: {
            const lock_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.lock", allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) {
                    issues += 1;
                    try reportCheck(emitter, io, stdout, "lockfile", false, "moonstone.lock is missing; run 'moon sync'.");
                    break :blk moonstone.domain.lockfile.LockFile.init(allocator);
                }
                return err;
            };
            defer allocator.free(lock_content);
            break :blk moonstone.domain.lockfile.LockFile.parse(allocator, lock_content) catch |err| {
                issues += 1;
                const msg = try std.fmt.allocPrint(allocator, "moonstone.lock is invalid: {s}", .{@errorName(err)});
                defer allocator.free(msg);
                try reportCheck(emitter, io, stdout, "lockfile", false, msg);
                break :blk moonstone.domain.lockfile.LockFile.init(allocator);
            };
        };
        defer lf.deinit();

        issues += try self.checkDependencies(allocator, io, emitter, stdout, "dependencies", mt.dependencies.items, &lf, idx);

        if (lf.packages.items.len > 0) {
            var missing_artifacts: usize = 0;
            for (lf.packages.items) |pkg| {
                if (pkg.artifact_hash.len == 0) continue;
                if (std.mem.eql(u8, pkg.artifact_hash, "link") or std.mem.eql(u8, pkg.artifact_hash, "path")) continue;
                if (!(idx.has_artifact(pkg.artifact_hash) catch false)) missing_artifacts += 1;
            }
            if (missing_artifacts > 0) {
                issues += 1;
                const msg = try std.fmt.allocPrint(allocator, "{d} lockfile artifact(s) are missing from the store; run 'moon sync'.", .{missing_artifacts});
                defer allocator.free(msg);
                try reportCheck(emitter, io, stdout, "lockfile_artifacts", false, msg);
            } else {
                try reportCheck(emitter, io, stdout, "lockfile_artifacts", true, "ok");
            }
        }

        const env_issues = try countEnvIssues(allocator, io);
        if (env_issues > 0) {
            issues += 1;
            const msg = try std.fmt.allocPrint(allocator, ".moonstone/env has {d} issue(s); run 'moon sync'.", .{env_issues});
            defer allocator.free(msg);
            try reportCheck(emitter, io, stdout, "env", false, msg);
        } else {
            try reportCheck(emitter, io, stdout, "env", true, "ok");
        }

        if (issues > 0) {
            if (emitter) |e| {
                try e.fail(io, name, "error.LockfileOutOfSync", .{ .issues = issues });
                return @import("command.zig").CommonError.AlreadyReported;
            }
            return error.LockfileOutOfSync;
        }

        if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .issues = issues });
        } else {
            try stdout.print("Project is up to date.\n", .{});
        }
    }

    fn checkDependencies(
        self: SyncCommand,
        allocator: std.mem.Allocator,
        io: std.Io,
        emitter: ?*ndjson.Emitter,
        stdout: *std.Io.Writer,
        about: []const u8,
        deps: []const moonstone.domain.manifest.StoreDependency,
        lf: *moonstone.domain.lockfile.LockFile,
        idx: *moonstone.store.driver.StoreDriver,
    ) !usize {
        _ = self;
        var issues: usize = 0;
        for (deps) |dep| {
            const dep_name = dep.name;

            if (dep.resolver) |resolver_name| {
                const resolver = moonstone.resolution.ResolverKind.fromString(resolver_name) catch null;
                if (resolver) |res| {
                    switch (res) {
                        .path => {
                            std.Io.Dir.cwd().access(io, dep.constraint, .{}) catch {
                                issues += 1;
                                const msg = try std.fmt.allocPrint(allocator, "path dependency {s} target does not exist: {s}", .{ dep_name, dep.constraint });
                                defer allocator.free(msg);
                                try reportCheck(emitter, io, stdout, about, false, msg);
                            };
                            continue;
                        },
                        .link => {
                            const link_store = moonstone.store.links.LinkStore.init(idx);
                            if (try link_store.get(dep.constraint)) |link_entry| {
                                var mut_entry = link_entry;
                                mut_entry.deinit(allocator);
                            } else {
                                issues += 1;
                                const msg = try std.fmt.allocPrint(allocator, "link dependency {s} is not registered; run 'moon link' from the {s} project directory, then retry 'moon add link:{s}'.", .{ dep_name, dep.constraint, dep.constraint });
                                defer allocator.free(msg);
                                try reportCheck(emitter, io, stdout, about, false, msg);
                            }
                            continue;
                        },
                        .artifact => {
                            if (!(idx.has_artifact(dep.constraint) catch false)) {
                                issues += 1;
                                const msg = try std.fmt.allocPrint(allocator, "artifact dependency {s} is missing from the store: {s}", .{ dep_name, dep.constraint });
                                defer allocator.free(msg);
                                try reportCheck(emitter, io, stdout, about, false, msg);
                            }
                            continue;
                        },
                        else => {},
                    }
                }
            }

            const lock_entry = lf.find(dep_name) orelse {
                issues += 1;
                const msg = try std.fmt.allocPrint(allocator, "moonstone.lock is missing dependency {s}; run 'moon sync'.", .{dep_name});
                defer allocator.free(msg);
                try reportCheck(emitter, io, stdout, about, false, msg);
                continue;
            };

            const constraint = if (dep.constraint.len > 0) dep.constraint else "*";
            if (!moonstone.domain.semver.matches(lock_entry.version, constraint)) {
                issues += 1;
                const msg = try std.fmt.allocPrint(allocator, "locked dependency {s}@{s} does not satisfy {s}; run 'moon sync'.", .{ dep_name, lock_entry.version, constraint });
                defer allocator.free(msg);
                try reportCheck(emitter, io, stdout, about, false, msg);
            }
        }
        if (issues == 0) try reportCheck(emitter, io, stdout, about, true, "ok");
        return issues;
    }
};

fn lockedDependenciesMatch(
    deps: []const moonstone.domain.manifest.StoreDependency,
    lf: *moonstone.domain.lockfile.LockFile,
) bool {
    for (deps) |dep| {
        const dep_name = dep.name;

        if (dep.resolver) |r| {
            if (std.mem.eql(u8, r, "link") or std.mem.eql(u8, r, "path") or std.mem.eql(u8, r, "artifact")) continue;
        }

        const lock_entry = lf.find(dep_name) orelse return false;
        const constraint = if (dep.constraint.len > 0) dep.constraint else "*";
        if (!moonstone.domain.semver.matches(lock_entry.version, constraint)) return false;
    }
    return true;
}

fn reportCheck(emitter: ?*ndjson.Emitter, io: std.Io, stdout: *std.Io.Writer, about: []const u8, ok: bool, message: []const u8) !void {
    if (emitter) |e| {
        try e.emit(io, if (ok) .STATUS else .ERROR, about, if (ok) "ok" else "check.failed", .{ .message = message });
    } else {
        try stdout.print("[{s}] {s}: {s}\n", .{ if (ok) "OK" else "FAIL", about, message });
    }
}

fn countEnvIssues(allocator: std.mem.Allocator, io: std.Io) !usize {
    var issues: usize = 0;
    var env_dir = std.Io.Dir.cwd().openDir(io, ".moonstone/env", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 1;
        return err;
    };
    defer env_dir.close(io);

    env_dir.access(io, "bin/lua", .{}) catch {
        issues += 1;
    };
    const env_abs = std.Io.Dir.cwd().realPathFileAlloc(io, ".moonstone/env", allocator) catch try allocator.dupe(u8, ".moonstone/env");
    defer allocator.free(env_abs);
    issues += try countBrokenSymlinks(allocator, io, env_dir, env_abs);
    return issues;
}

fn countBrokenSymlinks(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, abs_dir_path: []const u8) !usize {
    var broken: usize = 0;
    var iterable_dir = dir;
    var it = iterable_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            var child_dir = try iterable_dir.openDir(io, entry.name, .{ .iterate = true });
            defer child_dir.close(io);
            const child_abs = try std.fs.path.join(allocator, &.{ abs_dir_path, entry.name });
            defer allocator.free(child_abs);
            broken += try countBrokenSymlinks(allocator, io, child_dir, child_abs);
        } else if (entry.kind == .sym_link) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const len = iterable_dir.readLink(io, entry.name, &buf) catch {
                broken += 1;
                continue;
            };
            const target = buf[0..len];
            const target_path = if (std.fs.path.isAbsolute(target))
                try allocator.dupe(u8, target)
            else
                try std.fs.path.join(allocator, &.{ abs_dir_path, target });
            defer allocator.free(target_path);
            std.Io.Dir.cwd().access(io, target_path, .{}) catch {
                broken += 1;
            };
        }
    }
    return broken;
}
