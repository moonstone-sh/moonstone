const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const registry = @import("../../registry/registry.zig");
const driver_mod = @import("../../store/driver.zig");
const semver = @import("../../domain/semver.zig");
const fs = @import("../../platform/fs.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version_range: []const u8,
    index: driver_mod.StoreDriver,
    registries: []const registry.ResolvedRegistry,
    options: options_mod.ResolveOptions,
    env: ?*std.process.Environ.Map,
) !candidate_mod.ResolvedArtifact {
    // Coordinator handles local store check before calling this function.
    _ = index;
    // Proceed directly to remote registry resolution.
    // 1. Check remote registries unless offline
    if (!options.offline) {
        for (registries) |reg| {
            if (resolve_remote(allocator, io, pkg_name, version_range, reg.url, reg.token, options, env)) |res| {
                const art = res.desc.artifact[res.artifact_idx];
                return candidate_mod.Candidate{
                    .name = try allocator.dupe(u8, res.desc.package.name),
                    .version = try allocator.dupe(u8, res.desc.package.version),
                    .kind = res.desc.package.kind,
                    .artifact_hash = try allocator.dupe(u8, art.hash),
                    .runtime = try allocator.dupe(u8, art.runtime),
                    .runtime_artifact_hash = try allocator.dupe(u8, art.runtime_artifact_hash),
                    .lua_abi = try allocator.dupe(u8, art.lua_abi),
                    .lua_api = try allocator.dupe(u8, art.lua_api),
                    .origin = .{
                        .moonstone_registry = .{
                            .url = try allocator.dupe(u8, reg.url),
                            .token = if (reg.token) |t| try allocator.dupe(u8, t) else null,
                            .descriptor_path = try allocator.dupe(u8, res.descriptor_path),
                            .artifact_idx = res.artifact_idx,
                        },
                    },
                    .remote_desc = res.desc,
                    .registry_url = try allocator.dupe(u8, reg.url),
                    .registry_token = if (reg.token) |t| try allocator.dupe(u8, t) else null,
                    .descriptor_path = try allocator.dupe(u8, res.descriptor_path),
                    .artifact_idx = res.artifact_idx,
                };
            } else |err| {
                if (err == error.PackageNotFound) continue;

                continue;
            }
        }
    }


    return error.NoCompatibleCandidateFound;
}

pub fn resolve_remote(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version_range: []const u8,
    registry_url: []const u8,
    token: ?[]const u8,
    options: options_mod.ResolveOptions,
    env: ?*std.process.Environ.Map,
) !candidate_mod.RemoteResolveResult {

    if (options.offline) return error.PackageNotFound;

    var client = registry.RegistryClient.init(allocator, io, registry_url, token, env);
    client.on_event = options.on_event;
    client.on_event_context = options.on_event_context;
    defer client.deinit();

    const host = options.target orelse try get_host_target(allocator);
    defer if (options.target == null) allocator.free(host);

    // Try compact SQLite index first
    const cache_dir = if (env) |e| @import("../../platform/env.zig").get_cache_dir(allocator, e) catch null else null;
    defer if (cache_dir) |cd| allocator.free(cd);

    if (cache_dir) |cd| {
        const compact_versions = client.find_package_versions(cd, pkg_name) catch |err| blk: {
            if (err == error.CompactStoreIndexHashMismatch or err == error.ZstdDecompressionFailed or err == error.CompactStoreIndexContentHashMismatch) return err;
            break :blk @as([]registry.RegistryClient.CompactPackageVersion, &.{});
        };
        defer {
            for (compact_versions) |cv| {
                allocator.free(cv.version);
                allocator.free(cv.descriptor);
            }
            allocator.free(compact_versions);
        }

        if (compact_versions.len > 0) {
            var candidates = std.ArrayList(CandidateEntry).empty;
            defer candidates.deinit(allocator);
            for (compact_versions) |cv| {
                try candidates.append(allocator, .{ .version = cv.version, .descriptor = cv.descriptor });
            }
            if (try resolveFromCandidates(allocator, &client, candidates.items, version_range, options, host)) |result| return result;
        }
    }

    // Fall back to TOML index
    const idx = try client.fetch_index();
    defer idx.deinit(allocator);

    if (try resolveFromIndex(allocator, &client, idx, pkg_name, version_range, options, host)) |result| return result;
    if (try client.fetch_private_index()) |private_idx| {
        defer private_idx.deinit(allocator);
        if (try resolveFromIndex(allocator, &client, private_idx, pkg_name, version_range, options, host)) |result| return result;
    }

    return error.PackageNotFound;
}

const CandidateEntry = struct {
    version: []const u8,
    descriptor: []const u8,
};

fn resolveFromCandidates(
    allocator: std.mem.Allocator,
    client: *registry.RegistryClient,
    entries: []const CandidateEntry,
    version_range: []const u8,
    options: options_mod.ResolveOptions,
    host: []const u8,
) !?candidate_mod.RemoteResolveResult {
    const Candidate = struct {
        version: semver.Version,
        descriptor: []const u8,
    };

    var candidates = std.ArrayList(Candidate).empty;
    defer {
        for (candidates.items) |c| c.version.deinit(allocator);
        candidates.deinit(allocator);
    }

    for (entries) |entry| {
        if (matches(entry.version, version_range)) {
            try candidates.append(allocator, .{
                .version = try semver.Version.parse(entry.version),
                .descriptor = entry.descriptor,
            });
        }
    }

    if (candidates.items.len == 0) return null;

    // Sort descending (highest version first)
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.version.compare(b.version) > 0;
        }
    }.lessThan);

    for (candidates.items) |c| {
        var desc = try client.fetch_descriptor(c.descriptor);
        errdefer desc.deinit(allocator);

        // 1. Try prebuilt match
        for (desc.artifact, 0..) |art, i| {
            if (artifactMatchesRuntimeAbi(art, options) and (std.mem.eql(u8, art.target, host) or std.mem.eql(u8, art.target, "any") or std.mem.eql(u8, art.target, "native"))) {
                const dp = try allocator.dupe(u8, c.descriptor);
                return candidate_mod.RemoteResolveResult{ .desc = desc, .artifact_idx = i, .descriptor_path = dp };
            }
        }

        // 2. Try source fallback
        for (desc.artifact, 0..) |art, i| {
            if (artifactMatchesRuntimeAbi(art, options) and std.mem.eql(u8, art.target, "source")) {
                const dp = try allocator.dupe(u8, c.descriptor);
                return candidate_mod.RemoteResolveResult{ .desc = desc, .artifact_idx = i, .descriptor_path = dp };
            }
        }
        desc.deinit(allocator);
    }

    return null;
}

fn resolveFromIndex(allocator: std.mem.Allocator, client: *registry.RegistryClient, idx: manifest.RemotePackageStoreIndex, pkg_name: []const u8, version_range: []const u8, options: options_mod.ResolveOptions, host: []const u8) !?candidate_mod.RemoteResolveResult {
    var entries = std.ArrayList(CandidateEntry).empty;
    defer entries.deinit(allocator);

    for (idx.package) |pkg| {
        if (packageNamesMatch(pkg.name, pkg_name)) {
            try entries.append(allocator, .{
                .version = pkg.version,
                .descriptor = pkg.descriptor,
            });
        }
    }

    return try resolveFromCandidates(allocator, client, entries.items, version_range, options, host);
}

fn packageNamesMatch(index_name: []const u8, requested_name: []const u8) bool {
    if (std.mem.eql(u8, index_name, requested_name)) return true;
    
    const canonical_req = if (std.mem.eql(u8, requested_name, "lua")) @as([]const u8, "moonstone/lua")
                          else if (std.mem.eql(u8, requested_name, "luajit")) @as([]const u8, "moonstone/luajit")
                          else if (std.mem.eql(u8, requested_name, "love")) @as([]const u8, "moonstone/love")
                          else requested_name;

    const canonical_idx = if (std.mem.eql(u8, index_name, "lua")) @as([]const u8, "moonstone/lua")
                          else if (std.mem.eql(u8, index_name, "luajit")) @as([]const u8, "moonstone/luajit")
                          else if (std.mem.eql(u8, index_name, "love")) @as([]const u8, "moonstone/love")
                          else index_name;

    return std.mem.eql(u8, canonical_idx, canonical_req);
}

fn matches(version: []const u8, range: []const u8) bool {
    return semver.matches(version, range);
}

fn artifactMatchesRuntimeAbi(art: manifest.RemoteArtifact, options: options_mod.ResolveOptions) bool {
    // If the artifact declares its own isolated runtime, it doesn't need to match the project runtime
    if (art.runtime.len > 0) return true;
    
    if (options.runtime) |active_abi| {
        return options_mod.runtimeAbiMatches(active_abi, art.lua_abi);
    }
    return true;
}


fn get_host_target(allocator: std.mem.Allocator) ![]const u8 {
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
