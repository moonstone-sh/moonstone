const std = @import("std");
const error_context = @import("../diagnostics/error_context.zig");
const lockfile_mod = @import("../domain/lockfile.zig");
const LockEntry = lockfile_mod.LockEntry;
const locked_pkg = @import("../domain/locked_package.zig");
const store_driver = @import("../store/driver.zig").StoreDriver;
const package_provider = @import("provider/package_provider.zig");
const candidate_mod = @import("candidate.zig");

pub const RealizationMethod = enum {
    local_cas,
    remote_artifact,
    source_rematerialization,
};

pub const RealizeResult = struct {
    candidate: candidate_mod.Candidate,
    method: RealizationMethod,

    pub fn deinit(self: *RealizeResult, allocator: std.mem.Allocator) void {
        self.candidate.deinit(allocator);
    }
};

pub const ReplayPolicy = struct {
    offline: bool = false,
    allow_remote_artifacts: bool = true,
    allow_source_rematerialization: bool = true,
};

pub fn assessMaterializerCapability(source_kind: []const u8) locked_pkg.MaterializerCapability {
    if (std.mem.eql(u8, source_kind, "copy_lua") or
        std.mem.eql(u8, source_kind, "builtin") or
        std.mem.eql(u8, source_kind, "luarocks_src_rock") or
        std.mem.eql(u8, source_kind, "upstream_archive"))
    {
        return .source_replay_supported;
    }
    return .exact_artifact_required;
}

/// Every stored artifact identity is part of the replay contract. `native`
/// selects the host realization when the lock is created; it does not weaken
/// verification on the host that replays that lock. A project moving to a
/// different target must create a new target realization explicitly rather
/// than silently accepting a different artifact under the same lock entry.
pub fn requiresExactArtifactHash(entry: *const LockEntry) bool {
    return entry.artifact_hash.len > 0 and
        !std.mem.eql(u8, entry.artifact_hash, "link") and
        !std.mem.eql(u8, entry.artifact_hash, "path");
}

/// A locked LuaRocks replay must retain the exact location that supplied the
/// rockspec. Older realizations may only have recorded the matching source
/// rock. Its sibling rockspec is still an exact, case-preserving derivation;
/// it is materially different from rediscovering a URL from the package name.
fn lockedRockspecUrl(
    allocator: std.mem.Allocator,
    entry: *const LockEntry,
) !?[]u8 {
    if (entry.rockspec.len > 0) return try allocator.dupe(u8, entry.rockspec);

    const source_url = if (entry.source.len > 0) entry.source else entry.source_url;
    const suffix = ".src.rock";
    if (!std.mem.endsWith(u8, source_url, suffix)) return null;

    return try std.fmt.allocPrint(allocator, "{s}.rockspec", .{source_url[0 .. source_url.len - suffix.len]});
}

test "locked LuaRocks rockspec derivation preserves recorded source spelling" {
    const allocator = std.testing.allocator;
    const entry = LockEntry{
        .source = "https://mirror.example/luasql-sqlite3-2.8.0-1.src.rock",
    };
    const url = (try lockedRockspecUrl(allocator, &entry)).?;
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://mirror.example/luasql-sqlite3-2.8.0-1.rockspec", url);
}

test "locked LuaRocks rockspec derivation rejects non-source-rock provenance" {
    const entry = LockEntry{ .source = "https://mirror.example/source.tar.gz" };
    try std.testing.expect((try lockedRockspecUrl(std.testing.allocator, &entry)) == null);
}

test "native locked artifacts retain exact identity" {
    var entry = LockEntry{
        .artifact_hash = "b3:artifact",
        .target = "native",
    };
    try std.testing.expect(requiresExactArtifactHash(&entry));

    entry.artifact_hash = "link";
    try std.testing.expect(!requiresExactArtifactHash(&entry));
}

const graph_provider = @import("provider/graph_provider.zig");

pub fn ensureLockedArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    entry: *const LockEntry,
    build_artifacts: []const @import("options.zig").BuildArtifact,
    provider: *graph_provider.RegistryProvider,
    store_drv: *store_driver,
    policy: ReplayPolicy,
) !RealizeResult {
    _ = store_drv;
    const coordinator_mod = @import("coordinator.zig");
    const exact_artifact_hash = if (requiresExactArtifactHash(entry)) entry.artifact_hash else "";
    const requested_artifact_hash: ?[]const u8 = if (exact_artifact_hash.len > 0) exact_artifact_hash else null;
    // 1. Check configured artifact providers / local store by hash.
    if (exact_artifact_hash.len > 0 and
        !std.mem.eql(u8, exact_artifact_hash, "link") and
        !std.mem.eql(u8, exact_artifact_hash, "path"))
    {
        const req = package_provider.ArtifactRequest{
            .name = entry.name,
            .version = entry.version,
            .resolver = if (entry.resolver.len > 0) coordinator_mod.CoordinatorKind.fromString(entry.resolver) catch null else null,
            .artifact_hash = requested_artifact_hash,
            .runtime = if (entry.runtime.len > 0) entry.runtime else null,
            .lua_abi = if (entry.lua_abi.len > 0) entry.lua_abi else null,
        };

        if (try provider.get_artifact(req)) |cand| {
            var cand_valid = true;
            if (cand.local_path) |cand_path| {
                std.Io.Dir.cwd().access(io, cand_path, .{}) catch {
                    cand_valid = false;
                };
                if (cand_valid) {
                    const manifest_path = try std.fs.path.join(allocator, &.{ cand_path, "manifest.toml" });
                    defer allocator.free(manifest_path);
                    std.Io.Dir.cwd().access(io, manifest_path, .{}) catch {
                        cand_valid = false;
                    };
                }
            }
            if (cand_valid) {
                return RealizeResult{
                    .candidate = cand,
                    .method = .local_cas,
                };
            } else {
                var mut_cand = cand;
                mut_cand.deinit(allocator);
            }
        }
    }

    // 2. Assess materializer capability and ReplayContract. The provider above
    // searches the configured registries for an exact remote artifact, so do
    // not fall back to an unrelated default registry here.
    if (entry.replay_mode == .artifact_only) {
        error_context.setFmt(allocator, "The locked artifact for {s}@{s} is unavailable for target `{s}`. This package is artifact-only; restore the matching registry artifact or update the lockfile.", .{ entry.name, entry.version, entry.target });
        return error.ExactArtifactRequired;
    }

    const capability = assessMaterializerCapability(entry.source_kind);
    if (capability == .exact_artifact_required and entry.replay_mode != .declared_host) {
        error_context.setFmt(allocator, "The locked artifact for {s}@{s} has source kind `{s}`, which cannot be replayed from source. Restore the matching registry artifact or update the lockfile.", .{ entry.name, entry.version, entry.source_kind });
        return error.ExactArtifactRequired;
    }

    // 4. Host Tool Verification for declared_host replay mode
    if (entry.replay_mode == .declared_host) {
        const host_resolver = @import("../tools/host_resolver.zig");
        const replay_mod = @import("../domain/replay_contract.zig");

        const tool_name = if (std.mem.eql(u8, entry.source_kind, "cmake")) "cmake" else "zig";
        const tool_kind: replay_mod.HostToolKind = if (std.mem.eql(u8, tool_name, "cmake")) .cmake else .zig;
        var exec_names = [_][]const u8{tool_name};

        var req = replay_mod.HostToolRequirement{
            .id = try allocator.dupe(u8, tool_name),
            .kind = tool_kind,
            .executable_names = &exec_names,
            .version_policy = .exact_observed,
            .observed_version = if (entry.runtime.len > 0) try allocator.dupe(u8, entry.runtime) else null,
        };
        defer req.deinit(allocator);

        var resolved_tool = host_resolver.resolveHostTool(allocator, io, env, &req) catch |err| {
            return err;
        };
        defer resolved_tool.deinit(allocator);
    }

    // 5. Source rematerialization
    if (!policy.allow_source_rematerialization) {
        return error.LockedArtifactMissing;
    }

    // Must have a valid source URL, rockspec URL, or package identity
    const has_source_url = entry.source_url.len > 0 or entry.source.len > 0 or (entry.name.len > 0 and entry.version.len > 0);
    const has_rockspec_url = entry.rockspec.len > 0;
    if (!has_source_url and !has_rockspec_url) {
        return error.ReplayProvenanceMissing;
    }

    const platform_fs = @import("../platform/fs.zig");
    var paths = try platform_fs.resolve_moonstone(allocator, env, io);
    defer paths.deinit(allocator);

    // Create temp workspace
    const tmp_dir_name = try std.fmt.allocPrint(allocator, "replay-{s}-{s}", .{ entry.name, entry.version });
    defer allocator.free(tmp_dir_name);
    std.mem.replaceScalar(u8, tmp_dir_name, '/', '-');

    const tmp_work_path = try std.fs.path.join(allocator, &.{ paths.tmp, tmp_dir_name });
    defer allocator.free(tmp_work_path);
    const luarocks_src = @import("sources/luarocks.zig");
    const options_mod = @import("options.zig");

    const derived_rockspec_url = try lockedRockspecUrl(allocator, entry);
    defer if (derived_rockspec_url) |url| allocator.free(url);
    if (std.mem.eql(u8, entry.resolver, "rocks") and derived_rockspec_url == null) {
        error_context.setFmt(
            allocator,
            "Locked LuaRocks replay for {s}@{s} has no recorded rockspec URL. Restore an artifact with provenance or run 'moon sync --update' to refresh the lockfile.",
            .{ entry.name, entry.version },
        );
        return error.ReplayProvenanceMissing;
    }

    const resolve_opts = options_mod.ResolveOptions{
        .locked = true,
        .offline = policy.offline,
        .runtime = if (entry.lua_abi.len > 0) entry.lua_abi else "5.4",
        .runtime_artifact_hash = if (entry.runtime.len > 0) entry.runtime else null,
        .runtime_path = provider.options.runtime_path,
        .runtime_c_api = provider.options.runtime_c_api,
        .target = if (entry.target.len > 0) entry.target else "native",
        .lua_exe = provider.lua_exe,
        .locked_rockspec_url = derived_rockspec_url,
        .locked_rockspec_hash = if (entry.rockspec_hash.len > 0) entry.rockspec_hash else null,
        .locked_source_url = if (entry.source.len > 0) entry.source else null,
        .locked_source_hash = if (entry.source_hash.len > 0) entry.source_hash else null,
        .build_artifacts = build_artifacts,
        .on_event = provider.options.on_event,
        .on_event_context = provider.options.on_event_context,
        .cancellation_flag = provider.options.cancellation_flag,
    };

    const rocks_lookup_name = try allocator.dupe(u8, entry.name);
    defer allocator.free(rocks_lookup_name);
    for (rocks_lookup_name) |*byte| byte.* = std.ascii.toLower(byte.*);

    var cand = luarocks_src.resolve(
        allocator,
        io,
        rocks_lookup_name,
        entry.version,
        resolve_opts,
        env,
        null,
        if (entry.registry.len > 0) entry.registry else "rocks",
    ) catch |err| {
        if (policy.offline and (err == error.NetworkDenied or err == error.HttpFailed)) {
            return error.OfflineReplayInputUnavailable;
        }
        return err;
    };
    errdefer cand.deinit(allocator);

    // `luarocks.resolve` has already materialized and committed this source
    // replay. Keep the candidate out of sync's later remote Rocks scheduler,
    // which is reserved for unresolved candidates selected by PubGrub.
    cand.location = .local_store;

    // Validate plan hash if locked in entry
    if (entry.plan_hash.len > 0) {
        const plan_mod = @import("../materialization/plan.zig");
        const adapter_mod = @import("../materialization/adapter.zig");
        const mod_name = if (entry.name.len > 0) entry.name else "module";
        const tgt_name = if (entry.target.len > 0) entry.target else "native";
        var plan = try adapter_mod.PureLuaAdapter.buildPlan(allocator, entry.name, entry.version, tgt_name, mod_name);
        defer plan.deinit(allocator);

        const computed_plan_hash = try plan_mod.computePlanHash(allocator, &plan);
        defer allocator.free(computed_plan_hash);

        if (!std.mem.eql(u8, computed_plan_hash, entry.plan_hash)) {
            error_context.setFmt(allocator, "Locked materialization plan mismatch for {s}@{s}. Expected plan {s}, but the current plan is {s}. Restore the matching toolchain or run 'moon sync --update' to create a new lockfile.", .{ entry.name, entry.version, entry.plan_hash, computed_plan_hash });
            return error.PlanHashMismatch;
        }
    }

    // Verify artifact_hash match
    if (exact_artifact_hash.len > 0 and !std.mem.eql(u8, cand.artifact_hash, exact_artifact_hash)) {
        error_context.setFmt(allocator, "Locked artifact hash mismatch for {s}@{s}. Expected {s}, but resolution produced {s}. Restore the exact artifact or run 'moon sync --update' to create a new lockfile.", .{ entry.name, entry.version, entry.artifact_hash, cand.artifact_hash });
        return error.ArtifactHashMismatch;
    }

    // LuaRocks resolution materializes the package and commits it to the CAS
    // before returning its candidate. Replaying that commit would rename the
    // returned store path into its own `files` directory on macOS.

    return RealizeResult{
        .candidate = cand,
        .method = .source_rematerialization,
    };
}
