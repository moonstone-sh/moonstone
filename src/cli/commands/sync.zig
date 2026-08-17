const std = @import("std");
const builtin = @import("builtin");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const progress_runtime = @import("../progress.zig");
const task_protocol = @import("../task_protocol.zig");
const profiler = moonstone.diagnostics.profiler;

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

fn resolverForPackageSpec(
    mt: *const moonstone.domain.manifest.MoonstoneToml,
    spec: moonstone.domain.package_spec.PackageSpec,
) !moonstone.resolution.coordinator.CoordinatorKind {
    if (spec.resolver) |kind| return kind;

    const identity = spec.registry orelse return .moonstone;
    if (std.mem.eql(u8, identity, "moonstone")) return .moonstone;
    if (std.mem.eql(u8, identity, "rocks")) return .rocks;

    const config = mt.registries.get(identity) orelse return error.RegistryNotFound;
    return moonstone.resolution.coordinator.CoordinatorKind.fromString(config.resolver);
}

fn registryIdentityForPackageSpec(
    allocator: std.mem.Allocator,
    spec: moonstone.domain.package_spec.PackageSpec,
    resolver: moonstone.resolution.coordinator.CoordinatorKind,
) !?[]const u8 {
    if (spec.resolver != null) {
        return switch (resolver) {
            .path => try allocator.dupe(u8, spec.name),
            .link, .artifact => null,
            else => null,
        };
    }
    return try allocator.dupe(u8, spec.registry orelse switch (resolver) {
        .moonstone => "moonstone",
        .rocks => "rocks",
        else => return null,
    });
}

fn lockRegistryForPackage(
    allocator: std.mem.Allocator,
    pkg: *const moonstone.resolution.candidate.ResolvedArtifact,
    existing_lock: *const moonstone.domain.lockfile.LockFile,
) ![]const u8 {
    if (pkg.registry_name) |registry_name| return allocator.dupe(u8, registry_name);
    if (existing_lock.find(pkg.name)) |entry| {
        if (entry.registry.len > 0) return allocator.dupe(u8, entry.registry);
    }
    return &.{};
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
    if (resolver == null) {
        resolver = try allocator.dupe(u8, switch (pkg.origin) {
            .luarocks => "rocks",
            .moonstone_registry => "moonstone",
            .link => "link",
            .path => "path",
            .artifact_hash => "store",
        });
    }
    const pa_path = if (art_path) |p| try allocator.dupe(u8, p) else null;
    return .{
        .name = try allocator.dupe(u8, pkg.name),
        .version = try allocator.dupe(u8, pkg.version),
        .kind = pkg.kind,
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

fn roleForResolvedPackage(mt: *const moonstone.domain.manifest.MoonstoneToml, pkg_name: []const u8) moonstone.domain.manifest.DependencyRole {
    for (mt.dependencies.items) |dep| {
        if (std.ascii.eqlIgnoreCase(dep.name, pkg_name)) return dep.role;
    }
    return .runtime;
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
        if (comptime builtin.os.tag == .windows) {
            return self;
        } else {
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
    }

    pub fn deinit(self: *JsonStderrSilencer) void {
        if (comptime builtin.os.tag != .windows) {
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
    }

    fn closeFd(self: JsonStderrSilencer, fd: std.posix.fd_t) void {
        if (comptime builtin.os.tag != .windows) {
            const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
            file.close(self.io);
        }
    }
};

fn nowNs(io: std.Io) i128 {
    return std.Io.Timestamp.now(io, .real).nanoseconds;
}

fn elapsedMs(io: std.Io, start_ns: i128) i128 {
    return @divFloor(nowNs(io) - start_ns, std.time.ns_per_ms);
}

fn materializationJobs(arg: ?[]const u8) !usize {
    if (arg) |value| {
        const jobs = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidJobs;
        if (jobs == 0) return error.InvalidJobs;
        return jobs;
    }
    return @max(@as(usize, 1), @min(std.Thread.getCpuCount() catch 1, @as(usize, 8)));
}

/// Command-specific data passed through WorkerContext.cmd_data.
const SyncWorkData = struct {
    cmd: SyncCommand,
    ctx: *router.Context,
    error_detail: ?@import("command.zig").CliErrorDetail = null,
};

/// Worker entry point: runs the sync logic on a background thread,
/// sending progress events through the queue.
fn syncWorker(wctx: *progress_runtime.WorkerContext) anyerror!void {
    const data: *SyncWorkData = @ptrCast(@alignCast(wctx.cmd_data orelse return error.WorkerMissingData));
    data.cmd.runImpl(data.ctx, .{ .queue = wctx }) catch |err| {
        // Stash error_detail for the main thread to pick up.
        if (data.ctx.error_detail) |detail| {
            data.error_detail = detail;
            data.ctx.error_detail = null;
        }
        return err;
    };
}

// ────────────────────────────────────────────────────────────────────────────
//  Download + materialization pool
// ────────────────────────────────────────────────────────────────────────────

const MatResult = moonstone.materialization.materializer.MaterializeResult;
const ResolvedSolution = std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact);

const BuildArtifactLocation = struct {
    name: []const u8,
    artifact_hash: []const u8,
    artifact_path: []const u8,
};

const DownloadJob = struct {
    pkg: *const moonstone.resolution.candidate.ResolvedArtifact,
    result: ?MatResult = null,
    err: ?anyerror = null,
};

const RocksJob = struct {
    pkg: *moonstone.resolution.candidate.ResolvedArtifact,
    preparation_leader: ?usize = null,
    prepared: ?moonstone.resolution.sources.luarocks.PreparedResolution = null,
    build_dependency_names: []const []const u8 = &.{},
    scope_dependency_names: []const []const u8 = &.{},
    materialization_leader: ?usize = null,
    result: ?moonstone.resolution.candidate.ResolvedArtifact = null,
    err: ?anyerror = null,

    fn deinit(self: *RocksJob, allocator: std.mem.Allocator) void {
        if (self.prepared) |*prepared| prepared.deinit(allocator);
        for (self.build_dependency_names) |name| allocator.free(name);
        if (self.build_dependency_names.len > 0) allocator.free(self.build_dependency_names);
        for (self.scope_dependency_names) |name| allocator.free(name);
        if (self.scope_dependency_names.len > 0) allocator.free(self.scope_dependency_names);
        if (self.result) |result| result.deinit(allocator);
    }
};

fn collectBuildDependencyNames(
    allocator: std.mem.Allocator,
    dependencies: []const []const u8,
) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (dependencies) |dependency| {
        var parsed = try moonstone.luarocks.rockspec.parse_dependency_string(allocator, dependency);
        defer parsed.deinit(allocator);
        if (std.ascii.eqlIgnoreCase(parsed.name, "lua")) continue;
        try names.append(allocator, try allocator.dupe(u8, parsed.name));
    }
    return names.toOwnedSlice(allocator);
}

fn collectScopeDependencyNames(
    allocator: std.mem.Allocator,
    runtime_dependencies: []const []const u8,
    build_dependencies: []const []const u8,
) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    const dependency_sets = [_][]const []const u8{ runtime_dependencies, build_dependencies };
    for (dependency_sets) |dependencies| for (dependencies) |dependency| {
        var parsed = try moonstone.luarocks.rockspec.parse_dependency_string(allocator, dependency);
        defer parsed.deinit(allocator);
        if (std.ascii.eqlIgnoreCase(parsed.name, "lua")) continue;
        var already_present = false;
        for (names.items) |name| {
            if (std.ascii.eqlIgnoreCase(name, parsed.name)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) try names.append(allocator, try allocator.dupe(u8, parsed.name));
    };
    return names.toOwnedSlice(allocator);
}

fn mergeDependencyNames(
    allocator: std.mem.Allocator,
    existing: []const []const u8,
    discovered: []const []const u8,
) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    for (existing) |candidate| {
        var already_present = false;
        for (names.items) |name| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) try names.append(allocator, try allocator.dupe(u8, candidate));
    }
    for (discovered) |candidate| {
        var already_present = false;
        for (names.items) |name| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) try names.append(allocator, try allocator.dupe(u8, candidate));
    }
    return names.toOwnedSlice(allocator);
}

fn collectSolvedRocksDependencyNames(
    allocator: std.mem.Allocator,
    origins: []const moonstone.resolution.provider.graph_provider.StoreDependencyOrigin,
    solution: *const ResolvedSolution,
    parent_name: []const u8,
    include_runtime: bool,
) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    for (origins) |origin| {
        if (!std.ascii.eqlIgnoreCase(origin.parent_name, parent_name)) continue;
        if (!solutionContainsPackage(solution, origin.child_name)) continue;
        if (!include_runtime and origin.child_role != .build) continue;

        var already_present = false;
        for (names.items) |name| {
            if (std.ascii.eqlIgnoreCase(name, origin.child_name)) {
                already_present = true;
                break;
            }
        }
        if (!already_present) try names.append(allocator, try allocator.dupe(u8, origin.child_name));
    }
    return names.toOwnedSlice(allocator);
}

const LockedReplayJob = struct {
    entry: *const moonstone.domain.lockfile.LockEntry,
    result: ?moonstone.resolution.candidate.ResolvedArtifact = null,
    err: ?anyerror = null,

    fn deinit(self: *LockedReplayJob, allocator: std.mem.Allocator) void {
        if (self.result) |result| result.deinit(allocator);
    }
};

const MutexAllocator = struct {
    parent: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    pub fn allocator(self: *MutexAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.parent.rawAlloc(len, ptr_align, ret_addr);
    }
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.parent.rawResize(buf, buf_align, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.parent.rawRemap(buf, buf_align, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *MutexAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.parent.rawFree(buf, buf_align, ret_addr);
    }
};

const DownloadPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    jobs: []DownloadJob,
    target: []const u8,
    runtime_path: ?[]const u8 = null,
    next: std.atomic.Value(usize) = .init(0),
    wctx: ?*progress_runtime.WorkerContext,
    reporter: task_protocol.Reporter,
    on_resolve_cb: ?moonstone.resolution.options.ResolveCallback,
    on_resolve_ctx: ?*anyopaque,

    fn run(self: *DownloadPool) void {
        while (true) {
            // Cooperative cancellation: stop picking up new jobs.
            if (self.wctx) |w| {
                if (w.isCancelled()) return;
            }
            const idx = self.next.fetchAdd(1, .monotonic);
            if (idx >= self.jobs.len) return;
            self.processJob(idx);
        }
    }

    fn processJob(self: *DownloadPool, idx: usize) void {
        const job = &self.jobs[idx];
        const pkg = job.pkg.*;
        var task_buf: [384]u8 = undefined;
        const task_id = task_protocol.formatId(&task_buf, .realize, self.target, "moonstone", pkg.name, pkg.version) catch pkg.name;

        self.reporter.report(self.io, task_id, 1, "running", task_id, .{
            .package = pkg.name,
            .version = pkg.version,
            .resolver = "moonstone",
        });

        // Progress: package started
        if (self.wctx) |w| {
            var buf: [128]u8 = undefined;
            const tmp = std.fmt.bufPrint(&buf, "{s}@{s}", .{ pkg.name, pkg.version }) catch pkg.name;
            const msg = self.allocator.dupe(u8, tmp) catch pkg.name;
            w.sendPackageStarted(msg);
        }

        var mat = moonstone.materialization.materializer.Materializer{
            .allocator = self.allocator,
            .io = self.io,
            .environ_map = self.env,
            .runtime_path = self.runtime_path,
            .on_event = self.on_resolve_cb,
            .on_event_context = self.on_resolve_ctx,
        };

        const reg = pkg.origin.moonstone_registry;
        const m_res = mat.materialize_remote(
            reg.url,
            reg.token,
            reg.descriptor_path,
            pkg.remote_desc.?,
            reg.artifact_idx,
        ) catch |err| {
            job.err = err;
            self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{
                .package = pkg.name,
                .version = pkg.version,
                .error_name = @errorName(err),
            });
            if (self.wctx) |w| {
                var buf: [256]u8 = undefined;
                const tmp = std.fmt.bufPrint(&buf, "Failed to materialize {s}: {s}", .{ pkg.name, @errorName(err) }) catch return;
                const msg = self.allocator.dupe(u8, tmp) catch return;
                w.sendWarning(msg);
            }
            return;
        };

        job.result = m_res;

        self.reporter.report(self.io, task_id, 2, "completed", task_id, .{
            .package = pkg.name,
            .version = pkg.version,
            .artifact_hash = m_res.artifact_hash,
        });

        // Progress: package done
        if (self.wctx) |w| {
            var buf: [128]u8 = undefined;
            const tmp = std.fmt.bufPrint(&buf, "{s}@{s}", .{ pkg.name, pkg.version }) catch pkg.name;
            const msg = self.allocator.dupe(u8, tmp) catch pkg.name;
            w.sendPackageDone(msg);
        }
    }

    /// Spawn `n` worker threads, then join them all.
    fn execute(self: *DownloadPool, n: usize) !void {
        var scheduler = moonstone.realization.scheduler.Scheduler{
            .allocator = self.allocator,
            .io = self.io,
            .task_count = self.jobs.len,
            .context = @ptrCast(self),
            .run_task = runScheduled,
            .is_cancelled = isCancelled,
        };
        try scheduler.execute(n);
    }

    fn runScheduled(context: *anyopaque, task_index: usize) !void {
        const self: *DownloadPool = @ptrCast(@alignCast(context));
        self.processJob(task_index);
        if (self.jobs[task_index].err) |err| return err;
    }

    fn isCancelled(context: *anyopaque) bool {
        const self: *DownloadPool = @ptrCast(@alignCast(context));
        return if (self.wctx) |wctx| wctx.isCancelled() else false;
    }
};

const RocksPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    jobs: []RocksJob,
    selected: ?*ResolvedSolution = null,
    downloaded: []const DownloadJob = &.{},
    target: []const u8,
    options: moonstone.resolution.options.ResolveOptions,
    wctx: ?*progress_runtime.WorkerContext,
    reporter: task_protocol.Reporter,
    preparation_coordinator: moonstone.realization.request_coordinator.RequestCoordinator,
    request_coordinator: moonstone.realization.request_coordinator.RequestCoordinator,

    fn deinit(self: *RocksPool) void {
        self.preparation_coordinator.deinit();
        self.request_coordinator.deinit();
    }

    fn preparationRequestKey(self: *RocksPool, pkg: *const moonstone.resolution.candidate.ResolvedArtifact) ![]const u8 {
        const registry_name = pkg.registry_name orelse "rocks";
        const runtime = self.options.runtime orelse "";
        const runtime_artifact_hash = self.options.runtime_artifact_hash orelse "";
        const target = self.options.target orelse "native";
        const source_url = pkg.origin.luarocks.url;

        const input = try std.fmt.allocPrint(self.allocator,
            \\moonstone:rocks-preparation:v1
            \\source={d}:{s}
            \\registry={d}:{s}
            \\package={d}:{s}
            \\version={d}:{s}
            \\runtime={d}:{s}
            \\runtime_artifact={d}:{s}
            \\target={d}:{s}
            \\
        , .{
            source_url.len,
            source_url,
            registry_name.len,
            registry_name,
            pkg.name.len,
            pkg.name,
            pkg.version.len,
            pkg.version,
            runtime.len,
            runtime,
            runtime_artifact_hash.len,
            runtime_artifact_hash,
            target.len,
            target,
        });
        defer self.allocator.free(input);
        return moonstone.identity.hash.blake3_hex(self.allocator, input);
    }

    fn selectPreparationLeaders(self: *RocksPool) !void {
        for (self.jobs, 0..) |*job, index| {
            const key = try self.preparationRequestKey(job.pkg);
            defer self.allocator.free(key);
            job.preparation_leader = switch (try self.preparation_coordinator.claim(key, index)) {
                .leader => index,
                .follower => |leader| leader,
            };
        }
    }

    fn prepareJob(self: *RocksPool, idx: usize) void {
        const job = &self.jobs[idx];
        const pkg = job.pkg.*;
        var task_buf: [384]u8 = undefined;
        const task_id = task_protocol.formatId(&task_buf, .realize, self.target, "rocks", pkg.name, pkg.version) catch pkg.name;
        const task_label = std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ pkg.name, pkg.version }) catch pkg.name;
        defer if (task_label.ptr != pkg.name.ptr) self.allocator.free(task_label);
        self.reporter.report(self.io, task_id, 1, "preparing", task_label, .{
            .package = pkg.name,
            .version = pkg.version,
            .resolver = "rocks",
        });

        if (job.preparation_leader != null and job.preparation_leader.? != idx) {
            self.reporter.report(self.io, task_id, 2, "waiting", "reusing in-flight preparation", .{
                .package = pkg.name,
                .version = pkg.version,
                .resolver = "rocks",
                .reused_preparation = true,
            });
            return;
        }

        const base = pkg.origin.luarocks.url;
        const prepared = moonstone.resolution.sources.luarocks.prepare(
            self.allocator,
            self.io,
            pkg.name,
            pkg.version,
            self.options,
            self.env,
            base,
            pkg.registry_name,
        ) catch |err| {
            job.err = err;
            self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{ .error_name = @errorName(err) });
            return;
        };

        switch (prepared) {
            .binary => |resolved| {
                job.result = resolved;
                self.reporter.report(self.io, task_id, 2, "completed", task_label, .{
                    .package = pkg.name,
                    .version = pkg.version,
                    .resolver = "rocks",
                    .source = "binary-rock",
                });
            },
            .source => {
                job.prepared = prepared;
                const source = switch (job.prepared.?) {
                    .source => |*value| value,
                    .binary => unreachable,
                };
                const parsed_build_dependencies = collectBuildDependencyNames(self.allocator, source.parsed_rockspec.value.intent.build_dependencies) catch |err| {
                    job.err = err;
                    self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{ .error_name = @errorName(err) });
                    return;
                };
                defer {
                    for (parsed_build_dependencies) |name| self.allocator.free(name);
                    if (parsed_build_dependencies.len > 0) self.allocator.free(parsed_build_dependencies);
                }
                const merged_build_dependencies = mergeDependencyNames(self.allocator, job.build_dependency_names, parsed_build_dependencies) catch |err| {
                    job.err = err;
                    self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{ .error_name = @errorName(err) });
                    return;
                };
                for (job.build_dependency_names) |name| self.allocator.free(name);
                if (job.build_dependency_names.len > 0) self.allocator.free(job.build_dependency_names);
                job.build_dependency_names = merged_build_dependencies;

                const parsed_scope_dependencies = collectScopeDependencyNames(
                    self.allocator,
                    source.parsed_rockspec.value.intent.dependencies,
                    source.parsed_rockspec.value.intent.build_dependencies,
                ) catch |err| {
                    job.err = err;
                    self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{ .error_name = @errorName(err) });
                    return;
                };
                defer {
                    for (parsed_scope_dependencies) |name| self.allocator.free(name);
                    if (parsed_scope_dependencies.len > 0) self.allocator.free(parsed_scope_dependencies);
                }
                const merged_scope_dependencies = mergeDependencyNames(self.allocator, job.scope_dependency_names, parsed_scope_dependencies) catch |err| {
                    job.err = err;
                    self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{ .error_name = @errorName(err) });
                    return;
                };
                for (job.scope_dependency_names) |name| self.allocator.free(name);
                if (job.scope_dependency_names.len > 0) self.allocator.free(job.scope_dependency_names);
                job.scope_dependency_names = merged_scope_dependencies;
                self.reporter.report(self.io, task_id, 2, "prepared", task_label, .{
                    .package = pkg.name,
                    .version = pkg.version,
                    .resolver = "rocks",
                });
            },
        }
    }

    fn materializeJob(self: *RocksPool, idx: usize) void {
        const job = &self.jobs[idx];
        if (job.materialization_leader == null or job.materialization_leader.? != idx) return;

        var prepared = job.prepared orelse return;
        job.prepared = null;
        defer prepared.deinit(self.allocator);

        const source = switch (prepared) {
            .source => |*value| value,
            .binary => unreachable,
        };
        const pkg = job.pkg.*;
        var task_buf: [384]u8 = undefined;
        const task_id = task_protocol.formatId(&task_buf, .realize, self.target, "rocks", pkg.name, pkg.version) catch pkg.name;
        const task_label = std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ pkg.name, pkg.version }) catch pkg.name;
        defer if (task_label.ptr != pkg.name.ptr) self.allocator.free(task_label);
        self.reporter.report(self.io, task_id, 3, "materializing", task_label, .{
            .package = pkg.name,
            .version = pkg.version,
            .resolver = "rocks",
        });

        job.result = self.materializePreparedJob(idx, source) catch |err| {
            job.err = err;
            self.reporter.report(self.io, task_id, 4, "failed", @errorName(err), .{ .error_name = @errorName(err) });
            return;
        };
        self.reporter.report(self.io, task_id, 4, "completed", task_label, .{
            .package = pkg.name,
            .version = pkg.version,
            .resolver = "rocks",
        });
    }

    fn materializePreparedJob(
        self: *RocksPool,
        idx: usize,
        source: *moonstone.resolution.sources.luarocks.PreparedRock,
    ) !moonstone.resolution.candidate.ResolvedArtifact {
        const job = &self.jobs[idx];
        var scoped_environment: ?moonstone.project.build_scope.BuildScope = null;
        defer if (scoped_environment) |*scope| scope.deinit();

        var options = self.options;
        var build_artifacts = std.ArrayList(moonstone.resolution.options.BuildArtifact).empty;
        defer build_artifacts.deinit(self.allocator);
        var roots = std.ArrayList(moonstone.project.build_scope.ArtifactRoot).empty;
        defer roots.deinit(self.allocator);
        var owned_root_paths = std.ArrayList([]u8).empty;
        defer {
            for (owned_root_paths.items) |path| self.allocator.free(path);
            owned_root_paths.deinit(self.allocator);
        }

        var build_env = self.env;
        if (job.build_dependency_names.len > 0) {
            const closure = try self.buildClosure(idx);
            defer closure.deinit(self.allocator);
            for (closure.items) |dependency_name| {
                const dependency = self.buildArtifactFor(dependency_name) orelse return error.BuildDependencyResolutionMissing;
                const files_path = try std.fs.path.join(self.allocator, &.{ dependency.artifact_path, "files" });
                try owned_root_paths.append(self.allocator, files_path);
                try roots.append(self.allocator, .{ .files_path = files_path });
                try build_artifacts.append(self.allocator, .{
                    .name = dependency.name,
                    .artifact_hash = dependency.artifact_hash,
                });
            }

            const runtime_path = options.runtime_path orelse return error.RuntimePathRequired;
            const runtime_files_path = try std.fs.path.join(self.allocator, &.{ runtime_path, "files" });
            try owned_root_paths.append(self.allocator, runtime_files_path);
            try roots.append(self.allocator, .{ .files_path = runtime_files_path });

            var runtime_buf: [8]u8 = undefined;
            const lua_ver_dot = moonstone.resolution.options.normalizeRuntimeAbi(options.runtime orelse "lua54", &runtime_buf);
            scoped_environment = try moonstone.project.build_scope.project(self.allocator, self.io, self.env, roots.items, lua_ver_dot);
            build_env = &scoped_environment.?.env_map;
            options.build_artifacts = build_artifacts.items;
        }

        return moonstone.resolution.sources.luarocks.materialize_prepared_rock(
            self.allocator,
            self.io,
            job.pkg.name,
            source.parsed_rockspec.value.version,
            options,
            build_env,
            job.pkg.origin.luarocks.url,
            job.pkg.registry_name,
            source,
        );
    }

    fn findJob(self: *RocksPool, name: []const u8) ?usize {
        for (self.jobs, 0..) |job, index| {
            if (std.ascii.eqlIgnoreCase(job.pkg.name, name)) return index;
        }
        return null;
    }

    const BuildClosure = struct {
        items: []const []const u8,

        fn deinit(self: BuildClosure, allocator: std.mem.Allocator) void {
            for (self.items) |name| allocator.free(name);
            allocator.free(self.items);
        }
    };

    fn buildClosure(self: *RocksPool, idx: usize) !BuildClosure {
        var queue = std.ArrayList([]const u8).empty;
        defer queue.deinit(self.allocator);
        var closure = std.ArrayList([]const u8).empty;
        errdefer {
            for (closure.items) |name| self.allocator.free(name);
            closure.deinit(self.allocator);
        }

        for (self.jobs[idx].build_dependency_names) |name| {
            try queue.append(self.allocator, name);
        }
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const name = queue.items[cursor];
            var already_present = false;
            for (closure.items) |present| {
                if (std.ascii.eqlIgnoreCase(present, name)) {
                    already_present = true;
                    break;
                }
            }
            if (already_present) continue;
            try closure.append(self.allocator, try self.allocator.dupe(u8, name));

            if (self.findJob(name)) |dependency_index| {
                for (self.jobs[dependency_index].scope_dependency_names) |child_name| {
                    try queue.append(self.allocator, child_name);
                }
            }
        }

        return .{ .items = try closure.toOwnedSlice(self.allocator) };
    }

    fn buildArtifactFor(self: *RocksPool, name: []const u8) ?BuildArtifactLocation {
        if (self.findJob(name)) |index| {
            const job = &self.jobs[index];
            if (job.result) |*result| if (result.local_path) |path| {
                return .{ .name = result.name, .artifact_hash = result.artifact_hash, .artifact_path = path };
            };
            if (job.pkg.local_path) |path| {
                return .{ .name = job.pkg.name, .artifact_hash = job.pkg.artifact_hash, .artifact_path = path };
            }
        }
        for (self.downloaded) |download| {
            if (!std.ascii.eqlIgnoreCase(download.pkg.name, name)) continue;
            if (download.result) |result| {
                return .{ .name = download.pkg.name, .artifact_hash = result.artifact_hash, .artifact_path = result.path };
            }
        }
        if (self.selected) |selected| {
            var iterator = selected.iterator();
            while (iterator.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) if (entry.value_ptr.local_path) |path| {
                    return .{ .name = entry.value_ptr.name, .artifact_hash = entry.value_ptr.artifact_hash, .artifact_path = path };
                };
            }
        }
        return null;
    }

    fn selectMaterializationLeaders(self: *RocksPool) !void {
        for (self.jobs, 0..) |*job, index| {
            if (job.prepared == null) continue;
            const source = switch (job.prepared.?) {
                .source => |*value| value,
                .binary => unreachable,
            };
            if (source.recipeKey()) |recipe_key| {
                job.materialization_leader = switch (try self.request_coordinator.claim(recipe_key, index)) {
                    .leader => index,
                    .follower => |leader| leader,
                };
            } else {
                job.materialization_leader = index;
            }
        }

        for (self.jobs, 0..) |*job, index| {
            const preparation_leader = job.preparation_leader orelse continue;
            if (preparation_leader == index) continue;

            const leader = &self.jobs[preparation_leader];
            if (leader.result) |result| {
                job.result = try result.clone(self.allocator);
                continue;
            }
            job.materialization_leader = leader.materialization_leader;
        }
    }

    fn completeFollowers(self: *RocksPool) !void {
        for (self.jobs, 0..) |*job, index| {
            const leader = job.materialization_leader orelse continue;
            if (leader == index) continue;

            const leader_result = self.jobs[leader].result orelse return error.MaterializationLeaderMissingResult;
            job.result = try leader_result.clone(self.allocator);
            if (job.prepared) |*prepared| prepared.deinit(self.allocator);
            job.prepared = null;

            const pkg = job.pkg.*;
            var task_buf: [384]u8 = undefined;
            const task_id = task_protocol.formatId(&task_buf, .realize, self.target, "rocks", pkg.name, pkg.version) catch pkg.name;
            self.reporter.report(self.io, task_id, 3, "completed", "reused prepared recipe", .{
                .package = pkg.name,
                .version = pkg.version,
                .resolver = "rocks",
                .reused_recipe = true,
            });
        }
    }

    fn execute(self: *RocksPool, jobs: usize) !void {
        try self.selectPreparationLeaders();

        var scheduler = moonstone.realization.scheduler.Scheduler{
            .allocator = self.allocator,
            .io = self.io,
            .task_count = self.jobs.len,
            .context = @ptrCast(self),
            .run_task = runScheduled,
            .is_cancelled = isCancelled,
        };
        try scheduler.execute(jobs);

        try self.selectMaterializationLeaders();
        try self.materializeDependencyWaves(jobs);
        try self.completeFollowers();
    }

    const MaterializationWave = struct {
        pool: *RocksPool,
        indexes: []const usize,
    };

    /// Materialize each dependency-ready wave concurrently. The previous
    /// implementation switched the entire pool to a serial recursive walk as
    /// soon as any Rock declared build dependencies, which made unrelated
    /// source Rocks wait behind that one graph.
    fn materializeDependencyWaves(self: *RocksPool, jobs: usize) !void {
        var pending = try self.allocator.alloc(bool, self.jobs.len);
        defer self.allocator.free(pending);
        @memset(pending, true);

        while (true) {
            var ready = std.ArrayList(usize).empty;
            defer ready.deinit(self.allocator);
            var remaining: usize = 0;

            for (self.jobs, 0..) |*job, index| {
                if (!pending[index]) continue;

                if (job.result != null) {
                    pending[index] = false;
                    continue;
                }

                const leader = job.materialization_leader orelse index;
                if (leader != index) {
                    pending[index] = false;
                    continue;
                }

                remaining += 1;
                if (job.prepared == null) return error.MaterializationPreparationMissing;
                if (try self.materializationDependenciesReady(index)) {
                    try ready.append(self.allocator, index);
                }
            }

            if (remaining == 0) break;
            if (ready.items.len == 0) return error.LuaRocksBuildDependencyCycle;

            var wave = MaterializationWave{ .pool = self, .indexes = ready.items };
            var scheduler = moonstone.realization.scheduler.Scheduler{
                .allocator = self.allocator,
                .io = self.io,
                .task_count = wave.indexes.len,
                .context = @ptrCast(&wave),
                .run_task = runMaterializationWaveScheduled,
                .is_cancelled = isMaterializationWaveCancelled,
            };
            try scheduler.execute(jobs);

            for (ready.items) |index| {
                if (self.jobs[index].err) |err| return err;
                pending[index] = false;
            }
        }
    }

    fn materializationDependenciesReady(self: *RocksPool, idx: usize) !bool {
        for (self.jobs[idx].scope_dependency_names) |dependency_name| {
            if (self.findJob(dependency_name)) |dependency_index| {
                const leader = self.jobs[dependency_index].materialization_leader orelse dependency_index;
                if (self.jobs[leader].result == null) return false;
            } else if (self.buildArtifactFor(dependency_name) == null) {
                return error.BuildDependencyResolutionMissing;
            }
        }
        return true;
    }

    fn runScheduled(context: *anyopaque, task_index: usize) !void {
        const self: *RocksPool = @ptrCast(@alignCast(context));
        self.prepareJob(task_index);
        if (self.jobs[task_index].err) |err| return err;
    }

    fn runMaterializationWaveScheduled(context: *anyopaque, task_index: usize) !void {
        const wave: *MaterializationWave = @ptrCast(@alignCast(context));
        const job_index = wave.indexes[task_index];
        wave.pool.materializeJob(job_index);
        if (wave.pool.jobs[job_index].err) |err| return err;
    }

    fn isMaterializationWaveCancelled(context: *anyopaque) bool {
        const wave: *MaterializationWave = @ptrCast(@alignCast(context));
        return if (wave.pool.wctx) |wctx| wctx.isCancelled() else false;
    }

    fn isCancelled(context: *anyopaque) bool {
        const self: *RocksPool = @ptrCast(@alignCast(context));
        return if (self.wctx) |wctx| wctx.isCancelled() else false;
    }
};

/// Lock replay cannot share the solver's RegistryProvider between workers: it
/// owns an arena and mutable candidate cache. Each task instead opens an
/// independent SQLite connection and provider over the immutable project
/// registry/target configuration. Results are merged into the solution only
/// after all replay tasks finish.
const LockedReplayPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    index_db_path_z: [:0]const u8,
    registries: []const moonstone.registry.core.ResolvedRegistry,
    provider_options: moonstone.resolution.options.ResolveOptions,
    lua_exe: ?[]const u8,
    targets: []const moonstone.resolution.solver.term.Term,
    target: []const u8,
    jobs: []LockedReplayJob,
    policy: moonstone.resolution.locked_realizer.ReplayPolicy,
    wctx: ?*progress_runtime.WorkerContext,
    reporter: task_protocol.Reporter,

    fn processJob(self: *LockedReplayPool, task_index: usize) void {
        const job = &self.jobs[task_index];
        const entry = job.entry;
        var task_buf: [384]u8 = undefined;
        const resolver = if (entry.resolver.len > 0) entry.resolver else "locked";
        const task_id = task_protocol.formatId(&task_buf, .replay, self.target, resolver, entry.name, entry.version) catch entry.name;
        self.reporter.report(self.io, task_id, 1, "running", task_id, .{
            .package = entry.name,
            .version = entry.version,
            .resolver = resolver,
        });

        var worker_index = moonstone.store.driver.StoreDriver.init(self.allocator, self.index_db_path_z) catch |err| {
            job.err = err;
            return;
        };
        defer worker_index.deinit();

        var worker_provider: moonstone.resolution.provider.graph_provider.RegistryProvider = undefined;
        worker_provider.init(
            self.allocator,
            self.io,
            worker_index,
            self.registries,
            self.provider_options,
            self.env,
            self.lua_exe,
            self.targets,
        );
        defer worker_provider.deinit();

        const real_res = moonstone.resolution.locked_realizer.ensureLockedArtifact(
            self.allocator,
            self.io,
            self.env,
            entry,
            &worker_provider,
            &worker_index,
            self.policy,
        ) catch |err| {
            job.err = err;
            self.reporter.report(self.io, task_id, 2, "failed", @errorName(err), .{ .error_name = @errorName(err) });
            return;
        };
        job.result = real_res.candidate;
        self.reporter.report(self.io, task_id, 2, "completed", task_id, .{
            .package = entry.name,
            .version = entry.version,
            .resolver = resolver,
        });
    }

    fn execute(self: *LockedReplayPool, jobs: usize) !void {
        var scheduler = moonstone.realization.scheduler.Scheduler{
            .allocator = self.allocator,
            .io = self.io,
            .task_count = self.jobs.len,
            .context = @ptrCast(self),
            .run_task = runScheduled,
            .is_cancelled = isCancelled,
        };
        try scheduler.execute(jobs);
    }

    fn runScheduled(context: *anyopaque, task_index: usize) !void {
        const self: *LockedReplayPool = @ptrCast(@alignCast(context));
        self.processJob(task_index);
        if (self.jobs[task_index].err) |err| return err;
    }

    fn isCancelled(context: *anyopaque) bool {
        const self: *LockedReplayPool = @ptrCast(@alignCast(context));
        return if (self.wctx) |wctx| wctx.isCancelled() else false;
    }
};

// ────────────────────────────────────────────────────────────────────────────
//  Hash verification pool — parallel Blake3 verification of materialized artifacts
// ────────────────────────────────────────────────────────────────────────────

const VerifyJob = struct {
    pkg_name: []const u8,
    artifact_path: []const u8, // path in the store
    expected_hash: []const u8, // "b3:..." hex string
    ok: bool = false,
    err: ?anyerror = null,
};

const HashVerifyPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: []VerifyJob,
    next: std.atomic.Value(usize) = .init(0),
    wctx: ?*progress_runtime.WorkerContext,

    fn run(self: *HashVerifyPool) void {
        while (true) {
            // Cooperative cancellation: stop picking up new jobs.
            if (self.wctx) |w| {
                if (w.isCancelled()) return;
            }
            const idx = self.next.fetchAdd(1, .monotonic);
            if (idx >= self.jobs.len) return;
            self.verifyJob(idx);
        }
    }

    fn verifyJob(self: *HashVerifyPool, idx: usize) void {
        const job = &self.jobs[idx];

        // The artifact_path points to the store directory (e.g.
        // .../store/b3/aa/bb/aabb...-name-version).  We open it and
        // compute the canonical artifact hash, then compare against
        // the expected hash from the lockfile / registry.
        const dir = std.Io.Dir.cwd().openDir(self.io, job.artifact_path, .{ .iterate = true }) catch |err| {
            job.err = err;
            return;
        };
        defer dir.close(self.io);

        const computed = moonstone.identity.hash.artifact_hash(self.allocator, self.io, dir) catch |err| {
            job.err = err;
            return;
        };
        defer self.allocator.free(computed);

        // Expected hash is "b3:hex", computed is just hex.
        const expected_hex = if (std.mem.startsWith(u8, job.expected_hash, "b3:"))
            job.expected_hash[3..]
        else
            job.expected_hash;

        if (std.mem.eql(u8, computed, expected_hex)) {
            job.ok = true;
            if (self.wctx) |w| {
                w.sendPackageDone(job.pkg_name);
            }
        } else {
            job.err = error.HashMismatch;
            if (self.wctx) |w| {
                var buf: [256]u8 = undefined;
                const tmp = std.fmt.bufPrint(&buf, "Hash mismatch for {s}: expected {s}, got {s}", .{ job.pkg_name, expected_hex, computed }) catch return;
                const msg = self.allocator.dupe(u8, tmp) catch return;
                w.sendWarning(msg);
            }
        }
    }

    /// Spawn `n` worker threads, then join them all.
    fn execute(self: *HashVerifyPool, n: usize) !void {
        if (n <= 1 or self.jobs.len <= 1) {
            self.run();
            return;
        }
        const num = @min(n, self.jobs.len);

        var threads: [8]std.Thread = undefined;
        var spawned: usize = 0;
        for (0..num) |i| {
            threads[i] = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, run, .{self}) catch |err| {
                if (err == error.SystemResources or err == error.ResourceLimitReached or err == error.OutOfMemory) break;
                return err;
            };
            spawned += 1;
        }
        for (0..spawned) |i| {
            threads[i].join();
        }
    }
};

pub const SyncCommand = struct {
    pub const name = "sync";
    pub const description = "Synchronize the current project environment";

    positionals: []const []const u8 = &.{},
    locked: bool = false,
    update: bool = false,
    check: bool = false,
    offline: bool = false,
    json: bool = false,
    quiet: bool = false,
    target_arg: ?[]const u8 = null,
    jobs_arg: ?[]const u8 = null,
    progress_arg: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon sync [flags]
            \\
            \\Synchronizes the project environment with moonstone.toml and moonstone.lock.
            \\
            \\Flags:
            \\  --locked     Error if moonstone.lock is out of sync
            \\  --update     Re-resolve dependencies and update moonstone.lock within constraints
            \\  --check      Validate lockfile/env without modifying files
            \\  --offline    Do not connect to remote registries
            \\  --target <triple>  Resolve and lock a concrete target profile
            \\  --jobs <N>   Limit concurrent realization workers (default: min(CPUs, 8))
            \\  --progress <mode>  Human output: auto, fancy, or plain
            \\  --quiet      Suppress all output; use exit status only
            \\  --json       Emit moonstone:cli-events:v1 NDJSON on stdout
            \\
        , .{});
    }

    pub fn run(self: SyncCommand, ctx: *router.Context) !void {
        if (self.quiet and (self.json or self.progress_arg != null)) return error.InvalidOutputMode;
        if (self.json and self.progress_arg != null) return error.InvalidOutputMode;
        if (self.jobs_arg) |jobs_arg| {
            const jobs = std.fmt.parseUnsigned(usize, jobs_arg, 10) catch return error.InvalidJobs;
            if (jobs == 0) return error.InvalidJobs;
        }
        if (self.progress_arg) |mode| {
            if (!std.mem.eql(u8, mode, "auto") and !std.mem.eql(u8, mode, "fancy") and !std.mem.eql(u8, mode, "plain")) {
                return error.InvalidOutputMode;
            }
        }

        // JSON mode: run synchronously with direct stdout (emitter handles output).
        // Non-JSON mode: run on a worker thread with the progress UI on the main thread.
        if (self.json) {
            return self.runImpl(ctx, .{ .direct = ctx.stdout });
        }
        if (self.progress_arg != null and std.mem.eql(u8, self.progress_arg.?, "plain")) {
            return self.runImpl(ctx, .{ .direct = ctx.stderr });
        }

        if (self.quiet) {
            return self.runImpl(ctx, .silent);
        }

        const force_fancy = self.progress_arg != null and std.mem.eql(u8, self.progress_arg.?, "fancy");
        if (!force_fancy and (ctx.env.get("CI") != null or ctx.env.get("MOONSTONE_NO_PROGRESS") != null)) {
            return self.runImpl(ctx, .{ .direct = ctx.stderr });
        }

        var data = SyncWorkData{ .cmd = self, .ctx = ctx };
        progress_runtime.runWithProgress(ctx.io, ctx.stderr, ctx.allocator, ctx.env, syncWorker, &data) catch |err| {
            if (data.error_detail) |detail| {
                ctx.error_detail = detail;
            }
            return err;
        };
    }

    pub fn runImpl(self: SyncCommand, ctx: *router.Context, backend: progress_runtime.ProgressBackend) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;
        const started_ns = nowNs(io);
        const jobs = try materializationJobs(self.jobs_arg);

        var stderr_silencer = try JsonStderrSilencer.init(io, self.json or self.quiet);
        defer stderr_silencer.deinit();
        profiler.mark("sync.begin");

        var report = SyncReport{};
        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| if (!self.check) {
            try e.emit(io, .START, name, "sync.begin", .{
                .locked = self.locked,
                .update = self.update,
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
            ctx.error_detail = .{ .message = .{ .msg = "moonstone.toml is missing [interpreter]. Run `moon interpreter set lua@5.4` or `moon interpreter set luajit@2.1` to select one." } };
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

        const build_env = try mt.resolveBuildEnv(allocator, env);
        defer {
            for (build_env) |be| {
                allocator.free(be.key);
                allocator.free(be.value);
            }
            allocator.free(build_env);
        }

        if (!self.json) backend.phase("Reading registry configuration...", .{});
        var profile_span = profiler.now();
        const registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        profiler.span("sync.registry.resolve", profile_span);
        defer moonstone.registry.core.deinitResolved(registries, allocator);

        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
        };
        const plain_progress = !self.json and self.progress_arg != null and std.mem.eql(u8, self.progress_arg.?, "plain");

        // Callback routing: direct mode uses the existing render callbacks,
        // queue mode sends events through the WorkerContext.
        const on_resolve_cb: ?moonstone.resolution.options.ResolveCallback = switch (backend) {
            .direct => if (plain_progress) null else @import("command.zig").onResolveEvent,
            .queue => progress_runtime.onResolveEventProgress,
            .silent => null,
        };
        const on_resolve_ctx: ?*anyopaque = switch (backend) {
            .direct => if (plain_progress) null else @ptrCast(&resolve_cb_ctx),
            .queue => @ptrCast(backend.queue),
            .silent => null,
        };
        const on_solver_cb: ?moonstone.resolution.solver.report.SolverCallback = switch (backend) {
            .direct => @import("command.zig").onSolverEvent,
            .queue => progress_runtime.onSolverEventProgress,
            .silent => null,
        };
        const on_solver_ctx: ?*anyopaque = switch (backend) {
            .direct => @ptrCast(&resolve_cb_ctx),
            .queue => @ptrCast(backend.queue),
            .silent => null,
        };
        const plain_task_writer: ?*std.Io.Writer = if (plain_progress) switch (backend) {
            .direct => |writer| writer,
            .queue, .silent => null,
        } else null;
        var plain_task_mutex: std.Io.Mutex = .init;
        const task_reporter = task_protocol.Reporter{
            .emitter = emitter,
            .wctx = switch (backend) {
                .direct => null,
                .queue => |worker| worker,
                .silent => null,
            },
            .plain_writer = plain_task_writer,
            .plain_mutex = if (plain_task_writer != null) &plain_task_mutex else null,
        };

        // Helper to check for user cancellation (Ctrl-C) in queue mode.
        const cancelled = switch (backend) {
            .direct => false,
            .queue => |w| w.isCancelled(),
            .silent => false,
        };
        if (cancelled) return error.Cancelled;

        // 1. Determine active runtime
        const resolve_started_ns = nowNs(io);
        const pkg_name = moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName());
        const pkg_ver = mt.runtimeConstraint();
        const host_target = try moonstone.platform.target.hostTarget(allocator);
        defer allocator.free(host_target);
        const lock_target = if (self.target_arg) |target| try allocator.dupe(u8, target) else try allocator.dupe(u8, host_target);
        defer allocator.free(lock_target);
        moonstone.platform.target.validate(lock_target) catch return error.UnsupportedTarget;
        const target_is_host = std.mem.eql(u8, lock_target, host_target);

        const needs_host_rockspec_parser = blk: {
            if (target_is_host) break :blk false;
            for (mt.dependencies.items) |dep| {
                const raw_spec = try dep.toSpecString(allocator);
                defer allocator.free(raw_spec);
                const spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, raw_spec);
                defer spec.deinit(allocator);
                if (try resolverForPackageSpec(&mt, spec) == .rocks) {
                    break :blk true;
                }
            }
            break :blk false;
        };

        if (!self.json) backend.phase("Resolving runtime {s}@{s}...", .{ pkg_name, pkg_ver });

        var coordinator = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
        profile_span = profiler.now();
        var rt_res = try coordinator.resolve(pkg_name, pkg_ver, idx, registries, .{
            .on_event = on_resolve_cb,
            .on_event_context = on_resolve_ctx,
            .offline = self.offline,
            .build_env = build_env,
            .target = lock_target,
        }, env);
        profiler.span("sync.runtime.resolve", profile_span);
        defer rt_res.deinit(allocator);
        const active_lua_abi = mt.runtimeAbi();

        if (emitter) |e| {
            try e.emit(io, .STATUS, rt_res.name, "runtime.resolved", .{
                .name = rt_res.name,
                .version = rt_res.version,
            });
        } else {
            backend.phaseDone("Using interpreter: {s}@{s}", .{ rt_res.name, rt_res.version });
        }

        var mat = moonstone.materialization.materializer.Materializer{
            .allocator = allocator,
            .io = io,
            .environ_map = env,
            .on_event = on_resolve_cb,
            .on_event_context = on_resolve_ctx,
        };

        profile_span = profiler.now();
        const rt_mat_res = switch (rt_res.location) {
            .local_store, .local_path => moonstone.materialization.materializer.MaterializeResult{
                .path = try allocator.dupe(u8, rt_res.local_path.?),
                .artifact_hash = try allocator.dupe(u8, rt_res.artifact_hash),
            },
            .remote => switch (rt_res.origin) {
                .moonstone_registry => |r| blk: {
                    const materialized = mat.materialize_remote(
                        r.url,
                        r.token,
                        r.descriptor_path,
                        rt_res.remote_desc.?,
                        r.artifact_idx,
                    ) catch |err| {
                        if (!target_is_host) {
                            moonstone.diagnostics.error_context.setFmt(
                                allocator,
                                "Target `{s}` needs a compatible runtime artifact for {s}@{s}. The selected registry artifact could not be materialized ({s}); publish or configure that target runtime before syncing this profile.",
                                .{ lock_target, rt_res.name, rt_res.version, @errorName(err) },
                            );
                            return error.ForeignTargetRuntimeUnavailable;
                        }
                        return err;
                    };
                    break :blk materialized;
                },
                else => return error.UnsupportedOriginForRuntime,
            },
        };
        profiler.span("sync.runtime.materialize", profile_span);
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

        // A foreign runtime must never execute on the host merely to evaluate
        // a LuaRocks declaration. When the manifest names a rocks dependency,
        // materialize the matching host runtime as an execution-only parser
        // tool. It is deliberately absent from the foreign profile and lock.
        var host_rockspec_parser: ?[]const u8 = null;
        defer if (host_rockspec_parser) |path| allocator.free(path);
        if (needs_host_rockspec_parser) {
            if (!self.json) backend.phase("Preparing host Lua parser for LuaRocks metadata...", .{});

            var parser_runtime = coordinator.resolve(pkg_name, pkg_ver, idx, registries, .{
                .on_event = on_resolve_cb,
                .on_event_context = on_resolve_ctx,
                .offline = self.offline,
                .build_env = build_env,
                .target = host_target,
            }, env) catch |err| {
                moonstone.diagnostics.error_context.setFmt(
                    allocator,
                    "Foreign target `{s}` requires a host Lua runtime to evaluate LuaRocks metadata for {s}@{s}; configure or publish the host runtime first ({s}).",
                    .{ lock_target, pkg_name, pkg_ver, @errorName(err) },
                );
                return error.ForeignTargetRocksParserUnavailable;
            };
            defer parser_runtime.deinit(allocator);

            const parser_materialized = switch (parser_runtime.location) {
                .local_store, .local_path => moonstone.materialization.materializer.MaterializeResult{
                    .path = try allocator.dupe(u8, parser_runtime.local_path.?),
                    .artifact_hash = try allocator.dupe(u8, parser_runtime.artifact_hash),
                },
                .remote => switch (parser_runtime.origin) {
                    .moonstone_registry => |r| mat.materialize_remote(
                        r.url,
                        r.token,
                        r.descriptor_path,
                        parser_runtime.remote_desc.?,
                        r.artifact_idx,
                    ) catch |err| {
                        moonstone.diagnostics.error_context.setFmt(
                            allocator,
                            "Foreign target `{s}` requires a materialized host Lua runtime to evaluate LuaRocks metadata ({s}).",
                            .{ lock_target, @errorName(err) },
                        );
                        return error.ForeignTargetRocksParserUnavailable;
                    },
                    else => return error.UnsupportedOriginForRuntime,
                },
            };
            defer parser_materialized.deinit(allocator);

            host_rockspec_parser = moonstone.resolution.sources.luarocks.find_runtime_lua_executable(
                allocator,
                io,
                parser_materialized.path,
                env,
            ) catch |err| {
                moonstone.diagnostics.error_context.setFmt(
                    allocator,
                    "Foreign target `{s}` cannot use the host runtime as a LuaRocks parser ({s}).",
                    .{ lock_target, @errorName(err) },
                );
                return error.ForeignTargetRocksParserUnavailable;
            };
        }

        // Enrich store-hit artifacts with source provenance from the registry.
        // When an artifact was already in the local store, the initial materialization
        // may have predated registry descriptors gaining source_url/source_kind.
        // This fetches the source payload and updates the on-disk manifest so that
        // downstream tools (e.g. Meteorite cross-compilation) can access source archives.
        if (rt_res.location == .local_store and !self.offline) {
            for (registries) |reg| {
                const remote_res = coordinator.resolve_remote(
                    pkg_name,
                    pkg_ver,
                    reg.url,
                    reg.token,
                    .{
                        .on_event = on_resolve_cb,
                        .on_event_context = on_resolve_ctx,
                        .offline = false,
                        .build_env = build_env,
                    },
                    env,
                ) catch null;
                if (remote_res) |rr| {
                    defer {
                        var mut_desc = rr.desc;
                        mut_desc.deinit(allocator);
                        allocator.free(rr.descriptor_path);
                    }
                    mat.enrich_source_provenance(
                        rt_mat_res.path,
                        reg.url,
                        reg.token,
                        rr.descriptor_path,
                        rr.desc,
                        rr.artifact_idx,
                    ) catch |err| {
                        // Best-effort: enrichment failure should not break sync
                        if (!self.json) backend.warning("source provenance enrichment skipped: {s}", .{@errorName(err)});
                    };
                    break;
                }
            }
        }

        mat.runtime_path = rt_mat_res.path;
        const runtime_c_api = moonstone.runtime.c_api.fromRuntime(rt_res.name, rt_res.lua_api, active_lua_abi);
        const rt_recipe_options = moonstone.store.facade.RecipeOptions{
            .kind = @tagName(rt_res.kind),
            .name = rt_res.name,
            .version = rt_res.version,
            .source_hash = if (rt_res.remote_desc) |rd| rd.artifact[rt_res.artifact_idx orelse 0].hash else "",
            .materializer = if (rt_res.remote_desc) |rd| (if (rd.artifact[0].materialize) |m| m.kind else "prebuilt") else "prebuilt",
            .strategy = if (rt_res.remote_desc) |rd| (if (rd.artifact[0].materialize) |m| m.strategy orelse "default" else "local") else "local",
            .lua_abi = active_lua_abi,
            .target = lock_target,
        };

        profile_span = profiler.now();
        const rt_recipe_hash = try moonstone.store.facade.computeRecipeHash(allocator, rt_recipe_options);
        profiler.span("sync.runtime.recipe_hash", profile_span);
        defer allocator.free(rt_recipe_hash);

        // 2. Solve dependencies
        profile_span = profiler.now();
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

            const selected_resolver = try resolverForPackageSpec(&mt, spec);

            try targets.append(allocator, .{
                .name = try allocator.dupe(u8, if (selected_resolver == .rocks) spec.name else dep.name),
                .range = try moonstone.domain.semver.VersionRange.parse(allocator, spec.constraint orelse "*"),
                .resolver = selected_resolver,
                .registry = try registryIdentityForPackageSpec(allocator, spec, selected_resolver),
                .role = dep.role,
            });
        }
        profiler.spanCount("sync.targets.build", profile_span, "targets", targets.items.len);

        profile_span = profiler.now();
        var provider_impl = try allocator.create(moonstone.resolution.provider.graph_provider.RegistryProvider);
        provider_impl.init(allocator, io, idx, registries, .{
            .on_event = on_resolve_cb,
            .on_event_context = on_resolve_ctx,
            .offline = self.offline,
            .prefer_local = !self.update,
            .runtime = active_lua_abi,
            .runtime_c_api = runtime_c_api,
            .runtime_artifact_hash = rt_res.artifact_hash,
            .runtime_path = rt_mat_res.path,
            .build_env = build_env,
            .target = lock_target,
        }, env, host_rockspec_parser, targets.items);
        profiler.spanCount("sync.provider.plan", profile_span, "targets", targets.items.len);
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

        // v3 locks carry multiple target profiles. Select only the requested
        // target/runtime/ABI closure; legacy flat locks are migration input and
        // must be refreshed before they can be replayed normally.
        var replay_entries = std.ArrayList(*const moonstone.domain.lockfile.LockEntry).empty;
        defer replay_entries.deinit(allocator);
        const selected_profile = if (existing_lock.version == 3)
            existing_lock.findExactProfile(lock_target, rt_res.name, active_lua_abi)
        else
            null;
        if (selected_profile) |profile| {
            for (profile.packages) |reference| {
                const realization = existing_lock.findRealization(reference.realization_hash) orelse return error.LockfileOutOfSync;
                try replay_entries.append(allocator, realization);
            }
        } else if (existing_lock.version == 2) {
            for (existing_lock.packages.items) |*entry| try replay_entries.append(allocator, entry);
        }

        var solution: std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact) = .empty;
        defer {
            var sit = solution.iterator();
            while (sit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            solution.deinit(allocator);
        }

        const lock_runtime_matches = lockedEntriesRuntimeMatch(replay_entries.items, rt_res.name, rt_res.version, active_lua_abi);
        const lock_deps_match = lockedEntriesDependenciesMatch(mt.dependencies.items, replay_entries.items);
        const lock_target_state = lockReplayEntriesTargetState(replay_entries.items, lock_target);
        if (self.locked) {
            if (existing_lock.version == 3 and selected_profile == null) {
                moonstone.diagnostics.error_context.setFmt(
                    allocator,
                    "moonstone.lock has no profile for target `{s}`, runtime `{s}`, and Lua ABI `{s}`. Run `moon sync --target {s}` first.",
                    .{ lock_target, rt_res.name, active_lua_abi, lock_target },
                );
                return error.LockedProfileMissing;
            }
            switch (lock_target_state) {
                .compatible => {},
                .legacy_native => {
                    moonstone.diagnostics.error_context.setFmt(
                        allocator,
                        "moonstone.lock uses the legacy target `native`. Run `moon sync --update` to record the concrete host target `{s}` before using `--locked`.",
                        .{lock_target},
                    );
                    return error.LegacyNativeLockTarget;
                },
                .incompatible => {
                    moonstone.diagnostics.error_context.setFmt(
                        allocator,
                        "moonstone.lock targets a different host realization. Run `moon sync --update` on `{s}` to create its concrete target profile.",
                        .{lock_target},
                    );
                    return error.LockedTargetIncompatible;
                },
            }
        }
        if (!self.update and existing_lock.packages.items.len > 0 and (!lock_runtime_matches or !lock_deps_match)) {
            if (!lock_runtime_matches) profiler.mark("sync.lock.replay.skip.runtime_mismatch");
            if (!lock_deps_match) profiler.mark("sync.lock.replay.skip.dependencies_changed");
        }
        const can_replay_lock = !self.update and existing_lock.version == 3 and selected_profile != null and replay_entries.items.len > 0 and lock_runtime_matches and lock_deps_match and lock_target_state == .compatible;
        const replay_lock = self.locked or can_replay_lock;

        if (replay_lock) {
            // Lockfile replay mode: bypass PubGrub and retrieve exact artifacts by hash.
            // This is the default fast path; use --update to ask PubGrub for the newest
            // versions allowed by moonstone.toml constraints.
            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.locked_replay", .{ .packages = replay_entries.items.len });
            } else {
                backend.phase("Replaying target profile ({d} package{s})...", .{ replay_entries.items.len, if (replay_entries.items.len == 1) "" else "s" });
            }

            profile_span = profiler.now();
            var locked_replay_jobs = std.ArrayList(LockedReplayJob).empty;
            defer {
                for (locked_replay_jobs.items) |*job| job.deinit(allocator);
                locked_replay_jobs.deinit(allocator);
            }
            for (replay_entries.items) |entry| {
                const is_link = std.mem.eql(u8, entry.artifact_hash, "link");
                const is_path = std.mem.eql(u8, entry.artifact_hash, "path");

                if (is_link or is_path) {
                    // Link/path entries are reconstructed directly from lockfile metadata
                    const source_path = if (entry.source.len > 0) entry.source else "";
                    try checkLocalSourceAvailableForReplay(allocator, io, entry.name, entry.version, if (is_link) "link" else "path", source_path);
                    try checkLinkedRuntimeAbiForReplay(allocator, io, ctx, &mt, active_lua_abi, entry.name, entry.version, source_path);
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

                try locked_replay_jobs.append(allocator, .{ .entry = entry });
            }

            if (locked_replay_jobs.items.len > 0) {
                var mutex_alloc = MutexAllocator{
                    .parent = allocator,
                    .io = io,
                };
                var pool = LockedReplayPool{
                    .allocator = mutex_alloc.allocator(),
                    .io = io,
                    .env = env,
                    .index_db_path_z = index_db_path_z,
                    .registries = registries,
                    .provider_options = provider_impl.options,
                    .lua_exe = host_rockspec_parser,
                    .targets = targets.items,
                    .target = lock_target,
                    .jobs = locked_replay_jobs.items,
                    .policy = .{
                        .offline = self.offline,
                        .allow_remote_artifacts = true,
                        .allow_source_rematerialization = true,
                    },
                    .wctx = switch (backend) {
                        .direct => null,
                        .queue => |w| w,
                        .silent => null,
                    },
                    .reporter = task_reporter,
                };
                try pool.execute(jobs);
            }

            for (locked_replay_jobs.items) |*job| {
                if (job.err) |err| {
                    const entry = job.entry;
                    if (err == error.LockedArtifactMissing) {
                        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                        ctx.error_detail = .{
                            .locked_artifact_missing = .{
                                .name = try ctx.allocator.dupe(u8, entry.name),
                                .version = try ctx.allocator.dupe(u8, entry.version),
                                .resolver = if (entry.resolver.len > 0) try ctx.allocator.dupe(u8, entry.resolver) else null,
                                .artifact_hash = try ctx.allocator.dupe(u8, entry.artifact_hash),
                            },
                        };
                    }
                    return err;
                }

                const candidate = job.result orelse return error.LockedReplayMissingResult;
                try solution.put(allocator, try allocator.dupe(u8, job.entry.name), candidate);
                job.result = null;
            }

            report.requested_targets = replay_entries.items.len;
            report.resolved_packages = solution.count();
            report.resolve_ms = elapsedMs(io, resolve_started_ns);
            profiler.spanCount("sync.lock.replay", profile_span, "packages", solution.count());
            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.complete", .{
                    .requested_targets = report.requested_targets,
                    .resolved_packages = report.resolved_packages,
                    .elapsed_ms = report.resolve_ms,
                });
            }
        } else {
            if (replay_entries.items.len > 0 and !lock_deps_match and !self.json) {
                backend.phase("moonstone.toml changed; resolving a new lockfile...", .{});
            } else if (self.update and !self.json) {
                backend.phase("Updating lockfile within declared constraints...", .{});
            }
            profile_span = profiler.now();
            var solver = moonstone.resolution.solver.pubgrub.Solver.init(allocator, provider_impl.get_provider(), .{
                .on_event = on_solver_cb,
                .on_event_context = on_solver_ctx,
            });
            defer solver.deinit();
            profiler.span("sync.pubgrub.init", profile_span);

            if (emitter) |e| {
                try e.emit(io, .STATUS, name, "resolution.begin", .{ .targets = targets.items.len });
            } else {
                backend.phase("Solving dependencies...", .{});
            }
            profile_span = profiler.now();
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
                    if (solver.last_conflict) |inc| {
                        var aw = std.Io.Writer.Allocating.init(allocator);
                        defer aw.deinit();
                        try moonstone.resolution.solver.report.explain(&aw.writer, inc, allocator);
                        ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]) } };
                    } else {
                        ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, "No compatible resolution could be found.") } };
                    }
                    return err;
                }
                if (err == error.LinkedRuntimeAbiMismatch) {
                    if (provider_impl.linked_runtime_diagnostic) |diag| {
                        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                        if (diag.suggested_role) |sr| {
                            ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}\nIf this is a development CLI tool, add it with --{s} instead.", .{ diag.package_name, diag.package_version, diag.required_abi, diag.active_abi, diag.manifest_path, sr }) } };
                        } else {
                            ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}", .{ diag.package_name, diag.package_version, diag.required_abi, diag.active_abi, diag.manifest_path }) } };
                        }
                    }
                }
                return err;
            };
            profiler.spanCount("sync.pubgrub.solve", profile_span, "packages", solution.count());
            if (!self.json) backend.phaseDone("Resolved {d} dependencies.", .{solution.count()});
            profile_span = profiler.now();
            for (mt.dependencies.items) |dep| {
                const raw_spec = try dep.toSpecString(allocator);
                defer allocator.free(raw_spec);
                const spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, raw_spec);
                defer spec.deinit(allocator);

                const selected_resolver = try resolverForPackageSpec(&mt, spec);
                const dep_name = if (selected_resolver == .rocks) spec.name else dep.name;

                // LuaRocks source candidates must remain in the post-solve
                // realization pool so their build-only closure can be
                // materialized and projected before the parent build. Other
                // explicit resolvers retain the legacy direct path below.
                const force_direct = selected_resolver != .rocks and (spec.resolver != null or spec.registry != null);
                if (solutionContainsPackage(&solution, dep_name) and !force_direct) continue;

                var resolved_direct_opt: ?moonstone.resolution.candidate.ResolvedArtifact = null;
                const resolver_query_name = switch (selected_resolver) {
                    .path, .link, .artifact => spec.name,
                    else => dep_name,
                };
                if (selected_resolver != .moonstone and selected_resolver != .rocks) {
                    resolved_direct_opt = blk: {
                        break :blk coordinator.resolveWithKind(resolver_query_name, spec.constraint orelse "*", idx, registries, .{
                            .offline = self.offline,
                            .prefer_local = !self.update,
                            .runtime = active_lua_abi,
                            .runtime_c_api = runtime_c_api,
                            .runtime_artifact_hash = rt_res.artifact_hash,
                            .runtime_path = rt_mat_res.path,
                            .on_event = on_resolve_cb,
                            .on_event_context = on_resolve_ctx,
                            .build_env = build_env,
                        }, selected_resolver, env, spec.registry) catch |err| {
                            if (err == error.UnsupportedLuaRocksBuildType and (spec.resolver != null or spec.registry != null)) return err;
                            if (err == error.PackageNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) break :blk null;
                            return err;
                        };
                    };
                }
                if (resolved_direct_opt == null and selected_resolver == .moonstone) {
                    const registry_name = spec.registry orelse "moonstone";
                    for (registries) |reg| {
                        if (!std.mem.eql(u8, reg.name, registry_name)) continue;
                        const remote = coordinator.resolve_remote(dep_name, spec.constraint orelse "*", reg.url, reg.token, .{
                            .offline = self.offline,
                            .prefer_local = !self.update,
                            .runtime = active_lua_abi,
                            .runtime_artifact_hash = rt_res.artifact_hash,
                            .runtime_path = rt_mat_res.path,
                            .on_event = on_resolve_cb,
                            .on_event_context = on_resolve_ctx,
                            .build_env = build_env,
                        }, env) catch continue;
                        resolved_direct_opt = .{
                            .name = try allocator.dupe(u8, dep_name),
                            .version = try allocator.dupe(u8, remote.desc.package.version),
                            .kind = remote.desc.package.kind,
                            .artifact_hash = try allocator.dupe(u8, remote.desc.artifact[remote.artifact_idx].hash),
                            .lua_abi = try allocator.dupe(u8, remote.desc.artifact[remote.artifact_idx].lua_abi),
                            .remote_desc = remote.desc,
                            .registry_name = try allocator.dupe(u8, reg.name),
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

                if (resolved_direct.local_path) |linked_path| {
                    if (std.mem.eql(u8, resolved_direct.artifact_hash, "link") or std.mem.eql(u8, resolved_direct.artifact_hash, "path")) {
                        const manifest_path = try std.fs.path.join(allocator, &.{ linked_path, "moonstone.toml" });
                        defer allocator.free(manifest_path);
                        const linked_content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                            if (err == error.FileNotFound) continue;
                            return err;
                        };
                        defer allocator.free(linked_content);
                        var linked_mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, linked_content);
                        defer linked_mt.deinit(allocator);

                        for (linked_mt.dependencies.items) |child_dep| {
                            const child_raw_spec = try child_dep.toSpecString(allocator);
                            defer allocator.free(child_raw_spec);
                            const child_spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, child_raw_spec);
                            defer child_spec.deinit(allocator);
                            const child_resolver = try resolverForPackageSpec(&linked_mt, child_spec);
                            const child_name = if (child_resolver == .rocks) child_spec.name else child_dep.name;
                            if (solutionContainsPackage(&solution, child_name)) continue;

                            var child_kinds_buf: [4]moonstone.resolution.coordinator.CoordinatorKind = undefined;
                            var child_kinds_len: usize = 0;
                            child_kinds_buf[child_kinds_len] = child_resolver;
                            child_kinds_len += 1;

                            const child_query_name = switch (child_resolver) {
                                .path, .link, .artifact => child_spec.name,
                                else => child_name,
                            };
                            var resolved_child_opt: ?moonstone.resolution.candidate.ResolvedArtifact = null;
                            for (child_kinds_buf[0..child_kinds_len]) |kind| {
                                resolved_child_opt = coordinator.resolveWithKind(child_query_name, child_spec.constraint orelse "*", idx, registries, .{
                                    .offline = self.offline,
                                    .runtime = active_lua_abi,
                                    .runtime_artifact_hash = rt_res.artifact_hash,
                                    .runtime_path = rt_mat_res.path,
                                    .on_event = on_resolve_cb,
                                    .on_event_context = on_resolve_ctx,
                                    .build_env = build_env,
                                }, kind, env, child_spec.registry) catch |err| {
                                    if (err == error.PackageNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
                                    return err;
                                };
                                if (resolved_child_opt != null) break;
                            }
                            var resolved_child = resolved_child_opt orelse return error.PackageNotFound;
                            errdefer resolved_child.deinit(allocator);
                            try solution.put(allocator, try allocator.dupe(u8, child_name), resolved_child);
                        }
                    }
                }
            }

            // Direct path/link dependencies are resolved outside PubGrub so their
            // local manifests can participate in the project closure. A linked
            // project can introduce a registry package whose descriptor has
            // further dependencies (for example Meteorite -> Ballad -> dkjson).
            // Expand discovered descriptors to a fixed point before scope linking.
            var expanded_descriptors = std.StringArrayHashMapUnmanaged(void).empty;
            defer {
                var expanded_it = expanded_descriptors.iterator();
                while (expanded_it.next()) |entry| allocator.free(entry.key_ptr.*);
                expanded_descriptors.deinit(allocator);
            }
            while (expanded_descriptors.count() < solution.count()) {
                var package_names = std.ArrayList([]const u8).empty;
                defer {
                    for (package_names.items) |package_name| allocator.free(package_name);
                    package_names.deinit(allocator);
                }
                for (solution.keys()) |package_name| {
                    try package_names.append(allocator, try allocator.dupe(u8, package_name));
                }

                for (package_names.items) |parent_name| {
                    if (expanded_descriptors.contains(parent_name)) continue;
                    try expanded_descriptors.put(allocator, try allocator.dupe(u8, parent_name), {});

                    const parent = solution.getPtr(parent_name) orelse continue;
                    var child_specs = std.ArrayList([]const u8).empty;
                    defer {
                        for (child_specs.items) |child_spec| allocator.free(child_spec);
                        child_specs.deinit(allocator);
                    }

                    if (parent.remote_desc) |remote_desc| {
                        for (remote_desc.dependencies) |child_dep| {
                            try child_specs.append(allocator, try child_dep.toSpecString(allocator));
                        }
                    } else if (parent.local_path) |local_path| {
                        const manifest_path = try std.fs.path.join(allocator, &.{ local_path, "manifest.toml" });
                        defer allocator.free(manifest_path);
                        const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| switch (err) {
                            error.FileNotFound => null,
                            else => return err,
                        };
                        if (content) |store_content| {
                            defer allocator.free(store_content);
                            var store_manifest = try moonstone.domain.manifest.StoreManifest.parse(allocator, store_content);
                            defer store_manifest.deinit(allocator);
                            for (store_manifest.dependencies) |child_dep| {
                                try child_specs.append(allocator, try child_dep.toSpecString(allocator));
                            }
                        }
                    }

                    for (child_specs.items) |child_raw_spec| {
                        const child_spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, child_raw_spec);
                        defer child_spec.deinit(allocator);
                        const child_resolver = try resolverForPackageSpec(&mt, child_spec);
                        const child_name = child_spec.name;
                        if (solutionContainsPackage(&solution, child_name)) continue;

                        var child_kinds_buf: [4]moonstone.resolution.coordinator.CoordinatorKind = undefined;
                        var child_kinds_len: usize = 0;
                        child_kinds_buf[child_kinds_len] = child_resolver;
                        child_kinds_len += 1;

                        const child_query_name = switch (child_resolver) {
                            .path, .link, .artifact => child_spec.name,
                            else => child_name,
                        };
                        var resolved_child_opt: ?moonstone.resolution.candidate.ResolvedArtifact = null;
                        for (child_kinds_buf[0..child_kinds_len]) |kind| {
                            resolved_child_opt = coordinator.resolveWithKind(child_query_name, child_spec.constraint orelse "*", idx, registries, .{
                                .offline = self.offline,
                                .prefer_local = !self.update,
                                .runtime = active_lua_abi,
                                .runtime_c_api = runtime_c_api,
                                .runtime_artifact_hash = rt_res.artifact_hash,
                                .runtime_path = rt_mat_res.path,
                                .on_event = on_resolve_cb,
                                .on_event_context = on_resolve_ctx,
                                .build_env = build_env,
                            }, kind, env, child_spec.registry) catch |err| {
                                if (err == error.PackageNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
                                return err;
                            };
                            if (resolved_child_opt != null) break;
                        }
                        var resolved_child = resolved_child_opt orelse return error.PackageNotFound;
                        errdefer resolved_child.deinit(allocator);
                        try solution.put(allocator, try allocator.dupe(u8, resolved_child.name), resolved_child);
                    }
                }
            }
            profiler.spanCount("sync.direct.resolve", profile_span, "packages", solution.count());

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
            const selected_resolver = try resolverForPackageSpec(&mt, spec);
            const dep_pkg_name = if (selected_resolver == .rocks) spec.name else dep.name;
            const group_name = @tagName(dep.role);
            try group_ctx.addGroup(dep_pkg_name, group_name);
        }

        // Step 2: Build dependency graph from resolved packages
        const DependencyGraphEdge = struct {
            name: []const u8,
            role: moonstone.domain.manifest.DependencyRole,
        };
        var dep_graph = std.StringArrayHashMapUnmanaged(std.ArrayList(DependencyGraphEdge)).empty;
        defer {
            var dit = dep_graph.iterator();
            while (dit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |edge| allocator.free(edge.name);
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
                    var deps = std.ArrayList(DependencyGraphEdge).empty;
                    errdefer {
                        for (deps.items) |edge| allocator.free(edge.name);
                        deps.deinit(allocator);
                    }

                    if (pkg.remote_desc) |desc| {
                        for (desc.dependencies) |dep| {
                            const dep_name = dep.name;
                            try deps.append(allocator, .{
                                .name = try allocator.dupe(u8, dep_name),
                                .role = dep.role,
                            });
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
                                    const selected_resolver = try resolverForPackageSpec(&mt, dspec);
                                    const dname = if (selected_resolver == .rocks) dspec.name else dep.name;
                                    try deps.append(allocator, .{
                                        .name = try allocator.dupe(u8, dname),
                                        .role = dep.role,
                                    });
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
                                    try deps.append(allocator, .{
                                        .name = try allocator.dupe(u8, dep.name),
                                        .role = dep.role,
                                    });
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

        // Source LuaRocks candidates are still remote at this point, so their
        // manifest cannot yet provide edges above. Preserve the role-aware
        // metadata captured by the graph provider during PubGrub discovery.
        for (provider_impl.store_dependency_origins.items) |origin| {
            if (!solutionContainsPackage(&solution, origin.parent_name) or !solutionContainsPackage(&solution, origin.child_name)) continue;
            const gop = try dep_graph.getOrPut(allocator, origin.parent_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try allocator.dupe(u8, origin.parent_name);
                gop.value_ptr.* = std.ArrayList(DependencyGraphEdge).empty;
            }
            try gop.value_ptr.append(allocator, .{
                .name = try allocator.dupe(u8, origin.child_name),
                .role = origin.child_role,
            });
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
                    for (children.items) |edge| {
                        const parent_role = moonstone.domain.manifest.parseDependencyRole(current.group) catch return error.InvalidDependencyRole;
                        const child_role = if (edge.role == .runtime) parent_role else edge.role;
                        try queue.append(allocator, .{
                            .name = try allocator.dupe(u8, edge.name),
                            .group = try allocator.dupe(u8, @tagName(child_role)),
                        });
                    }
                }
            }
        }

        // 3. Materialize all chosen artifacts
        const materialize_started_ns = nowNs(io);
        profile_span = profiler.now();
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "materialization.begin", .{ .packages = report.resolved_packages });
        } else {
            backend.phase("Materializing {d} packages...", .{solution.count()});
        }

        // Check for cancellation before starting materialization.
        if (switch (backend) {
            .direct => false,
            .queue => |w| w.isCancelled(),
            .silent => false,
        }) return error.Cancelled;

        // ── Phase 1: Parallel download + materialize remote packages ───────
        var download_jobs = std.ArrayList(DownloadJob).empty;
        defer download_jobs.deinit(allocator);
        var job_map = std.StringHashMap(usize).init(allocator);
        defer job_map.deinit();
        var rocks_jobs = std.ArrayList(RocksJob).empty;
        defer {
            for (rocks_jobs.items) |*job| job.deinit(allocator);
            rocks_jobs.deinit(allocator);
        }

        {
            var prescan = solution.iterator();
            while (prescan.next()) |entry| {
                const p = entry.value_ptr.*;
                if (p.location == .remote and p.origin == .moonstone_registry) {
                    try download_jobs.append(allocator, .{ .pkg = entry.value_ptr });
                    try job_map.put(try allocator.dupe(u8, entry.key_ptr.*), download_jobs.items.len - 1);
                } else if (p.location == .remote and p.origin == .luarocks) {
                    var job = RocksJob{ .pkg = entry.value_ptr };
                    job.build_dependency_names = try collectSolvedRocksDependencyNames(
                        allocator,
                        provider_impl.store_dependency_origins.items,
                        &solution,
                        p.name,
                        false,
                    );
                    errdefer {
                        for (job.build_dependency_names) |dependency_name| allocator.free(dependency_name);
                        if (job.build_dependency_names.len > 0) allocator.free(job.build_dependency_names);
                    }
                    job.scope_dependency_names = try collectSolvedRocksDependencyNames(
                        allocator,
                        provider_impl.store_dependency_origins.items,
                        &solution,
                        p.name,
                        true,
                    );
                    try rocks_jobs.append(allocator, job);
                }
            }
        }

        if (download_jobs.items.len > 0 or rocks_jobs.items.len > 0) {
            var mutex_alloc = MutexAllocator{
                .parent = allocator,
                .io = io,
            };
            const safe_allocator = mutex_alloc.allocator();
            if (download_jobs.items.len > 0) {
                var pool = DownloadPool{
                    .allocator = safe_allocator,
                    .io = io,
                    .env = env,
                    .jobs = download_jobs.items,
                    .target = lock_target,
                    .runtime_path = rt_mat_res.path,
                    .wctx = switch (backend) {
                        .direct => null,
                        .queue => |w| w,
                        .silent => null,
                    },
                    .reporter = task_reporter,
                    .on_resolve_cb = on_resolve_cb,
                    .on_resolve_ctx = on_resolve_ctx,
                };
                try pool.execute(jobs);
            }
            if (rocks_jobs.items.len > 0) {
                var pool = RocksPool{
                    .allocator = safe_allocator,
                    .io = io,
                    .env = env,
                    .jobs = rocks_jobs.items,
                    .selected = &solution,
                    .downloaded = download_jobs.items,
                    .target = lock_target,
                    .options = .{
                        .on_event = on_resolve_cb,
                        .on_event_context = on_resolve_ctx,
                        .offline = self.offline,
                        .runtime = active_lua_abi,
                        .runtime_c_api = runtime_c_api,
                        .runtime_artifact_hash = rt_res.artifact_hash,
                        .runtime_path = rt_mat_res.path,
                        .lua_exe = host_rockspec_parser,
                        .build_env = build_env,
                        .target = lock_target,
                    },
                    .wctx = switch (backend) {
                        .direct => null,
                        .queue => |w| w,
                        .silent => null,
                    },
                    .reporter = task_reporter,
                    .preparation_coordinator = moonstone.realization.request_coordinator.RequestCoordinator.init(safe_allocator),
                    .request_coordinator = moonstone.realization.request_coordinator.RequestCoordinator.init(safe_allocator),
                };
                defer pool.deinit();
                try pool.execute(jobs);
            }
        }

        // Check for download errors before proceeding to serial phase.
        for (download_jobs.items) |dj| {
            if (dj.err) |err| {
                // Stash error detail for the main thread.
                if (dj.pkg.name.len > 0) {
                    ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "Failed to materialize {s}: {s}", .{ dj.pkg.name, @errorName(err) }) } };
                }
                return err;
            }
        }
        for (rocks_jobs.items) |*job| {
            if (job.err) |err| {
                ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "Failed to materialize {s}: {s}", .{ job.pkg.name, @errorName(err) }) } };
                return err;
            }
            if (job.result) |result| {
                job.pkg.*.deinit(allocator);
                job.pkg.* = result;
                job.pkg.*.location = .local_store;
                job.result = null;
                report.materializations += 1;
            }
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
                .role = .runtime,
            });
        } else {
            try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &rt_res, rt_mat_res.path, rt_mat_res.artifact_hash, .runtime));
        }

        // v2 and early v3 locks have a flat realization set without profile
        // ownership. They are migration input, not a second target closure to
        // preserve. Once v3 profiles exist, retain all other target profiles.
        var next_lock = if (existing_lock.version == 3 and existing_lock.profiles.items.len > 0)
            try existing_lock.clone(allocator)
        else
            moonstone.domain.lockfile.LockFile.init(allocator);
        defer next_lock.deinit();
        const new_realization_start = next_lock.packages.items.len;

        if (!replay_lock) {
            try next_lock.packages.append(allocator, .{
                .name = try allocator.dupe(u8, rt_res.name),
                .version = try allocator.dupe(u8, rt_res.version),
                .kind = rt_res.kind,
                .source_hash = if (rt_res.remote_desc) |descriptor| try allocator.dupe(u8, descriptor.artifact[rt_res.artifact_idx orelse 0].hash) else &.{},
                .recipe_hash = try allocator.dupe(u8, rt_recipe_hash),
                .artifact_hash = try allocator.dupe(u8, rt_mat_res.artifact_hash),
                .runtime = try allocator.dupe(u8, rt_res.name),
                .lua_abi = try allocator.dupe(u8, active_lua_abi),
                .target = try allocator.dupe(u8, lock_target),
                .constellation = try allocator.dupe(u8, "default"),
                .resolver = try allocator.dupe(u8, "moonstone"),
                .registry = &.{},
                .source = &.{},
                .source_kind = try allocator.dupe(u8, "runtime"),
                .source_payload = &.{},
                .source_url = &.{},
                .rockspec = &.{},
                .rockspec_hash = &.{},
                .rockspec_payload = &.{},
                .replay_mode = .artifact_only,
                .roles = &.{},
            });
        }

        var sit = solution.iterator();
        var materialize_index: usize = 0;
        const materialize_total = solution.count();
        while (sit.next()) |entry| {
            materialize_index += 1;
            const pkg_name_sol = entry.key_ptr.*;
            const pkg = entry.value_ptr.*;

            if (!self.json) {
                backend.status("materialize", "Materializing [{d}/{d}] {s}@{s}...", .{ materialize_index, materialize_total, pkg.name, pkg.version });
            }

            if (!target_is_host and pkg.local_path != null) {
                moonstone.diagnostics.error_context.setFmt(
                    allocator,
                    "Cannot realize live {s} dependency {s}@{s} for foreign target `{s}`. Use a registry or artifact-backed dependency for cross-target profiles.",
                    .{ if (std.mem.eql(u8, pkg.artifact_hash, "link")) "link" else "path", pkg.name, pkg.version, lock_target },
                );
                return error.ForeignTargetLiveSourceUnsupported;
            }
            if (pkg.local_path) |lp| {
                // If it's a link or path, handle it separately
                const is_link = std.mem.eql(u8, pkg.artifact_hash, "link");
                const is_path = std.mem.eql(u8, pkg.artifact_hash, "path");

                if (is_link or is_path) {
                    var entry_roles = std.ArrayList([]const u8).empty;
                    defer {
                        for (entry_roles.items) |group| allocator.free(group);
                        entry_roles.deinit(allocator);
                    }
                    if (package_roles.get(pkg.name)) |groups| {
                        for (groups.items) |group| {
                            try entry_roles.append(allocator, try allocator.dupe(u8, group));
                        }
                    }
                    try next_lock.packages.append(allocator, .{
                        .name = try allocator.dupe(u8, pkg.name),
                        .version = try allocator.dupe(u8, pkg.version),
                        .kind = pkg.kind,
                        .source_hash = &.{},
                        .recipe_hash = &.{},
                        .artifact_hash = try allocator.dupe(u8, pkg.artifact_hash),
                        .runtime = try allocator.dupe(u8, active_lua_abi),
                        .lua_abi = try allocator.dupe(u8, pkg.lua_abi orelse active_lua_abi),
                        .target = try allocator.dupe(u8, lock_target),
                        .constellation = try allocator.dupe(u8, "default"),
                        .resolver = try allocator.dupe(u8, if (is_link) "link" else "path"),
                        .registry = try lockRegistryForPackage(allocator, &pkg, &existing_lock),
                        .source = try allocator.dupe(u8, lp),
                        .source_kind = try allocator.dupe(u8, if (is_link) "live_link" else "local_path"),
                        .source_payload = &.{},
                        .source_url = &.{},
                        .rockspec = &.{},
                        .rockspec_hash = &.{},
                        .rockspec_payload = &.{},
                        .replay_mode = .artifact_only,
                        .roles = try entry_roles.toOwnedSlice(allocator),
                    });
                    try live_links.append(allocator, .{
                        .name = try allocator.dupe(u8, pkg_name_sol),
                        .source_path = try allocator.dupe(u8, lp),
                        .mode = try allocator.dupe(u8, if (is_link) "link" else "path"),
                        .pkg_name = try allocator.dupe(u8, pkg.name),
                        .pkg_version = try allocator.dupe(u8, pkg.version),
                        .pkg_kind = pkg.kind,
                        .role = roleForResolvedPackage(&mt, pkg_name_sol),
                    });
                    report.path_link_projections += 1;
                    continue;
                }

                if (pkg.artifact_hash.len > 0) {
                    if (std.mem.eql(u8, pkg.name, rt_res.name)) {
                        continue;
                    } else if (replay_lock) {
                        const lock_entry = findReplayEntry(replay_entries.items, pkg.name) orelse return error.LockfileOutOfSync;
                        if (!std.mem.eql(u8, lock_entry.version, pkg.version)) return error.LockfileOutOfSync;
                        if (moonstone.resolution.locked_realizer.requiresExactArtifactHash(lock_entry) and !std.mem.eql(u8, lock_entry.artifact_hash, pkg.artifact_hash)) {
                            moonstone.diagnostics.error_context.setFmt(
                                allocator,
                                "Locked artifact hash mismatch for {s}@{s}. Expected {s}, but replay produced {s}. Restore the exact artifact or run 'moon sync --update' to create a new lockfile.",
                                .{ pkg.name, pkg.version, lock_entry.artifact_hash, pkg.artifact_hash },
                            );
                            return error.ArtifactHashMismatch;
                        }
                        if (lock_entry.source_hash.len > 0 and pkg.source_hash.len > 0 and !std.mem.eql(u8, lock_entry.source_hash, pkg.source_hash)) return error.LockfileOutOfSync;
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
                        var store_prov_opt = @import("lock_provenance.zig").read(allocator, io, lp) catch null;
                        defer if (store_prov_opt) |*store_prov| store_prov.deinit(allocator);
                        const store_source_hash = if (store_prov_opt) |store_prov| store_prov.source_hash else "";
                        const store_recipe_hash = if (store_prov_opt) |store_prov| store_prov.recipe_hash else "";
                        const store_source = if (store_prov_opt) |store_prov| store_prov.source else "";
                        const store_source_kind = if (store_prov_opt) |store_prov| store_prov.source_kind else "";
                        const store_source_payload = if (store_prov_opt) |store_prov| store_prov.source_payload else "";
                        const store_source_url = if (store_prov_opt) |store_prov| store_prov.source_url else "";
                        const store_rockspec = if (store_prov_opt) |store_prov| store_prov.rockspec else "";
                        const store_rockspec_hash = if (store_prov_opt) |store_prov| store_prov.rockspec_hash else "";
                        const store_rockspec_payload = if (store_prov_opt) |store_prov| store_prov.rockspec_payload else "";
                        try next_lock.packages.append(allocator, .{
                            .name = try allocator.dupe(u8, pkg.name),
                            .version = try allocator.dupe(u8, pkg.version),
                            .kind = pkg.kind,
                            .source_hash = if (store_source_hash.len > 0) try allocator.dupe(u8, store_source_hash) else if (pkg.source_hash.len > 0) try allocator.dupe(u8, pkg.source_hash) else &.{},
                            .recipe_hash = if (store_recipe_hash.len > 0) try allocator.dupe(u8, store_recipe_hash) else if (pkg.recipe_hash.len > 0) try allocator.dupe(u8, pkg.recipe_hash) else try allocator.dupe(u8, recipe_hash),
                            .artifact_hash = try allocator.dupe(u8, pkg.artifact_hash),
                            .runtime = try allocator.dupe(u8, active_lua_abi),
                            .lua_abi = try allocator.dupe(u8, pkg.lua_abi orelse active_lua_abi),
                            .target = try allocator.dupe(u8, lock_target),
                            .constellation = try allocator.dupe(u8, "default"),
                            .resolver = try allocator.dupe(u8, switch (pkg.origin) {
                                .luarocks => "rocks",
                                .moonstone_registry => "moonstone",
                                .link => "link",
                                .path => "path",
                                .artifact_hash => blk: {
                                    if (existing_lock.find(pkg.name)) |ex_pkg| {
                                        if (ex_pkg.resolver.len > 0 and !std.mem.eql(u8, ex_pkg.resolver, "store")) {
                                            break :blk ex_pkg.resolver;
                                        }
                                    }
                                    if (store_rockspec.len > 0 or store_rockspec_hash.len > 0) {
                                        break :blk "rocks";
                                    }
                                    break :blk "store";
                                },
                            }),
                            .registry = try lockRegistryForPackage(allocator, &pkg, &existing_lock),
                            .source = if (store_source.len > 0) try allocator.dupe(u8, store_source) else switch (pkg.origin) {
                                .moonstone_registry => if (pkg.source.len > 0) try allocator.dupe(u8, pkg.source) else if (pkg.registry_url) |url| try allocator.dupe(u8, url) else &.{},
                                .luarocks => |r| try allocator.dupe(u8, r.url),
                                .link => |p| try allocator.dupe(u8, p),
                                .path => |p| try allocator.dupe(u8, p),
                                .artifact_hash => &.{},
                            },
                            .source_kind = if (store_source_kind.len > 0) try allocator.dupe(u8, store_source_kind) else &.{},
                            .source_payload = if (store_source_payload.len > 0) try allocator.dupe(u8, store_source_payload) else &.{},
                            .source_url = if (store_source_url.len > 0) try allocator.dupe(u8, store_source_url) else &.{},
                            .rockspec = if (store_rockspec.len > 0) try allocator.dupe(u8, store_rockspec) else if (pkg.rockspec.len > 0) try allocator.dupe(u8, pkg.rockspec) else &.{},
                            .rockspec_hash = if (store_rockspec_hash.len > 0) try allocator.dupe(u8, store_rockspec_hash) else if (pkg.rockspec_hash.len > 0) try allocator.dupe(u8, pkg.rockspec_hash) else &.{},
                            .rockspec_payload = if (store_rockspec_payload.len > 0) try allocator.dupe(u8, store_rockspec_payload) else &.{},
                            .replay_mode = blk: {
                                const sk = if (store_source_kind.len > 0) store_source_kind else "";
                                if (std.mem.eql(u8, sk, "zig_cc") or std.mem.eql(u8, sk, "cmake") or std.mem.eql(u8, sk, "native_cmodule")) {
                                    break :blk moonstone.domain.replay_contract.ReplayMode.declared_host;
                                }
                                if (moonstone.resolution.locked_realizer.assessMaterializerCapability(sk) == .source_replay_supported) {
                                    break :blk moonstone.domain.replay_contract.ReplayMode.portable_source;
                                }
                                break :blk moonstone.domain.replay_contract.ReplayMode.artifact_only;
                            },
                            .roles = try entry_roles.toOwnedSlice(allocator),
                        });
                    }
                    if (package_roles.get(pkg.name)) |glist| {
                        for (glist.items) |g| {
                            const role = moonstone.domain.manifest.parseDependencyRole(g) catch return error.InvalidDependencyRole;
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
            // Use pre-computed result from the download pool, or handle
            // local store/path packages inline.
            const m_res = blk: {
                if (job_map.get(pkg_name_sol)) |ji| {
                    if (download_jobs.items[ji].result) |r| break :blk r;
                    // Should have errored above; defensive fallback.
                    return error.MaterializerFailed;
                }
                break :blk moonstone.materialization.materializer.MaterializeResult{
                    .path = try allocator.dupe(u8, pkg.local_path.?),
                    .artifact_hash = try allocator.dupe(u8, pkg.artifact_hash),
                };
            };
            defer m_res.deinit(allocator);

            if (replay_lock) {
                const lock_entry = findReplayEntry(replay_entries.items, pkg.name) orelse return error.LockfileOutOfSync;
                if (!std.mem.eql(u8, lock_entry.version, pkg.version)) return error.LockfileOutOfSync;
                if (moonstone.resolution.locked_realizer.requiresExactArtifactHash(lock_entry) and !std.mem.eql(u8, lock_entry.artifact_hash, m_res.artifact_hash)) {
                    moonstone.diagnostics.error_context.setFmt(
                        allocator,
                        "Locked artifact hash mismatch for {s}@{s}. Expected {s}, but replay produced {s}. Restore the exact artifact or run 'moon sync --update' to create a new lockfile.",
                        .{ pkg.name, pkg.version, lock_entry.artifact_hash, m_res.artifact_hash },
                    );
                    return error.ArtifactHashMismatch;
                }
                if (lock_entry.source_hash.len > 0 and pkg.source_hash.len > 0 and !std.mem.eql(u8, lock_entry.source_hash, pkg.source_hash)) return error.LockfileOutOfSync;
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
                var store_prov_opt = @import("lock_provenance.zig").read(allocator, io, m_res.path) catch null;
                defer if (store_prov_opt) |*store_prov| store_prov.deinit(allocator);
                const store_source_hash = if (store_prov_opt) |store_prov| store_prov.source_hash else "";
                const store_recipe_hash = if (store_prov_opt) |store_prov| store_prov.recipe_hash else "";
                const store_source = if (store_prov_opt) |store_prov| store_prov.source else "";
                const store_source_kind = if (store_prov_opt) |store_prov| store_prov.source_kind else "";
                const store_source_payload = if (store_prov_opt) |store_prov| store_prov.source_payload else "";
                const store_source_url = if (store_prov_opt) |store_prov| store_prov.source_url else "";
                const store_rockspec = if (store_prov_opt) |store_prov| store_prov.rockspec else "";
                const store_rockspec_hash = if (store_prov_opt) |store_prov| store_prov.rockspec_hash else "";
                const store_rockspec_payload = if (store_prov_opt) |store_prov| store_prov.rockspec_payload else "";
                try next_lock.packages.append(allocator, .{
                    .name = try allocator.dupe(u8, pkg.name),
                    .version = try allocator.dupe(u8, pkg.version),
                    .kind = pkg.kind,
                    .source_hash = if (store_source_hash.len > 0) try allocator.dupe(u8, store_source_hash) else if (pkg.source_hash.len > 0) try allocator.dupe(u8, pkg.source_hash) else &.{},
                    .recipe_hash = if (store_recipe_hash.len > 0) try allocator.dupe(u8, store_recipe_hash) else if (pkg.recipe_hash.len > 0) try allocator.dupe(u8, pkg.recipe_hash) else try allocator.dupe(u8, recipe_hash),
                    .artifact_hash = try allocator.dupe(u8, m_res.artifact_hash),
                    .runtime = try allocator.dupe(u8, active_lua_abi),
                    .lua_abi = try allocator.dupe(u8, pkg.lua_abi orelse active_lua_abi),
                    .target = try allocator.dupe(u8, lock_target),
                    .constellation = try allocator.dupe(u8, "default"),
                    .resolver = try allocator.dupe(u8, switch (pkg.origin) {
                        .luarocks => "rocks",
                        .moonstone_registry => "moonstone",
                        .link => "link",
                        .path => "path",
                        else => "store",
                    }),
                    .registry = try lockRegistryForPackage(allocator, &pkg, &existing_lock),
                    .source = if (store_source.len > 0) try allocator.dupe(u8, store_source) else switch (pkg.origin) {
                        .moonstone_registry => if (pkg.source.len > 0) try allocator.dupe(u8, pkg.source) else if (pkg.registry_url) |url| try allocator.dupe(u8, url) else &.{},
                        .luarocks => |r| try allocator.dupe(u8, r.url),
                        .link => |p| try allocator.dupe(u8, p),
                        .path => |p| try allocator.dupe(u8, p),
                        .artifact_hash => &.{},
                    },
                    .source_kind = if (store_source_kind.len > 0) try allocator.dupe(u8, store_source_kind) else &.{},
                    .source_payload = if (store_source_payload.len > 0) try allocator.dupe(u8, store_source_payload) else &.{},
                    .source_url = if (store_source_url.len > 0) try allocator.dupe(u8, store_source_url) else &.{},
                    .rockspec = if (store_rockspec.len > 0) try allocator.dupe(u8, store_rockspec) else if (pkg.rockspec.len > 0) try allocator.dupe(u8, pkg.rockspec) else &.{},
                    .rockspec_hash = if (store_rockspec_hash.len > 0) try allocator.dupe(u8, store_rockspec_hash) else if (pkg.rockspec_hash.len > 0) try allocator.dupe(u8, pkg.rockspec_hash) else &.{},
                    .rockspec_payload = if (store_rockspec_payload.len > 0) try allocator.dupe(u8, store_rockspec_payload) else &.{},
                    .replay_mode = blk: {
                        const sk = if (store_source_kind.len > 0) store_source_kind else "";
                        if (std.mem.eql(u8, sk, "zig_cc") or std.mem.eql(u8, sk, "cmake") or std.mem.eql(u8, sk, "native_cmodule")) {
                            break :blk moonstone.domain.replay_contract.ReplayMode.declared_host;
                        }
                        if (moonstone.resolution.locked_realizer.assessMaterializerCapability(sk) == .source_replay_supported) {
                            break :blk moonstone.domain.replay_contract.ReplayMode.portable_source;
                        }
                        break :blk moonstone.domain.replay_contract.ReplayMode.artifact_only;
                    },
                    .roles = try entry_roles.toOwnedSlice(allocator),
                });
            }
            if (!std.mem.eql(u8, pkg.name, rt_res.name)) {
                if (package_roles.get(pkg.name)) |glist| {
                    for (glist.items) |g| {
                        const role = moonstone.domain.manifest.parseDependencyRole(g) catch return error.InvalidDependencyRole;
                        try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &pkg, m_res.path, m_res.artifact_hash, role));
                    }
                } else {
                    try projected_artifacts.append(allocator, try projectedArtifactFromPkg(allocator, &mt, &pkg, m_res.path, m_res.artifact_hash, .runtime));
                }
            }
        }
        // Tool runtime scopes and .moonstone/env are host-process concepts.
        // Foreign targets realize/store closures only in this first slice.
        if (target_is_host) {
            try ensureIsolatedRuntimes(
                allocator,
                io,
                stdout,
                ctx,
                &solution,
                &coordinator,
                idx,
                registries,
                &mat,
                active_lua_abi,
                self.offline,
                &report,
                emitter,
                backend,
                on_resolve_cb,
                on_resolve_ctx,
            );
        }

        report.materialize_ms = elapsedMs(io, materialize_started_ns);
        profiler.spanCount("sync.materialize", profile_span, "packages", solution.count());
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "materialization.complete", .{
                .store_hits = report.store_hits,
                .downloads = report.downloads,
                .materializations = report.materializations,
                .path_link_projections = report.path_link_projections,
                .elapsed_ms = report.materialize_ms,
            });
        }

        if (!replay_lock) {
            for (next_lock.packages.items[new_realization_start..]) |*entry| {
                entry.realization_hash = try moonstone.domain.lockfile.computeRealizationHash(allocator, entry.*);
            }
            var profile_refs = std.ArrayList(moonstone.domain.resolution_profile.ProfilePackageRef).empty;
            errdefer {
                for (profile_refs.items) |reference| reference.deinit(allocator);
                profile_refs.deinit(allocator);
            }
            for (next_lock.packages.items[new_realization_start..]) |entry| {
                try profile_refs.append(allocator, .{
                    .package_name = try allocator.dupe(u8, entry.name),
                    .package_version = try allocator.dupe(u8, entry.version),
                    .realization_hash = try allocator.dupe(u8, entry.realization_hash),
                });
            }
            const profile_id = try moonstone.domain.resolution_profile.generateProfileId(allocator, lock_target, rt_res.name, active_lua_abi);
            try next_lock.upsertProfile(.{
                .id = profile_id,
                .target = try allocator.dupe(u8, lock_target),
                .runtime = try allocator.dupe(u8, rt_res.name),
                .lua_abi = try allocator.dupe(u8, active_lua_abi),
                .packages = try profile_refs.toOwnedSlice(allocator),
                .edges = &.{},
            });
            try next_lock.validateProfiles();
            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try next_lock.serialize(allocator, &aw.writer);

            const lock_file = try std.Io.Dir.cwd().createFile(io, "moonstone.lock", .{});
            defer lock_file.close(io);
            try lock_file.writeStreamingAll(io, aw.written());
        }

        if (!target_is_host) {
            report.total_ms = elapsedMs(io, started_ns);
            if (emitter) |e| {
                try e.terminate(io, name, "sync.complete", .{ .summary = report, .target = lock_target, .projected = false });
            } else {
                backend.phaseDone("Target profile synchronized; host environment was not projected.", .{});
            }
            return;
        }

        // ── Phase 3: Link environment (serial/finalized) ─────────────────────
        // Linking is inherently serial: it writes symlinks and projection
        // metadata into a single project environment directory.  All
        // downloads, hash verification, and store commits are complete.
        // 5. Link environment
        const link_started_ns = nowNs(io);
        profile_span = profiler.now();
        if (emitter) |e| {
            try e.emit(io, .STATUS, name, "env.link.begin", .{ .artifacts = projected_artifacts.items.len, .links = live_links.items.len });
        } else {
            backend.phase("Linking project environment...", .{});
        }
        try moonstone.project.linker.link_project_env_at(allocator, io, std.Io.Dir.cwd(), idx, projected_artifacts.items, live_links.items, ".moonstone/env", env, rt_res.name);
        report.linked = projected_artifacts.items.len + live_links.items.len;
        report.env_refreshed = true;
        report.link_ms = elapsedMs(io, link_started_ns);
        profiler.spanCount("sync.env.link", profile_span, "artifacts", projected_artifacts.items.len + live_links.items.len);
        report.total_ms = elapsedMs(io, started_ns);

        if (emitter) |e| {
            try e.terminate(io, name, "sync.complete", .{
                .summary = report,
            });
        } else {
            backend.phaseDone("Project environment synchronized.", .{});
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
                            const path_target = if (std.mem.startsWith(u8, dep.constraint, "path:")) dep.constraint["path:".len..] else dep.constraint;
                            std.Io.Dir.cwd().access(io, path_target, .{}) catch {
                                issues += 1;
                                const msg = try std.fmt.allocPrint(allocator, "path dependency {s} target does not exist: {s}", .{ dep_name, path_target });
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

            const lock_entry = lf.findIgnoreCase(dep_name) orelse {
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
    if (deps.len == 0 and lf.packages.items.len > 0) return false;

    for (deps) |dep| {
        const dep_name = normalizedLockDependencyName(dep.name);

        if (dep.resolver) |r| {
            if (std.mem.eql(u8, r, "link") or std.mem.eql(u8, r, "path") or std.mem.eql(u8, r, "artifact")) continue;
        }

        const lock_entry = lf.findIgnoreCase(dep_name) orelse return false;
        const constraint = normalizedLockConstraint(if (dep.constraint.len > 0) dep.constraint else "*");
        if (!moonstone.domain.semver.matches(lock_entry.version, constraint)) return false;
    }
    return true;
}

fn findReplayEntry(entries: []const *const moonstone.domain.lockfile.LockEntry, name: []const u8) ?*const moonstone.domain.lockfile.LockEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
    }
    return null;
}

fn lockedEntriesDependenciesMatch(
    deps: []const moonstone.domain.manifest.StoreDependency,
    entries: []const *const moonstone.domain.lockfile.LockEntry,
) bool {
    if (deps.len == 0 and entries.len > 0) return false;
    for (deps) |dep| {
        if (dep.resolver) |resolver| {
            if (std.mem.eql(u8, resolver, "link") or std.mem.eql(u8, resolver, "path") or std.mem.eql(u8, resolver, "artifact")) continue;
        }
        const entry = findReplayEntry(entries, normalizedLockDependencyName(dep.name)) orelse return false;
        const constraint = normalizedLockConstraint(if (dep.constraint.len > 0) dep.constraint else "*");
        if (!moonstone.domain.semver.matches(entry.version, constraint)) return false;
    }
    return true;
}

fn normalizedLockDependencyName(raw: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw, "rocks:")) return raw["rocks:".len..];
    return raw;
}

fn isResolvableRuntimeSpec(runtime_spec: []const u8) bool {
    if (runtime_spec.len == 0) return false;
    if (std.mem.eql(u8, runtime_spec, "lua@unknown")) return false;
    if (std.mem.startsWith(u8, runtime_spec, "table:")) return false;
    if (std.mem.indexOfScalar(u8, runtime_spec, '@')) |at| {
        return at > 0 and at + 1 < runtime_spec.len;
    }
    return true;
}

fn lockedRuntimeMatches(
    lf: *const moonstone.domain.lockfile.LockFile,
    runtime_name: []const u8,
    runtime_version: []const u8,
    active_lua_abi: []const u8,
) bool {
    if (lf.find(runtime_name)) |entry| {
        return std.mem.eql(u8, entry.version, runtime_version);
    }

    for (lf.packages.items) |entry| {
        if (std.mem.eql(u8, entry.artifact_hash, "link") or std.mem.eql(u8, entry.artifact_hash, "path")) continue;
        if (entry.runtime.len == 0) continue;
        if (!moonstone.resolution.options.runtimeAbiMatches(active_lua_abi, entry.runtime)) return false;
    }

    return true;
}

fn lockedEntriesRuntimeMatch(
    entries: []const *const moonstone.domain.lockfile.LockEntry,
    runtime_name: []const u8,
    runtime_version: []const u8,
    active_lua_abi: []const u8,
) bool {
    if (findReplayEntry(entries, runtime_name)) |entry| {
        return std.mem.eql(u8, entry.version, runtime_version);
    }
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.artifact_hash, "link") or std.mem.eql(u8, entry.artifact_hash, "path")) continue;
        if (entry.runtime.len == 0) continue;
        if (!moonstone.resolution.options.runtimeAbiMatches(active_lua_abi, entry.runtime)) return false;
    }
    return true;
}

const LockReplayTargetState = enum {
    compatible,
    legacy_native,
    incompatible,
};

/// A lock records one concrete host realization. `native` was an older
/// context-sensitive spelling and cannot prove that the selected artifact is
/// valid for this host. Normal sync refreshes it; `--locked` refuses it.
fn lockReplayTargetState(lf: *const moonstone.domain.lockfile.LockFile, host_target: []const u8) LockReplayTargetState {
    for (lf.packages.items) |entry| {
        if (std.mem.eql(u8, entry.artifact_hash, "link") or std.mem.eql(u8, entry.artifact_hash, "path")) continue;
        if (std.mem.eql(u8, entry.target, "native")) return .legacy_native;
        if (!std.mem.eql(u8, entry.target, host_target)) return .incompatible;
    }
    return .compatible;
}

fn lockReplayEntriesTargetState(entries: []const *const moonstone.domain.lockfile.LockEntry, target: []const u8) LockReplayTargetState {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.artifact_hash, "link") or std.mem.eql(u8, entry.artifact_hash, "path")) continue;
        if (std.mem.eql(u8, entry.target, "native")) return .legacy_native;
        if (!std.mem.eql(u8, entry.target, target)) return .incompatible;
    }
    return .compatible;
}

fn normalizedLockConstraint(raw: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw, ':') != null) {
        if (std.mem.lastIndexOfScalar(u8, raw, '@')) |at| {
            return raw[at + 1 ..];
        }
        return "*";
    }
    return raw;
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
fn checkLinkedRuntimeAbiForReplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *router.Context,
    mt: *const moonstone.domain.manifest.MoonstoneToml,
    active_lua_abi: []const u8,
    pkg_name: []const u8,
    pkg_version: []const u8,
    source_path: []const u8,
) !void {
    if (source_path.len == 0) return;
    const role = roleForResolvedPackage(mt, pkg_name);
    const policy = role.getProjectionPolicy();
    if (policy.expose_tool_scope or policy.expose_helper_scope) return;

    const manifest_path = try std.fs.path.join(allocator, &.{ source_path, "moonstone.toml" });
    defer allocator.free(manifest_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(content);

    var linked_mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
    defer linked_mt.deinit(allocator);

    if (!moonstone.resolution.options.runtimeAbiMatches(active_lua_abi, linked_mt.runtime.abi)) {
        const suggested_role: ?[]const u8 = if (linked_mt.package.kind == .script or linked_mt.package.kind == .bin)
            "tool"
        else
            null;
        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
        if (suggested_role) |sr| {
            ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}\nIf this is a development CLI tool, add it with --{s} instead.", .{ pkg_name, pkg_version, linked_mt.runtime.abi, active_lua_abi, manifest_path, sr }) } };
        } else {
            ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}", .{ pkg_name, pkg_version, linked_mt.runtime.abi, active_lua_abi, manifest_path }) } };
        }
        return error.LinkedRuntimeAbiMismatch;
    }
}

fn checkLocalSourceAvailableForReplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    pkg_version: []const u8,
    resolver: []const u8,
    source_path: []const u8,
) !void {
    if (source_path.len == 0) {
        moonstone.diagnostics.error_context.setFmt(allocator, "Locked local {s} dependency {s}@{s} has no source path. Restore the source or update the dependency, then run 'moon sync --update'.", .{ resolver, pkg_name, pkg_version });
        return error.LocalSourceUnavailable;
    }

    var source_dir = std.Io.Dir.cwd().openDir(io, source_path, .{}) catch {
        moonstone.diagnostics.error_context.setFmt(allocator, "Locked local {s} dependency {s}@{s} is unavailable at '{s}'. Restore the source or update the dependency, then run 'moon sync --update'.", .{ resolver, pkg_name, pkg_version, source_path });
        return error.LocalSourceUnavailable;
    };
    source_dir.close(io);
}

fn runtimeSpecFromLinkedPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
) !?[]const u8 {
    const manifest_path = try std.fs.path.join(allocator, &.{ source_path, "moonstone.toml" });
    defer allocator.free(manifest_path);
    if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
        if (content) |c| {
            defer allocator.free(c);
            var linked_mt: ?moonstone.domain.manifest.MoonstoneToml = moonstone.domain.manifest.MoonstoneToml.parse(allocator, c) catch null;
            defer if (linked_mt) |*lmt| lmt.deinit(allocator);
            if (linked_mt) |*mt| {
                if (mt.runtime.name.len > 0 and mt.runtime.version.len > 0) {
                    return try std.fmt.allocPrint(allocator, "{s}@{s}", .{ mt.runtime.name, mt.runtime.version });
                }
            }
        }
    } else |_| {}
    return null;
}

fn runtimeInStore(
    allocator: std.mem.Allocator,
    index: moonstone.store.driver.StoreDriver,
    rt_spec: []const u8,
) !bool {
    var spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, rt_spec);
    defer spec.deinit(allocator);

    var runtime_name = moonstone.domain.package_spec.canonicalOfficialRuntime(spec.name);
    if (std.mem.startsWith(u8, runtime_name, "moonstone/")) {
        runtime_name = runtime_name["moonstone/".len..];
    }
    const runtime_constraint = spec.constraint orelse "*";

    const query_names = [_][]const u8{ runtime_name, try std.fmt.allocPrint(allocator, "moonstone/{s}", .{runtime_name}) };
    defer allocator.free(query_names[1]);

    for (query_names) |query_name| {
        const candidates = try index.findCandidates(.{
            .name = query_name,
            .kind = .runtime,
        });
        defer {
            for (candidates) |candidate| {
                var mut_candidate = candidate;
                mut_candidate.deinit(allocator);
            }
            allocator.free(candidates);
        }
        for (candidates) |cand| {
            const candidate_name = if (std.mem.startsWith(u8, cand.name, "moonstone/")) cand.name["moonstone/".len..] else cand.name;
            if (std.mem.eql(u8, candidate_name, runtime_name) and moonstone.domain.semver.matches(cand.version, runtime_constraint)) return true;
        }
    }
    return false;
}

fn resolveAndMaterializeRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    ctx: *router.Context,
    pkg_name: []const u8,
    pkg_version: []const u8,
    pkg_lua_abi: ?[]const u8,
    rt_spec: []const u8,
    coordinator: *moonstone.resolution.coordinator.Coordinator,
    index: moonstone.store.driver.StoreDriver,
    registries: []const moonstone.registry.core.ResolvedRegistry,
    mat: *moonstone.materialization.materializer.Materializer,
    active_lua_abi: []const u8,
    offline: bool,
    report: *SyncReport,
    emitter: ?*ndjson.Emitter,
    backend: progress_runtime.ProgressBackend,
    on_resolve_cb: ?moonstone.resolution.options.ResolveCallback,
    on_resolve_ctx: ?*anyopaque,
    fail_hard: bool,
) !void {
    _ = stdout;
    var spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, rt_spec);
    defer spec.deinit(allocator);

    var runtime_name = moonstone.domain.package_spec.canonicalOfficialRuntime(spec.name);
    if (std.mem.startsWith(u8, runtime_name, "moonstone/")) {
        runtime_name = runtime_name["moonstone/".len..];
    }
    const runtime_constraint = spec.constraint orelse "*";
    const target_abi = pkg_lua_abi orelse active_lua_abi;

    if (emitter) |e| {
        try e.emit(io, .STATUS, pkg_name, "isolated_runtime.resolve", .{ .runtime = rt_spec });
    } else {
        backend.status("isolated-runtime", "Resolving isolated interpreter {s} for {s}@{s}...", .{ rt_spec, pkg_name, pkg_version });
    }

    const rt_res_iso = coordinator.resolve(runtime_name, runtime_constraint, index, registries, .{
        .offline = offline,
        .prefer_local = true,
        .runtime = target_abi,
        .on_event = on_resolve_cb,
        .on_event_context = on_resolve_ctx,
    }, ctx.env) catch |err| {
        if (fail_hard) {
            if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
            ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "package {s}@{s} requires isolated runtime {s}, but it could not be resolved: {s}", .{ pkg_name, pkg_version, rt_spec, @errorName(err) }) } };
            return error.IsolatedRuntimeResolutionFailed;
        }
        return;
    };
    defer rt_res_iso.deinit(allocator);

    switch (rt_res_iso.location) {
        .local_store, .local_path => {},
        .remote => switch (rt_res_iso.origin) {
            .moonstone_registry => |r| {
                _ = try mat.materialize_remote(
                    r.url,
                    r.token,
                    r.descriptor_path,
                    rt_res_iso.remote_desc.?,
                    r.artifact_idx,
                );
                report.downloads += 1;
                report.materializations += 1;
            },
            else => {
                if (fail_hard) {
                    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                    ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "package {s}@{s} requires isolated runtime {s}, but it has an unsupported origin", .{ pkg_name, pkg_version, rt_spec }) } };
                    return error.IsolatedRuntimeResolutionFailed;
                }
            },
        },
    }
}

fn ensureIsolatedRuntimes(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    ctx: *router.Context,
    solution: *const std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact),
    coordinator: *moonstone.resolution.coordinator.Coordinator,
    idx: moonstone.store.driver.StoreDriver,
    registries: []const moonstone.registry.core.ResolvedRegistry,
    mat: *moonstone.materialization.materializer.Materializer,
    active_lua_abi: []const u8,
    offline: bool,
    report: *SyncReport,
    emitter: ?*ndjson.Emitter,
    backend: progress_runtime.ProgressBackend,
    on_resolve_cb: ?moonstone.resolution.options.ResolveCallback,
    on_resolve_ctx: ?*anyopaque,
) !void {
    var seen = std.StringArrayHashMapUnmanaged(void).empty;
    defer {
        var sit = seen.iterator();
        while (sit.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit(allocator);
    }

    var it = solution.iterator();
    while (it.next()) |entry| {
        const pkg = entry.value_ptr.*;
        if (pkg.kind == .runtime) continue;

        const is_link_or_path = std.mem.eql(u8, pkg.artifact_hash, "link") or std.mem.eql(u8, pkg.artifact_hash, "path");

        const rt_spec: ?[]const u8 = blk: {
            if (is_link_or_path) {
                if (pkg.local_path) |lp| {
                    if (try runtimeSpecFromLinkedPackage(allocator, io, lp)) |linked_rt| {
                        break :blk linked_rt;
                    }
                }
                break :blk null;
            }
            if (pkg.runtime) |r| {
                if (isResolvableRuntimeSpec(r)) break :blk try allocator.dupe(u8, r);
            }
            break :blk null;
        };
        defer if (rt_spec) |r| allocator.free(r);
        const rt = rt_spec orelse continue;

        if (seen.contains(rt)) {
            continue;
        }
        try seen.put(allocator, try allocator.dupe(u8, rt), {});

        const in_store = try runtimeInStore(allocator, idx, rt);
        if (in_store) continue;

        try resolveAndMaterializeRuntime(
            allocator,
            io,
            stdout,
            ctx,
            pkg.name,
            pkg.version,
            pkg.lua_abi,
            rt,
            coordinator,
            idx,
            registries,
            mat,
            active_lua_abi,
            offline,
            report,
            emitter,
            backend,
            on_resolve_cb,
            on_resolve_ctx,
            !is_link_or_path,
        );
    }
}

test "rocks preparation coordination elects one leader for an identical resolved source" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var first = moonstone.resolution.candidate.ResolvedArtifact{
        .name = "same-rock",
        .version = "1.0-1",
        .kind = .lib,
        .origin = .{ .luarocks = .{ .url = "https://rocks.example", .rockspec_path = "" } },
        .registry_name = "rocks",
    };
    var second = moonstone.resolution.candidate.ResolvedArtifact{
        .name = "same-rock",
        .version = "1.0-1",
        .kind = .lib,
        .origin = .{ .luarocks = .{ .url = "https://rocks.example", .rockspec_path = "" } },
        .registry_name = "rocks",
    };
    var jobs = [_]RocksJob{
        .{ .pkg = &first },
        .{ .pkg = &second },
    };
    var pool = RocksPool{
        .allocator = allocator,
        .io = std.testing.io,
        .env = &env,
        .jobs = &jobs,
        .target = "x86_64-linux-gnu",
        .options = .{
            .runtime = "lua54",
            .runtime_artifact_hash = "b3:runtime",
            .target = "x86_64-linux-gnu",
        },
        .wctx = null,
        .reporter = .{},
        .preparation_coordinator = moonstone.realization.request_coordinator.RequestCoordinator.init(allocator),
        .request_coordinator = moonstone.realization.request_coordinator.RequestCoordinator.init(allocator),
    };
    defer pool.deinit();

    try pool.selectPreparationLeaders();
    try std.testing.expectEqual(@as(?usize, 0), jobs[0].preparation_leader);
    try std.testing.expectEqual(@as(?usize, 0), jobs[1].preparation_leader);
}
