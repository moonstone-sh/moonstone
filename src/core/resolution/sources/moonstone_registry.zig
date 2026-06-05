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

    // Try compact SQLite index first
    const cache_dir = if (env) |e| @import("../../platform/env.zig").get_cache_dir(allocator, e) catch null else null;
    defer if (cache_dir) |cd| allocator.free(cd);

    const compact_res = if (cache_dir) |cd| client.find_package_descriptor(cd, pkg_name) catch null else null;
    if (compact_res) |cr| {
        defer allocator.free(cr.version);
        if (matches(cr.version, version_range)) {
            var desc = try client.fetch_descriptor(cr.descriptor);
            errdefer desc.deinit(allocator);

            const host = options.target orelse try get_host_target(allocator);
            defer if (options.target == null) allocator.free(host);

            // 1. Try prebuilt match
            if (desc.artifact.len > 0) {
                for (desc.artifact, 0..) |art, i| {
                    if (artifactMatchesRuntimeAbi(art, options) and (std.mem.eql(u8, art.target, host) or std.mem.eql(u8, art.target, "any") or std.mem.eql(u8, art.target, "native"))) {
                        const dp = try allocator.dupe(u8, cr.descriptor);
                        allocator.free(cr.descriptor);
                        return candidate_mod.RemoteResolveResult{ .desc = desc, .artifact_idx = i, .descriptor_path = dp };
                    }
                }

                // 2. Try source fallback
                for (desc.artifact, 0..) |art, i| {
                    if (artifactMatchesRuntimeAbi(art, options) and std.mem.eql(u8, art.target, "source")) {
                        const dp = try allocator.dupe(u8, cr.descriptor);
                        allocator.free(cr.descriptor);
                        return candidate_mod.RemoteResolveResult{ .desc = desc, .artifact_idx = i, .descriptor_path = dp };
                    }
                }
            }
            desc.deinit(allocator);
        }
        allocator.free(cr.descriptor);
    }

    // Fall back to TOML index
    const idx = try client.fetch_index();
    defer idx.deinit(allocator);

    const host = options.target orelse try get_host_target(allocator);
    defer if (options.target == null) allocator.free(host);

    if (try resolveFromIndex(allocator, &client, idx, pkg_name, version_range, options, host)) |result| return result;
    if (try client.fetch_private_index()) |private_idx| {
        defer private_idx.deinit(allocator);
        if (try resolveFromIndex(allocator, &client, private_idx, pkg_name, version_range, options, host)) |result| return result;
    }

    return error.PackageNotFound;
}

fn resolveFromIndex(allocator: std.mem.Allocator, client: *registry.RegistryClient, idx: manifest.RemotePackageStoreIndex, pkg_name: []const u8, version_range: []const u8, options: options_mod.ResolveOptions, host: []const u8) !?candidate_mod.RemoteResolveResult {
    for (idx.package) |pkg| {
        if (packageNamesMatch(pkg.name, pkg_name)) {
            if (matches(pkg.version, version_range)) {

                var desc = try client.fetch_descriptor(pkg.descriptor);
                errdefer desc.deinit(allocator);

                // 1. Try prebuilt match
                for (desc.artifact, 0..) |art, i| {
                    if (artifactMatchesRuntimeAbi(art, options) and (std.mem.eql(u8, art.target, host) or std.mem.eql(u8, art.target, "any") or std.mem.eql(u8, art.target, "native"))) {
                        const dp = try allocator.dupe(u8, pkg.descriptor);
                        return candidate_mod.RemoteResolveResult{ .desc = desc, .artifact_idx = i, .descriptor_path = dp };
                    }
                }

                // 2. Try source fallback
                for (desc.artifact, 0..) |art, i| {
                    if (artifactMatchesRuntimeAbi(art, options) and std.mem.eql(u8, art.target, "source")) {
                        const dp = try allocator.dupe(u8, pkg.descriptor);
                        return candidate_mod.RemoteResolveResult{ .desc = desc, .artifact_idx = i, .descriptor_path = dp };
                    }
                }
                desc.deinit(allocator);
            }
        }
    }

    return null;
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
