const std = @import("std");
const lockfile_mod = @import("../domain/lockfile.zig");
const LockEntry = lockfile_mod.LockEntry;
const locked_pkg = @import("../domain/locked_package.zig");
const manifest = @import("../domain/manifest.zig");
const store = @import("../store.zig");
const store_driver = @import("../store/driver.zig").StoreDriver;
const package_provider = @import("provider/package_provider.zig");
const candidate_mod = @import("candidate.zig");
const hash_mod = @import("../identity/hash.zig");

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

const graph_provider = @import("provider/graph_provider.zig");

pub fn ensureLockedArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    entry: *const LockEntry,
    provider: *graph_provider.RegistryProvider,
    store_drv: *store_driver,
    policy: ReplayPolicy,
) !RealizeResult {
    _ = store_drv;
    const coordinator_mod = @import("coordinator.zig");
    // 1. Check local CAS index by artifact_hash
    if (entry.artifact_hash.len > 0 and !std.mem.eql(u8, entry.artifact_hash, "link") and !std.mem.eql(u8, entry.artifact_hash, "path")) {
        const req = package_provider.ArtifactRequest{
            .name = entry.name,
            .version = entry.version,
            .resolver = if (entry.resolver.len > 0) coordinator_mod.CoordinatorKind.fromString(entry.resolver) catch null else null,
            .artifact_hash = entry.artifact_hash,
            .runtime = if (entry.runtime.len > 0) entry.runtime else null,
            .lua_abi = if (entry.lua_abi.len > 0) entry.lua_abi else null,
        };

        if (try provider.get_artifact(req)) |cand| {
            return RealizeResult{
                .candidate = cand,
                .method = .local_cas,
            };
        }
    }

    // 2. Assess materializer capability and ReplayContract. The provider above
    // searches the configured registries for an exact remote artifact, so do
    // not fall back to an unrelated default registry here.
    if (entry.replay_mode == .artifact_only) {
        return error.ExactArtifactRequired;
    }

    const capability = assessMaterializerCapability(entry.source_kind);
    if (capability == .exact_artifact_required and entry.replay_mode != .declared_host) {
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

    const resolve_opts = options_mod.ResolveOptions{
        .offline = policy.offline,
        .runtime = if (entry.lua_abi.len > 0) entry.lua_abi else "5.4",
        .runtime_artifact_hash = if (entry.runtime.len > 0) entry.runtime else null,
        .runtime_path = provider.options.runtime_path,
        .runtime_c_api = provider.options.runtime_c_api,
        .target = if (entry.target.len > 0) entry.target else "native",
    };

    var cand = luarocks_src.resolve(allocator, io, entry.name, entry.version, resolve_opts, env) catch |err| {
        if (policy.offline and (err == error.NetworkDenied or err == error.HttpFailed)) {
            return error.OfflineReplayInputUnavailable;
        }
        return err;
    };
    errdefer cand.deinit(allocator);

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
            return error.PlanHashMismatch;
        }
    }

    // Verify artifact_hash match
    if (entry.artifact_hash.len > 0 and !std.mem.eql(u8, cand.artifact_hash, entry.artifact_hash)) {
        return error.ArtifactHashMismatch;
    }

    // Commit rebuilt candidate to CAS store on exact equality
    if (cand.local_path) |lp| {
        const store_facade = @import("../store.zig");
        const manifest_mod = @import("../domain/manifest.zig");
        const remote_desc = manifest_mod.RemotePackageDescriptor{
            .package = .{ .name = cand.name, .version = cand.version, .kind = cand.kind },
            .compat = .{},
        };
        const remote_art = manifest_mod.RemoteArtifact{
            .target = if (entry.target.len > 0) entry.target else "native",
            .lua_abi = if (entry.lua_abi.len > 0) entry.lua_abi else "5.4",
            .hash = cand.artifact_hash,
            .recipe_hash = entry.recipe_hash,
            .url = "",
            .format = "tar.gz",
            .provides = .{},
        };
        _ = store_facade.commit_to_store(allocator, io, env, lp, remote_desc, remote_art, entry.resolver, entry.source, &.{}) catch {};
    }

    return RealizeResult{
        .candidate = cand,
        .method = .source_rematerialization,
    };
}
