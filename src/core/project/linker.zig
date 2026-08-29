const std = @import("std");
const builtin = @import("builtin");
const UNIQUE_BUILD_MARKER = "UNIQUE_BUILD_MARKER_20250608_1847";
const manifest = @import("../domain/manifest.zig");
const package_spec = @import("../domain/package_spec.zig");
const driver_mod = @import("../store/driver.zig");
const semver = @import("../domain/semver.zig");
const executable = @import("../platform/executable.zig");

pub const ProjectEnv = struct {
    bin_map: std.array_hash_map.String(struct { path: []const u8, artifact_hash: []const u8 }),
    lua_map: std.array_hash_map.String(struct { path: []const u8, artifact_hash: []const u8 }),
};

pub const LiveLink = struct {
    name: []const u8,
    source_path: []const u8,
    mode: []const u8,
    pkg_name: []const u8,
    pkg_version: []const u8,
    pkg_kind: manifest.Kind,
    role: @import("../domain/dependency_role.zig").DependencyRole = .runtime,
};

pub const ProjectedArtifact = struct {
    name: []const u8,
    version: []const u8,
    kind: @import("../domain/manifest.zig").Kind = .lib,
    constraint: []const u8,
    resolver: ?[]const u8,
    role: @import("../domain/dependency_role.zig").DependencyRole,
    artifact_hash: []const u8,
    lua_abi: ?[]const u8,
    lua_api: ?[]const u8,
    target: ?[]const u8,
    path: ?[]const u8,
};

fn runtimeInfoFromLiveLinks(
    allocator: std.mem.Allocator,
    io: std.Io,
    live_links: []const LiveLink,
) !?driver_mod.RuntimeProvision {
    for (live_links) |link| {
        if (link.pkg_kind != .runtime) continue;

        const manifest_path = try std.fs.path.join(allocator, &.{ link.source_path, "moonstone.toml" });
        defer allocator.free(manifest_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(content);

        var mt = manifest.MoonstoneToml.parse(allocator, content) catch continue;
        defer mt.deinit(allocator);
        if (mt.package.kind != .runtime) continue;

        return driver_mod.RuntimeProvision{
            .artifact_hash = try allocator.dupe(u8, "link"),
            .name = try allocator.dupe(u8, mt.runtimeName()),
            .version = try allocator.dupe(u8, mt.runtimeVersion()),
            .abi = try allocator.dupe(u8, mt.runtimeAbi()),
        };
    }

    return null;
}

fn runtimeBinPathFromSpec(
    allocator: std.mem.Allocator,
    index: driver_mod.StoreDriver,
    runtime_spec: []const u8,
) !?[]const u8 {
    if (runtime_spec.len == 0) return null;
    var spec = try package_spec.parsePackageSpec(allocator, runtime_spec);
    defer spec.deinit(allocator);

    var runtime_name = package_spec.canonicalOfficialRuntime(spec.name);
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

        for (candidates) |candidate| {
            const candidate_name = if (std.mem.startsWith(u8, candidate.name, "moonstone/")) candidate.name["moonstone/".len..] else candidate.name;
            if (std.mem.eql(u8, candidate_name, runtime_name) and semver.matches(candidate.version, runtime_constraint)) {
                return try std.fs.path.join(allocator, &.{ candidate.path, "files", "bin" });
            }
        }
    }
    return null;
}

fn isResolvableRuntimeSpec(runtime_spec: []const u8) bool {
    if (runtime_spec.len == 0) return false;
    if (std.mem.eql(u8, runtime_spec, "lua@unknown")) return false;
    if (std.mem.startsWith(u8, runtime_spec, "table:")) return false;
    if (std.mem.indexOfScalar(u8, runtime_spec, '@')) |at| return at > 0 and at + 1 < runtime_spec.len;
    return true;
}

fn runtimeSpecFromArtifactManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    artifact_hash: []const u8,
) !?[]const u8 {
    const art_path = try index.get_artifact_path(artifact_hash) orelse return null;
    defer allocator.free(art_path);

    const manifest_path = try std.fs.path.join(allocator, &.{ art_path, "manifest.toml" });
    defer allocator.free(manifest_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);

    var store_manifest = try manifest.StoreManifest.parse(allocator, content);
    defer store_manifest.deinit(allocator);

    if (!isResolvableRuntimeSpec(store_manifest.compat.runtime_version)) return null;
    return try allocator.dupe(u8, store_manifest.compat.runtime_version);
}

fn writeLiveLinkScope(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_dir: std.Io.Dir,
    index: driver_mod.StoreDriver,
    scope_root: []const u8,
    bin_name: []const u8,
    source_path: []const u8,
    lua_ver_dot: []const u8,
    project_runtime_bin_path: ?[]const u8,
) !void {
    const scope_dir_rel = try std.fs.path.join(allocator, &.{ scope_root, bin_name });
    defer allocator.free(scope_dir_rel);
    try env_dir.createDirPath(io, scope_dir_rel);

    var scope_dir = try env_dir.openDir(io, scope_dir_rel, .{});
    defer scope_dir.close(io);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try aw.writer.print("[env]\n", .{});

    const bin_dir_path = try std.fs.path.join(allocator, &.{ source_path, "bin" });
    defer allocator.free(bin_dir_path);

    // Prefer the linked package's declared runtime; fall back to the project runtime.
    var scoped_runtime_bin_path: ?[]const u8 = null;
    defer if (scoped_runtime_bin_path) |pth| allocator.free(pth);

    const linked_manifest_path = try std.fs.path.join(allocator, &.{ source_path, "moonstone.toml" });
    defer allocator.free(linked_manifest_path);
    if (std.Io.Dir.cwd().access(io, linked_manifest_path, .{})) |_| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, linked_manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
        if (content) |c| {
            defer allocator.free(c);
            var linked_mt: ?manifest.MoonstoneToml = manifest.MoonstoneToml.parse(allocator, c) catch null;
            defer if (linked_mt) |*lmt| lmt.deinit(allocator);
            if (linked_mt) |*mt| {
                const rt_spec = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ mt.runtime.name, mt.runtime.version });
                defer allocator.free(rt_spec);
                if (rt_spec.len > 0) {
                    scoped_runtime_bin_path = try runtimeBinPathFromSpec(allocator, index, rt_spec);
                }
            }
        }
    } else |_| {}
    if (scoped_runtime_bin_path == null and project_runtime_bin_path != null) {
        scoped_runtime_bin_path = try allocator.dupe(u8, project_runtime_bin_path.?);
    }

    if (scoped_runtime_bin_path) |runtime_path| {
        const paths = [_][]const u8{ bin_dir_path, runtime_path };
        try writeScopedPathPrepend(&aw.writer, &paths);
    } else {
        const paths = [_][]const u8{bin_dir_path};
        try writeScopedPathPrepend(&aw.writer, &paths);
    }

    const src_lua_path = try std.fs.path.join(allocator, &.{ source_path, "src", "?.lua" });
    defer allocator.free(src_lua_path);
    const src_init_path = try std.fs.path.join(allocator, &.{ source_path, "src", "?", "init.lua" });
    defer allocator.free(src_init_path);
    const env_lua_path = try std.fmt.allocPrint(allocator, ".moonstone/env/share/lua/{s}/?.lua", .{lua_ver_dot});
    defer allocator.free(env_lua_path);
    const env_init_path = try std.fmt.allocPrint(allocator, ".moonstone/env/share/lua/{s}/?/init.lua", .{lua_ver_dot});
    defer allocator.free(env_init_path);

    try aw.writer.print("lua_path = [\"{s}\", \"{s}\", \"{s}\", \"{s}\"]\n", .{ src_lua_path, src_init_path, env_lua_path, env_init_path });
    try aw.writer.flush();

    const file = try scope_dir.createFile(io, "env.toml", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);
}

fn resolveScopedRuntimeBinPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    artifact_hash: []const u8,
) !?[]const u8 {
    var owner = try index.get_candidate_by_hash(artifact_hash) orelse return null;
    defer owner.deinit(allocator);

    if (owner.runtime_artifact_hash) |runtime_hash| {
        if (runtime_hash.len > 0) {
            if (try runtimeBinPathFromHash(allocator, index, runtime_hash)) |path| return path;
        }
    }

    var manifest_runtime_spec: ?[]const u8 = null;
    defer if (manifest_runtime_spec) |runtime_spec| allocator.free(runtime_spec);

    const runtime_spec = blk: {
        if (owner.runtime) |runtime| {
            if (isResolvableRuntimeSpec(runtime)) break :blk runtime;
        }
        if (try runtimeSpecFromArtifactManifest(allocator, io, index, artifact_hash)) |runtime| {
            manifest_runtime_spec = runtime;
            break :blk runtime;
        }
        return null;
    };

    return try runtimeBinPathFromSpec(allocator, index, runtime_spec);
}

fn runtimeBinPathFromHash(
    allocator: std.mem.Allocator,
    index: driver_mod.StoreDriver,
    runtime_hash: []const u8,
) !?[]const u8 {
    const runtime_path = try index.get_artifact_path(runtime_hash) orelse return null;
    defer allocator.free(runtime_path);
    return try std.fs.path.join(allocator, &.{ runtime_path, "files", "bin" });
}

fn appendUniqueOwnedPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), path: []const u8) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            allocator.free(path);
            return;
        }
    }
    errdefer allocator.free(path);
    try paths.append(allocator, path);
}

fn deinitProvisions(allocator: std.mem.Allocator, provisions: anytype) void {
    for (provisions.bins) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.bin_luas) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.headers) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.libs) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.lua_modules) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.lua_cmodules) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.scripts) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.assets) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    for (provisions.ballad_plugins) |provision| {
        var mutable_provision = provision;
        mutable_provision.deinit(allocator);
    }
    allocator.free(provisions.bins);
    allocator.free(provisions.bin_luas);
    allocator.free(provisions.headers);
    allocator.free(provisions.libs);
    allocator.free(provisions.lua_modules);
    allocator.free(provisions.lua_cmodules);
    allocator.free(provisions.scripts);
    allocator.free(provisions.assets);
    allocator.free(provisions.ballad_plugins);
}

fn luaAbiDigits(abi: []const u8) ?u32 {
    var result: u32 = 0;
    var found_digit = false;
    for (abi) |ch| {
        if (std.ascii.isDigit(ch)) {
            found_digit = true;
            result = result * 10 + (ch - '0');
        }
    }
    return if (found_digit) result else null;
}

fn luaAbisCompatible(left: ?[]const u8, right: ?[]const u8) bool {
    const left_abi = left orelse return true;
    const right_abi = right orelse return true;
    if (left_abi.len == 0 or right_abi.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(left_abi, right_abi)) return true;
    const left_digits = luaAbiDigits(left_abi) orelse return false;
    const right_digits = luaAbiDigits(right_abi) orelse return false;
    return left_digits == right_digits;
}

fn scopeArtifactAbiCompatible(owner_abi: ?[]const u8, artifact_abi: ?[]const u8, has_native_lua_modules: bool) bool {
    return luaAbisCompatible(owner_abi, artifact_abi) or !has_native_lua_modules;
}

fn provisionModuleRoot(allocator: std.mem.Allocator, provision: manifest.FeatureProvision) !?[]const u8 {
    const module_relative_path = try std.mem.replaceOwned(u8, allocator, provision.name, ".", "/");
    defer allocator.free(module_relative_path);
    const extension = std.fs.path.extension(provision.path);
    const direct_suffix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ module_relative_path, extension });
    defer allocator.free(direct_suffix);
    const init_suffix = try std.fmt.allocPrint(allocator, "{s}/init{s}", .{ module_relative_path, extension });
    defer allocator.free(init_suffix);

    const suffix = if (std.mem.endsWith(u8, provision.path, direct_suffix)) direct_suffix else if (std.mem.endsWith(u8, provision.path, init_suffix)) init_suffix else return null;
    var root_end = provision.path.len - suffix.len;
    if (root_end > 0 and provision.path[root_end - 1] == std.fs.path.sep) root_end -= 1;
    return try allocator.dupe(u8, provision.path[0..root_end]);
}

fn findProjectedArtifact(
    projected_artifacts: []const ProjectedArtifact,
    artifact_hash: []const u8,
) ?*const ProjectedArtifact {
    for (projected_artifacts) |*artifact| {
        if (std.mem.eql(u8, artifact.artifact_hash, artifact_hash)) return artifact;
    }
    return null;
}

fn findResolvedDependency(
    projected_artifacts: []const ProjectedArtifact,
    dependency: manifest.StoreDependency,
) ?*const ProjectedArtifact {
    for (projected_artifacts) |*artifact| {
        if (!std.ascii.eqlIgnoreCase(artifact.name, dependency.name)) continue;
        return artifact;
    }
    return null;
}

fn appendScopeClosure(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    projected_artifacts: []const ProjectedArtifact,
    owner_abi: ?[]const u8,
    artifact: *const ProjectedArtifact,
    visited: *std.StringHashMapUnmanaged(void),
    closure: *std.ArrayList(*const ProjectedArtifact),
) !void {
    const result = try visited.getOrPut(allocator, artifact.artifact_hash);
    if (result.found_existing) return;
    try closure.append(allocator, artifact);

    const artifact_path = try index.get_artifact_path(artifact.artifact_hash) orelse return;
    defer allocator.free(artifact_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ artifact_path, "manifest.toml" });
    defer allocator.free(manifest_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(content);

    var store_manifest = try manifest.StoreManifest.parse(allocator, content);
    defer store_manifest.deinit(allocator);

    // Lua ABI boundaries are mandatory for native modules, but pure Lua
    // dependencies are portable source files. A tool such as Ballad may run
    // under LuaJIT while the hosting project uses Lua 5.4; its pure-Lua
    // transitive dependencies still belong to the tool scope.
    if (!scopeArtifactAbiCompatible(owner_abi, artifact.lua_abi, store_manifest.provides.lua_cmodule.len != 0)) {
        return error.ScopeDependencyAbiMismatch;
    }

    for (store_manifest.dependencies) |dependency| {
        if (dependency.optional) continue;
        const resolved_dependency = findResolvedDependency(projected_artifacts, dependency) orelse return error.ScopeDependencyNotResolved;
        try appendScopeClosure(allocator, io, index, projected_artifacts, owner_abi, resolved_dependency, visited, closure);
    }
}

fn collectScopeClosure(
    allocator: std.mem.Allocator,
    io: std.Io,
    index: driver_mod.StoreDriver,
    projected_artifacts: []const ProjectedArtifact,
    artifact_hash: []const u8,
) !std.ArrayList(*const ProjectedArtifact) {
    const owner = findProjectedArtifact(projected_artifacts, artifact_hash) orelse return error.ScopeOwnerNotResolved;
    var closure = std.ArrayList(*const ProjectedArtifact).empty;
    errdefer closure.deinit(allocator);
    var visited = std.StringHashMapUnmanaged(void).empty;
    defer visited.deinit(allocator);
    try appendScopeClosure(allocator, io, index, projected_artifacts, owner.lua_abi, owner, &visited, &closure);
    return closure;
}

fn writeScopedPathPrepend(writer: *std.Io.Writer, paths: []const []const u8) !void {
    try writer.print("path_prepend = [", .{});
    var index = paths.len;
    while (index > 0) {
        index -= 1;
        if (index != paths.len - 1) try writer.print(", ", .{});
        try writer.print("\"{s}\"", .{paths[index]});
    }
    try writer.print("]\n", .{});
}

fn writeTomlPathList(writer: *std.Io.Writer, key: []const u8, paths: []const []const u8) !void {
    try writer.print("{s} = [", .{key});
    for (paths, 0..) |path, path_index| {
        if (path_index > 0) try writer.print(", ", .{});
        try writer.print("\"{s}\"", .{path});
    }
    try writer.print("]\n", .{});
}

fn writeRuntimeScope(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_dir: std.Io.Dir,
    index: driver_mod.StoreDriver,
    scope_root: []const u8,
    bin_name: []const u8,
    bin_path: []const u8,
    artifact_hash: []const u8,
    include_module_paths: bool,
    runtime_bin_path: ?[]const u8,
    projected_artifacts: []const ProjectedArtifact,
) !void {
    const scope_dir_rel = try std.fs.path.join(allocator, &.{ scope_root, bin_name });
    defer allocator.free(scope_dir_rel);
    try env_dir.createDirPath(io, scope_dir_rel);
    var scope_dir = try env_dir.openDir(io, scope_dir_rel, .{});
    defer scope_dir.close(io);

    var scope_aw = std.Io.Writer.Allocating.init(allocator);
    defer scope_aw.deinit();
    try scope_aw.writer.print("[env]\n", .{});

    const bin_dir_path = std.fs.path.dirname(bin_path) orelse bin_path;

    var computed_runtime_bin_path: ?[]const u8 = null;
    defer if (computed_runtime_bin_path) |p| allocator.free(p);
    const effective_runtime_bin_path = if (runtime_bin_path) |p| p else blk: {
        computed_runtime_bin_path = try resolveScopedRuntimeBinPath(allocator, io, index, artifact_hash);
        break :blk computed_runtime_bin_path;
    };

    var scope_closure = try collectScopeClosure(allocator, io, index, projected_artifacts, artifact_hash);
    defer scope_closure.deinit(allocator);

    var path_prepend = std.ArrayList([]const u8).empty;
    defer {
        for (path_prepend.items) |path| allocator.free(path);
        path_prepend.deinit(allocator);
    }
    try appendUniqueOwnedPath(allocator, &path_prepend, try allocator.dupe(u8, bin_dir_path));

    var lua_paths = std.ArrayList([]const u8).empty;
    defer {
        for (lua_paths.items) |path| allocator.free(path);
        lua_paths.deinit(allocator);
    }
    var lua_cpaths = std.ArrayList([]const u8).empty;
    defer {
        for (lua_cpaths.items) |path| allocator.free(path);
        lua_cpaths.deinit(allocator);
    }

    for (scope_closure.items) |scope_artifact| {
        const art_path = try index.get_artifact_path(scope_artifact.artifact_hash) orelse continue;
        defer allocator.free(art_path);
        const provisions = try index.get_provisions(scope_artifact.artifact_hash);
        defer deinitProvisions(allocator, provisions);

        for (provisions.bins) |provision| {
            const bin_dir = std.fs.path.dirname(provision.path) orelse continue;
            try appendUniqueOwnedPath(allocator, &path_prepend, try std.fs.path.join(allocator, &.{ art_path, "files", bin_dir }));
        }
        if (!include_module_paths) continue;

        for (provisions.lua_modules) |provision| {
            const module_root = try provisionModuleRoot(allocator, provision) orelse continue;
            defer allocator.free(module_root);
            const absolute_module_root = try std.fs.path.join(allocator, &.{ art_path, "files", module_root });
            defer allocator.free(absolute_module_root);
            try appendUniqueOwnedPath(allocator, &lua_paths, try std.fs.path.join(allocator, &.{ absolute_module_root, "?.lua" }));
            try appendUniqueOwnedPath(allocator, &lua_paths, try std.fs.path.join(allocator, &.{ absolute_module_root, "?", "init.lua" }));
        }
        for (provisions.lua_cmodules) |provision| {
            const module_root = try provisionModuleRoot(allocator, provision) orelse continue;
            defer allocator.free(module_root);
            const absolute_module_root = try std.fs.path.join(allocator, &.{ art_path, "files", module_root });
            defer allocator.free(absolute_module_root);
            for (luaCmoduleExtensions()) |extension| {
                const pattern = try std.fmt.allocPrint(allocator, "?{s}", .{extension});
                defer allocator.free(pattern);
                try appendUniqueOwnedPath(allocator, &lua_cpaths, try std.fs.path.join(allocator, &.{ absolute_module_root, pattern }));
            }
        }
    }
    if (effective_runtime_bin_path) |runtime_path| {
        try appendUniqueOwnedPath(allocator, &path_prepend, try allocator.dupe(u8, runtime_path));
    }

    try writeScopedPathPrepend(&scope_aw.writer, path_prepend.items);

    if (lua_paths.items.len > 0) try writeTomlPathList(&scope_aw.writer, "lua_path", lua_paths.items);
    if (lua_cpaths.items.len > 0) try writeTomlPathList(&scope_aw.writer, "lua_cpath", lua_cpaths.items);

    try scope_aw.writer.flush();
    const scope_toml_file = try scope_dir.createFile(io, "env.toml", .{});
    defer scope_toml_file.close(io);
    try scope_toml_file.writeStreamingAll(io, scope_aw.writer.buffer[0..scope_aw.writer.end]);
}
fn writeLiveLinkScriptShim(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin_dir: std.Io.Dir,
    bin_name: []const u8,
    source_path: []const u8,
    script_command: []const u8,
) !void {
    const entry = if (std.mem.startsWith(u8, script_command, "lua ")) script_command[4..] else script_command;
    const shim_name = if (comptime builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "{s}.cmd", .{bin_name})
    else
        try allocator.dupe(u8, bin_name);
    defer allocator.free(shim_name);

    const shim = if (comptime builtin.os.tag == .windows) try std.fmt.allocPrint(allocator,
        \\@echo off
        \\setlocal EnableExtensions DisableDelayedExpansion
        \\set "TOOL_ROOT={s}"
        \\set "LUA_BIN=%TOOL_ROOT%\\.moonstone\\env\\bin\\lua.exe"
        \\if not exist "%LUA_BIN%" set "LUA_BIN=lua.exe"
        \\set "LUA_PATH=%TOOL_ROOT%\\src\\?.lua;%TOOL_ROOT%\\src\\?\\init.lua;%LUA_PATH%;;"
        \\set "LUA_CPATH=%TOOL_ROOT%\\.moonstone\\env\\lib\\lua\\?.dll;%LUA_CPATH%;;"
        \\"%LUA_BIN%" "%TOOL_ROOT%\\{s}" %*
        \\exit /b %ERRORLEVEL%
        \\
    , .{ source_path, entry }) else try std.fmt.allocPrint(allocator,
        \\#!/usr/bin/env sh
        \\set -eu
        \\TOOL_ROOT="{s}"
        \\LUA_BIN="$TOOL_ROOT/.moonstone/env/bin/lua"
        \\if [ ! -x "$LUA_BIN" ]; then LUA_BIN="lua"; fi
        \\
        \\LUA_PATH_STR="$TOOL_ROOT/src/?.lua;$TOOL_ROOT/src/?/init.lua"
        \\if [ -d "$TOOL_ROOT/.moonstone/env/share/lua" ]; then
        \\  for d in "$TOOL_ROOT/.moonstone/env/share/lua/"*; do
        \\    if [ -d "$d" ]; then
        \\      V=$(basename "$d")
        \\      LUA_PATH_STR="$LUA_PATH_STR;$TOOL_ROOT/.moonstone/env/share/lua/$V/?.lua;$TOOL_ROOT/.moonstone/env/share/lua/$V/?/init.lua"
        \\    fi
        \\  done
        \\fi
        \\export LUA_PATH="$LUA_PATH_STR;${{LUA_PATH:-}};;"
        \\
        \\LUA_CPATH_STR=""
        \\if [ -d "$TOOL_ROOT/.moonstone/env/lib/lua" ]; then
        \\  for d in "$TOOL_ROOT/.moonstone/env/lib/lua/"*; do
        \\    if [ -d "$d" ]; then
        \\      V=$(basename "$d")
        \\      LUA_CPATH_STR="$LUA_CPATH_STR;$TOOL_ROOT/.moonstone/env/lib/lua/$V/?.so;$TOOL_ROOT/.moonstone/env/lib/lua/$V/?.dylib"
        \\    fi
        \\  done
        \\fi
        \\export LUA_CPATH="${{LUA_CPATH_STR#;}};${{LUA_CPATH:-}};;"
        \\
        \\exec "$LUA_BIN" "$TOOL_ROOT/{s}" "$@"
        \\
    , .{ source_path, entry });
    defer allocator.free(shim);

    bin_dir.deleteFile(io, shim_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    const file = try bin_dir.createFile(io, shim_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, shim);
    if (comptime builtin.os.tag != .windows) {
        try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
    }
}

const ProjectionMethod = enum { linked, copied };

/// Zig 0.16's Windows `Dir.symLink` sets the reparse point itself. Its
/// `deviceIoControl(.SET_REPARSE_POINT)` maps `PRIVILEGE_NOT_HELD` and
/// `ACCESS_DENIED` explicitly, but sends every other NTSTATUS through
/// `windows.unexpectedStatus`; that intentionally loses the status and returns
/// `error.Unexpected`. Wine's `STATUS_NOT_SUPPORTED` (0xc00000bb) therefore
/// reaches Moonstone as `Unexpected`, with no status value left to inspect.
///
/// Keep that unavoidable compatibility escape hatch at this exact derived-env
/// projection boundary. Do not apply it to other filesystem operations: their
/// `Unexpected` errors still propagate normally.
fn isWindowsProjectionSymlinkFallback(err: anyerror) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return switch (err) {
        error.AccessDenied, error.PermissionDenied, error.Unexpected => true,
        else => false,
    };
}

/// `Dir.symLink` creates the destination as a normal entry before attempting
/// to set its Windows reparse point. Remove that partial entry before copying
/// after an unavailable-symlink fallback; otherwise the failed link can block
/// the replacement copy.
fn removeFailedFileSymlinkEntry(io: std.Io, destination_dir: std.Io.Dir, destination_name: []const u8) !void {
    destination_dir.deleteFile(io, destination_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

fn removeFailedDirectorySymlinkEntry(io: std.Io, destination_dir: std.Io.Dir, destination_name: []const u8) !void {
    destination_dir.deleteTree(io, destination_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };
}

/// A package descriptor's public binary name is logical (`lua`), while a
/// Windows store payload is physically suffixed (`lua.exe`, `tool.cmd`, or
/// `tool.bat`). Preserve that physical suffix in the environment so both PATH
/// and explicit environment-bin lookup can execute the projected file.
fn windowsExecutableProjectionExtension(
    logical_name: []const u8,
    source_path: []const u8,
    is_windows: bool,
) ?[]const u8 {
    if (!is_windows or std.fs.path.extension(logical_name).len != 0) return null;
    return executable.windowsExecutableExtension(source_path);
}

fn needsWindowsExeProjection(
    logical_name: []const u8,
    source_path: []const u8,
    is_windows: bool,
) bool {
    return windowsExecutableProjectionExtension(logical_name, source_path, is_windows) != null;
}

fn projectFileWithFallback(
    io: std.Io,
    destination_dir: std.Io.Dir,
    source_path: []const u8,
    destination_name: []const u8,
) !ProjectionMethod {
    destination_dir.deleteFile(io, destination_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    destination_dir.symLink(io, source_path, destination_name, .{}) catch |err| {
        if (!isWindowsProjectionSymlinkFallback(err)) return err;
        // A project environment is derived state, unlike the immutable store.
        // Copy only this projection when Windows cannot create its symlink.
        try removeFailedFileSymlinkEntry(io, destination_dir, destination_name);
        try std.Io.Dir.cwd().copyFile(source_path, destination_dir, destination_name, io, .{ .replace = true });
        return .copied;
    };
    return .linked;
}

fn projectFile(
    io: std.Io,
    destination_dir: std.Io.Dir,
    source_path: []const u8,
    destination_name: []const u8,
) !void {
    _ = try projectFileWithFallback(io, destination_dir, source_path, destination_name);
}

/// Projected PE launchers need co-located DLLs in the environment. A symlinked
/// launcher resolves those from its store directory, but a copied launcher
/// does not. Copy only immediate sibling DLLs; never recurse or copy arbitrary
/// files. Replacing an existing entry makes rebuilds converge on this source.
fn copySiblingDllsForWindows(
    io: std.Io,
    destination_dir: std.Io.Dir,
    source_path: []const u8,
    is_windows: bool,
) !void {
    if (!is_windows) return;

    const source_parent = std.fs.path.dirname(source_path) orelse return;
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_parent, .{ .iterate = true });
    defer source_dir.close(io);

    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.name), ".dll")) continue;
        // Remove first rather than allowing a replacement copy to follow an
        // old projected symlink. This makes collisions safe and deterministic
        // across environment rebuilds.
        destination_dir.deleteFile(io, entry.name) catch |err| {
            if (err != error.FileNotFound) return err;
        };
        try source_dir.copyFile(entry.name, destination_dir, entry.name, io, .{ .replace = false });
    }
}

fn projectExecutable(
    io: std.Io,
    destination_dir: std.Io.Dir,
    source_path: []const u8,
    destination_name: []const u8,
    is_windows: bool,
) !void {
    _ = try projectFileWithFallback(io, destination_dir, source_path, destination_name);
    try copySiblingDllsForWindows(io, destination_dir, source_path, is_windows);
}

fn projectTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination_dir: std.Io.Dir,
    source_path: []const u8,
) !void {
    var source_dir = std.Io.Dir.openDirAbsolute(io, source_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer source_dir.close(io);

    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const source_file = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_file);

        if (entry.kind == .directory) {
            try destination_dir.createDirPath(io, entry.name);
            var child_destination_dir = try destination_dir.openDir(io, entry.name, .{});
            defer child_destination_dir.close(io);
            try projectTree(allocator, io, child_destination_dir, source_file);
        } else {
            try projectFile(io, destination_dir, source_file, entry.name);
        }
    }
}

fn projectDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination_dir: std.Io.Dir,
    source_path: []const u8,
    destination_name: []const u8,
) !void {
    destination_dir.deleteTree(io, destination_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    destination_dir.symLink(io, source_path, destination_name, .{ .is_directory = true }) catch |err| {
        if (!isWindowsProjectionSymlinkFallback(err)) return err;
        try removeFailedDirectorySymlinkEntry(io, destination_dir, destination_name);
        try destination_dir.createDirPath(io, destination_name);
        var copied_dir = try destination_dir.openDir(io, destination_name, .{});
        defer copied_dir.close(io);
        try projectTree(allocator, io, copied_dir, source_path);
        return;
    };
}

fn packageLocalName(pkg_name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, pkg_name, '/')) |pos| return pkg_name[pos + 1 ..];
    return pkg_name;
}

fn writeTomlString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn liveLinkScriptCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
) !?[]const u8 {
    const main_path = try std.fs.path.join(allocator, &.{ source_path, "src", "main.lua" });
    defer allocator.free(main_path);

    std.Io.Dir.cwd().access(io, main_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };

    return try allocator.dupe(u8, "lua src/main.lua");
}

pub fn link_project_env(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: std.Io.Dir,
    index: driver_mod.StoreDriver,
    projected_artifacts: []const ProjectedArtifact,
    live_links: []const LiveLink,
    project_runtime_name: []const u8,
) !void {
    try link_project_env_at(allocator, io, project_root, index, projected_artifacts, live_links, ".moonstone/env", &std.process.environ_map, project_runtime_name);
}

pub fn link_project_env_at(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: std.Io.Dir,
    index: driver_mod.StoreDriver,
    projected_artifacts: []const ProjectedArtifact,
    live_links: []const LiveLink,
    env_path: []const u8,
    env_map: *std.process.Environ.Map,
    project_runtime_name: []const u8,
) !void {
    _ = env_map;
    const MapType = struct { path: []const u8, artifact_hash: []const u8, role: @import("../domain/dependency_role.zig").DependencyRole };
    const UnmanagedMap = std.StringArrayHashMapUnmanaged(MapType);

    var public_bin_map = UnmanagedMap.empty;
    defer {
        var it = public_bin_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        public_bin_map.deinit(allocator);
    }

    var tool_bin_map = UnmanagedMap.empty;
    defer {
        var it = tool_bin_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        tool_bin_map.deinit(allocator);
    }

    var helper_bin_map = UnmanagedMap.empty;
    defer {
        var it = helper_bin_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        helper_bin_map.deinit(allocator);
    }

    var lua_map = UnmanagedMap.empty;
    defer {
        var it = lua_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        lua_map.deinit(allocator);
    }

    var cmod_map = UnmanagedMap.empty;
    defer {
        var it = cmod_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        cmod_map.deinit(allocator);
    }

    var native_lib_map = UnmanagedMap.empty;
    defer {
        var it = native_lib_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        native_lib_map.deinit(allocator);
    }

    var runtime_info: ?driver_mod.RuntimeProvision = null;
    defer if (runtime_info) |*r| r.deinit(allocator);

    var project_runtime_bin_path: ?[]const u8 = null;
    defer if (project_runtime_bin_path) |pth| allocator.free(pth);

    // 2. Query all provisions and check for conflicts
    for (projected_artifacts) |pa| {
        const hash = pa.artifact_hash;
        const policy = pa.role.getProjectionPolicy();

        if (policy.metadata_only) continue;

        const art_path = try index.get_artifact_path(hash) orelse return error.ArtifactMissingFromStoreIndex;
        defer allocator.free(art_path);

        // Runtime artifacts that are not the project's selected runtime are
        // isolated runtimes pulled in by tool/bin packages. They must not
        // contribute public bins/modules to the root environment (that would
        // conflict with the project runtime), but they remain available for
        // scoped bin-runtime env resolution.
        const is_project_runtime = pa.kind != .runtime or blk: {
            const bare_project = if (std.mem.startsWith(u8, project_runtime_name, "moonstone/")) project_runtime_name["moonstone/".len..] else project_runtime_name;
            const bare_artifact = if (std.mem.startsWith(u8, pa.name, "moonstone/")) pa.name["moonstone/".len..] else pa.name;
            break :blk std.mem.eql(u8, bare_project, bare_artifact);
        };
        if (!is_project_runtime) continue;

        if (try index.get_provision_runtime(hash)) |r| {
            var provision = r;
            // Only treat the artifact as the project runtime if its name matches;
            // other runtimes are isolated runtimes for tool/bin packages.
            const bare_project_rt = if (std.mem.startsWith(u8, project_runtime_name, "moonstone/")) project_runtime_name["moonstone/".len..] else project_runtime_name;
            const bare_provision_rt = if (std.mem.startsWith(u8, provision.name, "moonstone/")) provision.name["moonstone/".len..] else provision.name;
            if (std.mem.eql(u8, bare_provision_rt, bare_project_rt)) {
                if (runtime_info) |existing| {
                    if (!@import("../resolution/options.zig").runtimeAbiMatches(existing.abi, provision.abi)) {
                        provision.deinit(allocator);
                        return error.ABIMismatch;
                    }
                }
                if (runtime_info == null) {
                    runtime_info = provision;
                    if (project_runtime_bin_path) |old_bin| allocator.free(old_bin);
                    project_runtime_bin_path = try std.fs.path.join(allocator, &.{ art_path, "files", "bin" });
                } else {
                    provision.deinit(allocator);
                }
            } else {
                provision.deinit(allocator);
            }
        }

        const provs = try index.get_provisions(hash);
        defer {
            for (provs.bins) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.bin_luas) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.headers) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.libs) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.lua_modules) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.lua_cmodules) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.scripts) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.assets) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            for (provs.ballad_plugins) |p| {
                var mut_p = p;
                mut_p.deinit(allocator);
            }
            allocator.free(provs.bins);
            allocator.free(provs.bin_luas);
            allocator.free(provs.headers);
            allocator.free(provs.libs);
            allocator.free(provs.lua_modules);
            allocator.free(provs.lua_cmodules);
            allocator.free(provs.scripts);
            allocator.free(provs.assets);
            allocator.free(provs.ballad_plugins);
        }

        for (provs.bins) |b| {
            const abs_bin_path = try std.fs.path.join(allocator, &.{ art_path, "files", b.path });
            if (policy.expose_public_bins) {
                if (public_bin_map.get(b.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) {
                        const namespaced = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pa.name, b.name });
                        if (public_bin_map.contains(namespaced)) return error.BinConflict;
                        try public_bin_map.put(allocator, namespaced, .{
                            .path = abs_bin_path,
                            .artifact_hash = try allocator.dupe(u8, hash),
                            .role = pa.role,
                        });
                    }
                } else {
                    try public_bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                        .path = abs_bin_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            } else if (policy.expose_tool_scope) {
                if (tool_bin_map.get(b.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) {
                        const namespaced = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pa.name, b.name });
                        if (tool_bin_map.contains(namespaced)) return error.BinConflict;
                        try tool_bin_map.put(allocator, namespaced, .{
                            .path = abs_bin_path,
                            .artifact_hash = try allocator.dupe(u8, hash),
                            .role = pa.role,
                        });
                    }
                } else {
                    try tool_bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                        .path = abs_bin_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            } else if (policy.expose_helper_scope) {
                if (helper_bin_map.get(b.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) {
                        const namespaced = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pa.name, b.name });
                        if (helper_bin_map.contains(namespaced)) return error.BinConflict;
                        try helper_bin_map.put(allocator, namespaced, .{
                            .path = abs_bin_path,
                            .artifact_hash = try allocator.dupe(u8, hash),
                            .role = pa.role,
                        });
                    }
                } else {
                    try helper_bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                        .path = abs_bin_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            }
        }

        for (provs.bin_luas) |b| {
            const abs_bin_path = try std.fs.path.join(allocator, &.{ art_path, "files", b.path });
            if (policy.expose_public_bins) {
                if (public_bin_map.get(b.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) {
                        const namespaced = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pa.name, b.name });
                        if (public_bin_map.contains(namespaced)) return error.BinConflict;
                        try public_bin_map.put(allocator, namespaced, .{
                            .path = abs_bin_path,
                            .artifact_hash = try allocator.dupe(u8, hash),
                            .role = pa.role,
                        });
                    }
                } else {
                    try public_bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                        .path = abs_bin_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            } else if (policy.expose_tool_scope) {
                if (tool_bin_map.get(b.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) {
                        const namespaced = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pa.name, b.name });
                        if (tool_bin_map.contains(namespaced)) return error.BinConflict;
                        try tool_bin_map.put(allocator, namespaced, .{
                            .path = abs_bin_path,
                            .artifact_hash = try allocator.dupe(u8, hash),
                            .role = pa.role,
                        });
                    }
                } else {
                    try tool_bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                        .path = abs_bin_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            } else if (policy.expose_helper_scope) {
                if (helper_bin_map.get(b.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) {
                        const namespaced = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ pa.name, b.name });
                        if (helper_bin_map.contains(namespaced)) return error.BinConflict;
                        try helper_bin_map.put(allocator, namespaced, .{
                            .path = abs_bin_path,
                            .artifact_hash = try allocator.dupe(u8, hash),
                            .role = pa.role,
                        });
                    }
                } else {
                    try helper_bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                        .path = abs_bin_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            }
        }

        for (provs.lua_modules) |m| {
            if (policy.link_lua_modules_to_root) {
                if (lua_map.get(m.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) return error.ModuleConflict;
                } else {
                    const rel_file = if (std.mem.startsWith(u8, m.path, "${build}/"))
                        m.path["${build}/".len..]
                    else
                        m.name;
                    const abs_lua_path = try std.fs.path.join(allocator, &.{ art_path, "files", rel_file });
                    try lua_map.put(allocator, try allocator.dupe(u8, m.name), .{
                        .path = abs_lua_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            }
        }

        for (provs.lua_cmodules) |m| {
            if (policy.link_cmodules_to_root) {
                if (cmod_map.get(m.name)) |existing| {
                    if (!std.mem.eql(u8, existing.artifact_hash, hash)) return error.ModuleConflict;
                } else {
                    const abs_cmod_path = try std.fs.path.join(allocator, &.{ art_path, "files", m.path });
                    try cmod_map.put(allocator, try allocator.dupe(u8, m.name), .{
                        .path = abs_cmod_path,
                        .artifact_hash = try allocator.dupe(u8, hash),
                        .role = pa.role,
                    });
                }
            }
        }

        for (provs.libs) |library| {
            if (!policy.link_cmodules_to_root) continue;
            if (library.linkage == .static) continue;
            const library_file_name = std.fs.path.basename(library.path);
            if (native_lib_map.get(library_file_name)) |existing| {
                if (!std.mem.eql(u8, existing.artifact_hash, hash)) return error.NativeLibraryConflict;
                continue;
            }
            const absolute_library_path = try std.fs.path.join(allocator, &.{ art_path, "files", library.path });
            try native_lib_map.put(allocator, try allocator.dupe(u8, library_file_name), .{
                .path = absolute_library_path,
                .artifact_hash = try allocator.dupe(u8, hash),
                .role = pa.role,
            });
        }
    }

    if (runtime_info == null) {
        runtime_info = try runtimeInfoFromLiveLinks(allocator, io, live_links);
    }
    if (runtime_info == null and live_links.len == 0) return error.MissingRuntime;

    // 3. Create .moonstone/env structure
    project_root.deleteTree(io, env_path) catch |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    };
    project_root.createDirPath(io, env_path) catch |err| {
        return err;
    };
    var env_dir = project_root.openDir(io, env_path, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer env_dir.close(io);

    env_dir.createDirPath(io, "bin") catch |err| {
        return err;
    };
    var bin_dir = env_dir.openDir(io, "bin", .{}) catch |err| {
        return err;
    };
    defer bin_dir.close(io);
    env_dir.createDirPath(io, "libexec") catch |err| {
        return err;
    };
    var libexec_dir = env_dir.openDir(io, "libexec", .{}) catch |err| {
        return err;
    };
    defer libexec_dir.close(io);

    const abi = if (runtime_info) |ri| ri.abi else "lua54";
    var lua_ver_dot: []const u8 = undefined;
    if (std.mem.startsWith(u8, abi, "lua") and abi.len >= 5) {
        if (abi.len == 5) {
            lua_ver_dot = try std.fmt.allocPrint(allocator, "{c}.{c}", .{ abi[3], abi[4] });
        } else if (std.mem.indexOfScalar(u8, abi, '-')) |pos| {
            lua_ver_dot = try allocator.dupe(u8, abi[pos + 1 ..]);
        } else {
            lua_ver_dot = try allocator.dupe(u8, abi[3..]);
        }
    } else lua_ver_dot = try allocator.dupe(u8, abi);
    defer allocator.free(lua_ver_dot);

    // Create lua share dir if we have live links or runtime
    if (live_links.len > 0 or runtime_info != null) {
        const share_lua_path = try std.fs.path.join(allocator, &.{ "share/lua", lua_ver_dot });
        defer allocator.free(share_lua_path);
        try env_dir.createDirPath(io, share_lua_path);
    }

    // 4. Link public binaries from store artifacts
    var bit = public_bin_map.iterator();
    while (bit.next()) |entry| {
        const name = entry.key_ptr.*;
        const provision_path = entry.value_ptr.path;
        var fallback_path: ?[]const u8 = null;
        defer if (fallback_path) |path| allocator.free(path);

        const target_path = blk: {
            std.Io.Dir.cwd().access(io, provision_path, .{}) catch |err| {
                if (err != error.FileNotFound) return err;
                if (std.mem.eql(u8, name, "luac")) continue;
                if (!std.mem.eql(u8, name, "lua")) return err;
                const parent = std.fs.path.dirname(provision_path) orelse return err;
                const luajit_path = try std.fs.path.join(allocator, &.{ parent, "luajit" });
                fallback_path = luajit_path;
                std.Io.Dir.cwd().access(io, luajit_path, .{}) catch |fallback_err| {
                    return fallback_err;
                };
                break :blk luajit_path;
            };
            break :blk provision_path;
        };

        var projected_name: ?[]const u8 = null;
        defer if (projected_name) |value| allocator.free(value);
        if (windowsExecutableProjectionExtension(name, target_path, comptime builtin.os.tag == .windows)) |extension| {
            projected_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, extension });
        }
        try projectExecutable(io, bin_dir, target_path, projected_name orelse name, comptime builtin.os.tag == .windows);

        // If this public binary comes from a package with an isolated runtime
        // that differs from the project runtime, create a bin-runtime scope so
        // `moon exec` can prepend the correct runtime bin directory.
        const scoped_runtime_bin_path = try resolveScopedRuntimeBinPath(allocator, io, index, entry.value_ptr.artifact_hash);
        defer if (scoped_runtime_bin_path) |p| allocator.free(p);
        const needs_isolated_scope = if (scoped_runtime_bin_path) |srp| blk: {
            if (project_runtime_bin_path) |prp| {
                break :blk !std.mem.eql(u8, prp, srp);
            }
            break :blk true;
        } else false;
        if (needs_isolated_scope) {
            try writeRuntimeScope(allocator, io, env_dir, index, "bin-runtime", name, target_path, entry.value_ptr.artifact_hash, true, scoped_runtime_bin_path, projected_artifacts);
        }
    }

    // 4a. Create tool scope directories
    var tit = tool_bin_map.iterator();
    while (tit.next()) |entry| {
        const bin_name = entry.key_ptr.*;
        const bin_info = entry.value_ptr.*;
        try writeRuntimeScope(allocator, io, env_dir, index, "bin-runtime", bin_name, bin_info.path, bin_info.artifact_hash, true, null, projected_artifacts);
    }

    // 4a-bis. Create helper scope directories
    var hit = helper_bin_map.iterator();
    while (hit.next()) |entry| {
        const bin_name = entry.key_ptr.*;
        const bin_info = entry.value_ptr.*;
        try writeRuntimeScope(allocator, io, env_dir, index, "bin-helper", bin_name, bin_info.path, bin_info.artifact_hash, true, null, projected_artifacts);
    }

    // 4b. Link C modules from store artifacts
    var cit = cmod_map.iterator();
    while (cit.next()) |entry| {
        const mod_name = entry.key_ptr.*;
        const target_path = entry.value_ptr.path;

        const search_str = try std.fmt.allocPrint(allocator, "lib/lua/{s}/", .{lua_ver_dot});
        defer allocator.free(search_str);

        const final_dest_rel = if (std.mem.indexOf(u8, target_path, search_str) != null) blk: {
            const pos = std.mem.indexOf(u8, target_path, search_str).?;
            break :blk target_path[pos..];
        } else blk: {
            const cmodule_extension = luaCmoduleExtension();
            const clean_name = luaCmoduleLogicalName(mod_name);
            const slash_name = try std.mem.replaceOwned(u8, allocator, clean_name, ".", "/");
            defer allocator.free(slash_name);
            break :blk try std.fmt.allocPrint(allocator, "lib/lua/{s}/{s}{s}", .{ lua_ver_dot, slash_name, cmodule_extension });
        };
        const is_owned = std.mem.indexOf(u8, target_path, search_str) == null;
        defer if (is_owned) allocator.free(final_dest_rel);

        const dest_dir_rel = std.fs.path.dirname(final_dest_rel).?;
        const dest_name = std.fs.path.basename(final_dest_rel);
        env_dir.createDirPath(io, dest_dir_rel) catch |err| {
            return err;
        };
        var dest_dir = env_dir.openDir(io, dest_dir_rel, .{}) catch |err| {
            return err;
        };
        defer dest_dir.close(io);

        try projectFile(io, dest_dir, target_path, dest_name);
    }

    // 4b-bis. Link runtime native libraries for the host dynamic loader.
    if (native_lib_map.count() > 0) {
        try env_dir.createDirPath(io, "lib/native");
        var native_lib_dir = try env_dir.openDir(io, "lib/native", .{});
        defer native_lib_dir.close(io);
        var native_iterator = native_lib_map.iterator();
        while (native_iterator.next()) |entry| {
            const destination_name = entry.key_ptr.*;
            if (std.fs.path.dirname(destination_name)) |parent| try native_lib_dir.createDirPath(io, parent);
            if (std.fs.path.dirname(destination_name)) |parent| {
                var destination_dir = try native_lib_dir.openDir(io, parent, .{});
                defer destination_dir.close(io);
                try projectFile(io, destination_dir, entry.value_ptr.path, std.fs.path.basename(destination_name));
            } else {
                try projectFile(io, native_lib_dir, entry.value_ptr.path, destination_name);
            }
        }
    }

    // 4c. Link Lua modules from store artifacts
    var lit = lua_map.iterator();
    while (lit.next()) |entry| {
        const mod_name = entry.key_ptr.*;
        const target_path = entry.value_ptr.path;

        const is_dir = blk: {
            const target_dir_path = std.fs.path.dirname(target_path).?;
            var target_dir = std.Io.Dir.openDirAbsolute(io, target_dir_path, .{}) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
            defer target_dir.close(io);
            const stat = target_dir.statFile(io, std.fs.path.basename(target_path), .{}) catch |err| {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
            break :blk stat.kind == .directory;
        };

        if (is_dir == null) continue;

        const search_str = try std.fmt.allocPrint(allocator, "share/lua/{s}/", .{lua_ver_dot});
        defer allocator.free(search_str);

        const final_dest_rel = if (std.mem.indexOf(u8, target_path, search_str) != null) blk: {
            const pos = std.mem.indexOf(u8, target_path, search_str).?;
            break :blk target_path[pos..];
        } else blk: {
            if (std.mem.indexOfScalar(u8, mod_name, '/') != null) {
                break :blk try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, mod_name });
            } else {
                const ext = if (std.mem.endsWith(u8, mod_name, ".lua")) @as(usize, 4) else @as(usize, 0);
                const clean_name = mod_name[0 .. mod_name.len - ext];
                const slash_name = try std.mem.replaceOwned(u8, allocator, clean_name, ".", "/");
                defer allocator.free(slash_name);
                if (is_dir.?) {
                    break :blk try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, slash_name });
                } else {
                    break :blk try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}.lua", .{ lua_ver_dot, slash_name });
                }
            }
        };
        const is_owned = std.mem.indexOf(u8, target_path, search_str) == null;
        defer if (is_owned) allocator.free(final_dest_rel);

        const dest_dir_rel = std.fs.path.dirname(final_dest_rel).?;
        const dest_name = std.fs.path.basename(final_dest_rel);
        env_dir.createDirPath(io, dest_dir_rel) catch |err| {
            return err;
        };
        var dest_dir = env_dir.openDir(io, dest_dir_rel, .{}) catch |err| {
            return err;
        };
        defer dest_dir.close(io);

        try projectFile(io, dest_dir, target_path, dest_name);
    }

    // 5. Link live dependencies
    for (live_links) |ll| {
        const policy = ll.role.getProjectionPolicy();
        if (ll.pkg_kind == .bin) {
            // For binary packages, link binaries from source project's bin/ or specified path
            const src_bin_path = try std.fs.path.join(allocator, &.{ ll.source_path, "bin" });
            defer allocator.free(src_bin_path);

            var src_bin_dir = std.Io.Dir.openDirAbsolute(io, src_bin_path, .{ .iterate = true }) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            defer src_bin_dir.close(io);

            var it = src_bin_dir.iterate();
            while (try it.next(io)) |sub_entry| {
                if (sub_entry.kind != .file) continue;
                const src_file = try std.fs.path.join(allocator, &.{ src_bin_path, sub_entry.name });
                defer allocator.free(src_file);
                try projectFile(io, bin_dir, src_file, sub_entry.name);
                if (policy.expose_tool_scope) {
                    try writeLiveLinkScope(allocator, io, env_dir, index, "bin-runtime", sub_entry.name, ll.source_path, lua_ver_dot, project_runtime_bin_path);
                } else if (policy.expose_helper_scope) {
                    try writeLiveLinkScope(allocator, io, env_dir, index, "bin-helper", sub_entry.name, ll.source_path, lua_ver_dot, project_runtime_bin_path);
                }
            }
        } else if (ll.pkg_kind == .lib or ll.pkg_kind == .script) {
            if (ll.pkg_kind == .script and (ll.role == .dev or ll.role == .tool or ll.role == .helper)) {
                const bin_name = packageLocalName(ll.pkg_name);
                if (try liveLinkScriptCommand(allocator, io, ll.source_path)) |script_command| {
                    defer allocator.free(script_command);
                    try writeLiveLinkScriptShim(allocator, io, bin_dir, bin_name, ll.source_path, script_command);
                    if (policy.expose_tool_scope) {
                        try writeLiveLinkScope(allocator, io, env_dir, index, "bin-runtime", bin_name, ll.source_path, lua_ver_dot, project_runtime_bin_path);
                    } else if (policy.expose_helper_scope) {
                        try writeLiveLinkScope(allocator, io, env_dir, index, "bin-helper", bin_name, ll.source_path, lua_ver_dot, project_runtime_bin_path);
                    }
                }
            }

            // For library packages, link lua modules from source project's src/
            const local_name = packageLocalName(ll.pkg_name);
            const module_name_hyphen = try allocator.dupe(u8, local_name);
            defer allocator.free(module_name_hyphen);
            const module_name_underscore = try allocator.dupe(u8, local_name);
            defer allocator.free(module_name_underscore);
            for (module_name_underscore) |*c| {
                if (c.* == '-') c.* = '_';
            }

            const names = [_][]const u8{ module_name_hyphen, module_name_underscore };
            const names_slice = if (std.mem.eql(u8, module_name_hyphen, module_name_underscore)) names[0..1] else names[0..2];

            for (names_slice) |name| {
                const module_dir_name = try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, name });
                defer allocator.free(module_dir_name);

                const module_lua_name = try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}.lua", .{ lua_ver_dot, name });
                defer allocator.free(module_lua_name);

                const module_subdir_path = try std.fs.path.join(allocator, &.{ ll.source_path, "src", name });
                defer allocator.free(module_subdir_path);

                const module_single_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.lua", .{ ll.source_path, name });
                defer allocator.free(module_single_path);

                // 1. Preferred layout: <source>/src/<module>/...  (directory of files)
                if (std.Io.Dir.cwd().access(io, module_subdir_path, .{})) |_| {
                    env_dir.createDirPath(io, module_dir_name) catch |err| {
                        return err;
                    };
                    var ddir = env_dir.openDir(io, module_dir_name, .{}) catch |err| {
                        return err;
                    };
                    defer ddir.close(io);
                    try projectTree(allocator, io, ddir, module_subdir_path);
                } else |err| {
                    if (err != error.FileNotFound) return err;
                }

                // 2. Single-file layout: <source>/src/<module>.lua  (e.g. "moon init --template lib" output)
                // Link the entry point even when a subdirectory also exists (e.g. ballad.lua + ballad/)
                if (std.Io.Dir.cwd().access(io, module_single_path, .{})) |_| {
                    const share_lua_dir = std.fs.path.dirname(module_lua_name) orelse "share/lua";
                    env_dir.createDirPath(io, share_lua_dir) catch |create_err| {
                        return create_err;
                    };
                    try projectFile(io, env_dir, module_single_path, module_lua_name);
                } else |err| {
                    if (err != error.FileNotFound) return err;
                }
            }
        }
    }

    // 5b. Link non-metadata live dependencies into libexec/ for stable references.
    for (live_links) |ll| {
        const ll_policy = ll.role.getProjectionPolicy();
        if (ll_policy.metadata_only) continue;
        const ll_local = packageLocalName(ll.pkg_name);
        try linkPackageIntoLibexec(allocator, io, libexec_dir, ll_local, ll.source_path);
    }

    // 6. Fallback linking for artifacts without successful module metadata linking
    for (projected_artifacts) |pa| {
        const hash = pa.artifact_hash;
        const policy = pa.role.getProjectionPolicy();

        if (policy.metadata_only) continue;

        const art_path = try index.get_artifact_path(hash) orelse continue;
        defer allocator.free(art_path);

        const share_lua_files_path = try std.fs.path.join(allocator, &.{ art_path, "files", "share", "lua", lua_ver_dot });
        defer allocator.free(share_lua_files_path);
        if (std.Io.Dir.openDirAbsolute(io, share_lua_files_path, .{ .iterate = true })) |share_lua_dir| {
            defer share_lua_dir.close(io);
            var it = share_lua_dir.iterate();
            while (try it.next(io)) |sub_entry| {
                const mod_dest = try std.fs.path.join(allocator, &.{ "share/lua", lua_ver_dot, sub_entry.name });
                defer allocator.free(mod_dest);
                const full_dest = try std.fs.path.join(allocator, &.{ env_path, mod_dest });
                defer allocator.free(full_dest);

                if (std.Io.Dir.cwd().access(io, full_dest, .{})) |_| {
                    continue;
                } else |_| {
                    const mod_src = try std.fs.path.join(allocator, &.{ share_lua_files_path, sub_entry.name });
                    defer allocator.free(mod_src);
                    if (sub_entry.kind == .directory) {
                        try env_dir.createDirPath(io, mod_dest);
                        var ddir = try env_dir.openDir(io, mod_dest, .{});
                        defer ddir.close(io);
                        try projectTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file) {
                        try projectFile(io, env_dir, mod_src, mod_dest);
                    }
                }
            }
            continue;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        // Try files/lua/ first
        const lua_files_path = try std.fs.path.join(allocator, &.{ art_path, "files", "lua" });
        defer allocator.free(lua_files_path);

        var lua_dir: ?std.Io.Dir = null;
        if (std.Io.Dir.openDirAbsolute(io, lua_files_path, .{ .iterate = true })) |dir| {
            lua_dir = dir;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        if (lua_dir) |d| {
            defer d.close(io);
            var it = d.iterate();
            while (try it.next(io)) |sub_entry| {
                const mod_dest = try std.fs.path.join(allocator, &.{ "share/lua", lua_ver_dot, sub_entry.name });
                defer allocator.free(mod_dest);
                const full_dest = try std.fs.path.join(allocator, &.{ env_path, mod_dest });
                defer allocator.free(full_dest);

                if (std.Io.Dir.cwd().access(io, full_dest, .{})) |_| {
                    continue; // Already linked
                } else |_| {
                    const mod_src = try std.fs.path.join(allocator, &.{ lua_files_path, sub_entry.name });
                    defer allocator.free(mod_src);
                    if (sub_entry.kind == .directory) {
                        try env_dir.createDirPath(io, mod_dest);
                        var ddir = try env_dir.openDir(io, mod_dest, .{});
                        defer ddir.close(io);
                        try projectTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".lua")) {
                        try projectFile(io, env_dir, mod_src, mod_dest);
                    }
                }
            }
            continue;
        }

        // Fallback 1: files/src/
        const src_files_path = try std.fs.path.join(allocator, &.{ art_path, "files", "src" });
        defer allocator.free(src_files_path);
        if (std.Io.Dir.openDirAbsolute(io, src_files_path, .{ .iterate = true })) |src_dir| {
            defer src_dir.close(io);
            var it = src_dir.iterate();
            while (try it.next(io)) |sub_entry| {
                if (sub_entry.kind != .directory) continue;
                const mod_src = try std.fs.path.join(allocator, &.{ src_files_path, sub_entry.name });
                defer allocator.free(mod_src);
                const mod_dest = try std.fs.path.join(allocator, &.{ "share/lua", lua_ver_dot, sub_entry.name });
                defer allocator.free(mod_dest);

                const full_dest = try std.fs.path.join(allocator, &.{ env_path, mod_dest });
                defer allocator.free(full_dest);

                if (std.Io.Dir.cwd().access(io, full_dest, .{})) |_| {
                    continue; // Already linked
                } else |_| {
                    try env_dir.createDirPath(io, mod_dest);
                    var ddir = try env_dir.openDir(io, mod_dest, .{});
                    defer ddir.close(io);
                    try projectTree(allocator, io, ddir, mod_src);
                }
            }
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        // Fallback 2: files/libexec/<local_name>/src/
        const local_name = packageLocalName(pa.name);
        const libexec_src_path = try std.fs.path.join(allocator, &.{ art_path, "files", "libexec", local_name, "src" });
        defer allocator.free(libexec_src_path);
        if (std.Io.Dir.openDirAbsolute(io, libexec_src_path, .{ .iterate = true })) |libexec_src_dir| {
            defer libexec_src_dir.close(io);
            var libexec_it = libexec_src_dir.iterate();
            while (try libexec_it.next(io)) |sub_entry| {
                const mod_src = try std.fs.path.join(allocator, &.{ libexec_src_path, sub_entry.name });
                defer allocator.free(mod_src);
                const mod_dest = try std.fs.path.join(allocator, &.{ "share/lua", lua_ver_dot, sub_entry.name });
                defer allocator.free(mod_dest);

                const full_dest = try std.fs.path.join(allocator, &.{ env_path, mod_dest });
                defer allocator.free(full_dest);

                if (std.Io.Dir.cwd().access(io, full_dest, .{})) |_| {
                    continue;
                } else |_| {
                    if (sub_entry.kind == .directory) {
                        try env_dir.createDirPath(io, mod_dest);
                        var ddir = try env_dir.openDir(io, mod_dest, .{});
                        defer ddir.close(io);
                        try projectTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".lua")) {
                        try projectFile(io, env_dir, mod_src, mod_dest);
                    }
                }
            }
            continue;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        // Fallback 3: files/libexec/<local_name>/lua/
        const libexec_lua_path = try std.fs.path.join(allocator, &.{ art_path, "files", "libexec", local_name, "lua" });
        defer allocator.free(libexec_lua_path);
        if (std.Io.Dir.openDirAbsolute(io, libexec_lua_path, .{ .iterate = true })) |libexec_lua_dir| {
            defer libexec_lua_dir.close(io);
            var libexec_it = libexec_lua_dir.iterate();
            while (try libexec_it.next(io)) |sub_entry| {
                const mod_src = try std.fs.path.join(allocator, &.{ libexec_lua_path, sub_entry.name });
                defer allocator.free(mod_src);
                const mod_dest = try std.fs.path.join(allocator, &.{ "share/lua", lua_ver_dot, sub_entry.name });
                defer allocator.free(mod_dest);

                const full_dest = try std.fs.path.join(allocator, &.{ env_path, mod_dest });
                defer allocator.free(full_dest);

                if (std.Io.Dir.cwd().access(io, full_dest, .{})) |_| {
                    continue;
                } else |_| {
                    if (sub_entry.kind == .directory) {
                        try env_dir.createDirPath(io, mod_dest);
                        var ddir = try env_dir.openDir(io, mod_dest, .{});
                        defer ddir.close(io);
                        try projectTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".lua")) {
                        try projectFile(io, env_dir, mod_src, mod_dest);
                    }
                }
            }
        } else |err| {
            if (err != error.FileNotFound) return err;
        }
    }

    // 6b. Link non-metadata store artifacts into libexec/ for stable references.
    for (projected_artifacts) |pa2| {
        const pa_policy = pa2.role.getProjectionPolicy();
        if (pa_policy.metadata_only) continue;
        const pa_path = try index.get_artifact_path(pa2.artifact_hash) orelse continue;
        defer allocator.free(pa_path);
        const pa_local = packageLocalName(pa2.name);
        try linkPackageIntoLibexec(allocator, io, libexec_dir, pa_local, pa_path);
    }

    // 7. Generate env.toml
    const env_toml_file = try env_dir.createFile(io, "env.toml", .{});
    defer env_toml_file.close(io);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try aw.writer.print("[runtime]\n", .{});
    if (runtime_info) |rt| {
        try aw.writer.print("name = \"{s}\"\n", .{rt.name});
        try aw.writer.print("version = \"{s}\"\n", .{rt.version});
        try aw.writer.print("abi = \"{s}\"\n", .{rt.abi});
    } else {
        try aw.writer.print("name = \"unknown\"\n", .{});
        try aw.writer.print("version = \"unknown\"\n", .{});
        try aw.writer.print("abi = \"unknown\"\n", .{});
    }

    try aw.writer.flush();
    try env_toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

    // 7b. Generate dependencies.toml
    const deps_toml_file = try env_dir.createFile(io, "dependencies.toml", .{});
    defer deps_toml_file.close(io);

    var deps_aw = std.Io.Writer.Allocating.init(allocator);
    defer deps_aw.deinit();
    for (projected_artifacts) |pa| {
        try deps_aw.writer.print("[[dependencies]]\n", .{});
        try deps_aw.writer.print("name = ", .{});
        try writeTomlString(&deps_aw.writer, pa.name);
        try deps_aw.writer.print("\nversion = ", .{});
        try writeTomlString(&deps_aw.writer, pa.version);
        try deps_aw.writer.print("\nrole = ", .{});
        try writeTomlString(&deps_aw.writer, @tagName(pa.role));
        if (pa.constraint.len > 0) {
            try deps_aw.writer.print("\nconstraint = ", .{});
            try writeTomlString(&deps_aw.writer, pa.constraint);
        }
        if (pa.resolver) |r| {
            try deps_aw.writer.print("\nresolver = ", .{});
            try writeTomlString(&deps_aw.writer, r);
        }
        try deps_aw.writer.print("\nartifact_hash = ", .{});
        try writeTomlString(&deps_aw.writer, pa.artifact_hash);
        if (pa.lua_abi) |l_abi| {
            try deps_aw.writer.print("\nlua_abi = ", .{});
            try writeTomlString(&deps_aw.writer, l_abi);
        }
        if (pa.lua_api) |api| {
            try deps_aw.writer.print("\nlua_api = ", .{});
            try writeTomlString(&deps_aw.writer, api);
        }
        if (pa.target) |t| {
            try deps_aw.writer.print("\ntarget = ", .{});
            try writeTomlString(&deps_aw.writer, t);
        }
        if (pa.path) |p| {
            try deps_aw.writer.print("\npath = ", .{});
            try writeTomlString(&deps_aw.writer, p);
        }
        try deps_aw.writer.print("\n", .{});
    }
    for (live_links) |ll| {
        try deps_aw.writer.print("[[dependencies]]\n", .{});
        try deps_aw.writer.print("name = ", .{});
        try writeTomlString(&deps_aw.writer, ll.pkg_name);
        try deps_aw.writer.print("\nversion = ", .{});
        try writeTomlString(&deps_aw.writer, ll.pkg_version);
        try deps_aw.writer.print("\nrole = ", .{});
        try writeTomlString(&deps_aw.writer, @tagName(ll.role));
        try deps_aw.writer.print("\nresolver = ", .{});
        try writeTomlString(&deps_aw.writer, ll.mode);
        try deps_aw.writer.print("\nartifact_hash = ", .{});
        try writeTomlString(&deps_aw.writer, ll.mode);
        try deps_aw.writer.print("\npath = ", .{});
        try writeTomlString(&deps_aw.writer, ll.source_path);
        try deps_aw.writer.print("\n", .{});
    }
    try deps_aw.writer.flush();
    try deps_toml_file.writeStreamingAll(io, deps_aw.writer.buffer[0..deps_aw.writer.end]);

    refreshLspConfig(allocator, io, project_root, lua_ver_dot);
}

fn refreshLspConfig(allocator: std.mem.Allocator, io: std.Io, project_root: std.Io.Dir, lua_ver_dot: []const u8) void {
    const content = project_root.readFileAlloc(io, ".luarc.json", allocator, std.Io.Limit.limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    var updated = allocator.dupe(u8, content) catch return;
    defer allocator.free(updated);
    var changed = false;

    const legacy_path = ".moonstone/env/lua/";
    if (std.mem.indexOf(u8, updated, legacy_path) != null) {
        const migrated = std.mem.replaceOwned(u8, allocator, updated, legacy_path, ".moonstone/env/share/lua/") catch return;
        allocator.free(updated);
        updated = migrated;
        changed = true;
    }

    const libexec_ignore_entry = "\".moonstone/env/libexec\"";
    if (std.mem.indexOf(u8, updated, libexec_ignore_entry) == null) {
        const include_ignore_entry = "\".moonstone/env/include\",";
        if (std.mem.indexOf(u8, updated, include_ignore_entry) != null) {
            const with_libexec_ignored = std.mem.replaceOwned(
                u8,
                allocator,
                updated,
                include_ignore_entry,
                "\".moonstone/env/include\",\n      \".moonstone/env/libexec\",",
            ) catch return;
            allocator.free(updated);
            updated = with_libexec_ignored;
            changed = true;
        }
    }

    const managed_path_prefix = ".moonstone/env/share/lua/";
    const known_lua_versions = [_][]const u8{ "5.1", "5.2", "5.3", "5.4", "5.5" };
    for (known_lua_versions) |known_version| {
        if (std.mem.eql(u8, known_version, lua_ver_dot)) continue;

        const old_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ managed_path_prefix, known_version }) catch return;
        defer allocator.free(old_path);
        if (std.mem.indexOf(u8, updated, old_path) == null) continue;

        const new_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ managed_path_prefix, lua_ver_dot }) catch return;
        defer allocator.free(new_path);
        const migrated = std.mem.replaceOwned(u8, allocator, updated, old_path, new_path) catch return;
        allocator.free(updated);
        updated = migrated;
        changed = true;
    }

    if (changed) {
        const file = project_root.createFile(io, ".luarc.json", .{}) catch return;
        defer file.close(io);
        file.writeStreamingAll(io, updated) catch return;
        return;
    }

    const file = project_root.openFile(io, ".luarc.json", .{ .mode = .read_write }) catch return;
    defer file.close(io);
    file.setTimestampsNow(io) catch {};
}

fn linkPackageIntoLibexec(
    allocator: std.mem.Allocator,
    io: std.Io,
    libexec_dir: std.Io.Dir,
    local_name: []const u8,
    src_path: []const u8,
) !void {
    try projectDirectory(allocator, io, libexec_dir, src_path, local_name);
}

test "link_project_env basic" {
    // This is an integration test that requires filesystem setup.
    // We verify the struct compiles correctly.
    _ = LiveLink{ .name = "test", .source_path = "/tmp", .mode = "live", .pkg_name = "test", .pkg_version = "0.1.0", .pkg_kind = .lib };
}

test "Windows binary projection retains the executable suffix" {
    try std.testing.expect(needsWindowsExeProjection("lua", "C:\\store\\files\\bin\\lua.exe", true));
    try std.testing.expect(!needsWindowsExeProjection("lua.exe", "C:\\store\\files\\bin\\lua.exe", true));
    try std.testing.expect(!needsWindowsExeProjection("lua", "/store/files/bin/lua", true));
    try std.testing.expect(!needsWindowsExeProjection("lua", "C:\\store\\files\\bin\\lua.exe", false));
    try std.testing.expectEqualStrings(".cmd", windowsExecutableProjectionExtension("tool", "C:\\store\\files\\bin\\tool.cmd", true).?);
    try std.testing.expectEqualStrings(".bat", windowsExecutableProjectionExtension("tool", "C:\\store\\files\\bin\\tool.bat", true).?);
}

test "Windows executable projection retains sibling DLLs for linked launchers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "source");
    try tmp.dir.createDir(io, "destination");

    var source = try tmp.dir.openDir(io, "source", .{});
    defer source.close(io);
    const launcher = try source.createFile(io, "lua.exe", .{});
    launcher.close(io);
    const sibling = try source.createFile(io, "lua54.DLL", .{});
    defer sibling.close(io);
    try sibling.writeStreamingAll(io, "runtime dependency");
    const unrelated = try source.createFile(io, "README.txt", .{});
    unrelated.close(io);

    const source_root = try tmp.dir.realPathAlloc(io, std.testing.allocator, "source");
    defer std.testing.allocator.free(source_root);
    const launcher_path = try std.fs.path.join(std.testing.allocator, &.{ source_root, "lua.exe" });
    defer std.testing.allocator.free(launcher_path);
    var destination = try tmp.dir.openDir(io, "destination", .{});
    defer destination.close(io);

    try projectExecutable(io, destination, launcher_path, "lua.exe", true);
    try destination.access(io, "lua.exe", .{});
    try destination.access(io, "lua54.DLL", .{});
    try std.testing.expectError(error.FileNotFound, destination.access(io, "README.txt", .{}));

    const stale = try destination.createFile(io, "lua54.DLL", .{});
    try stale.writeStreamingAll(io, "stale projection");
    stale.close(io);
    try copySiblingDllsForWindows(io, destination, launcher_path, true);
    const projected = try destination.readFileAlloc(io, "lua54.DLL", std.testing.allocator, 4096);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqualStrings("runtime dependency", projected);
}

test "live-link shim uses the target launcher without hardcoded Lua versions" {
    const allocator = std.testing.allocator;
    const io = std.Io.default;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeLiveLinkScriptShim(allocator, io, tmp.dir, "dummy_bin", "/fake/source", "lua src/main.lua");

    const shim_name = if (comptime builtin.os.tag == .windows) "dummy_bin.cmd" else "dummy_bin";
    const content = try tmp.dir.readFileAlloc(io, shim_name, allocator, 4096);
    defer allocator.free(content);

    if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, content, "@echo off") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "?.dll") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, content, "for d in \"$TOOL_ROOT/.moonstone/env/share/lua/\"*; do") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "share/lua/5.1/") == null);
        try std.testing.expect(std.mem.indexOf(u8, content, "share/lua/5.4/") == null);
    }
}

test "scope module roots preserve dotted Lua module paths" {
    const allocator = std.testing.allocator;

    const lua_root = (try provisionModuleRoot(allocator, .{
        .name = "compiler.frontend.parse",
        .path = "share/lua/5.4/compiler/frontend/parse.lua",
    })).?;
    defer allocator.free(lua_root);
    try std.testing.expectEqualStrings("share/lua/5.4", lua_root);

    const c_root = (try provisionModuleRoot(allocator, .{
        .name = "platform.core",
        .path = "lib/lua/5.4/platform/core.so",
    })).?;
    defer allocator.free(c_root);
    try std.testing.expectEqualStrings("lib/lua/5.4", c_root);
}

test "scope closures permit pure Lua dependencies across ABI boundaries" {
    try std.testing.expect(scopeArtifactAbiCompatible("lua51", "lua54", false));
    try std.testing.expect(!scopeArtifactAbiCompatible("lua51", "lua54", true));
    try std.testing.expect(scopeArtifactAbiCompatible("lua54", "lua54", true));
}
fn luaCmoduleExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

fn luaCmoduleLogicalName(name: []const u8) []const u8 {
    const known_extensions = [_][]const u8{ ".dylib", ".dll", ".so" };
    for (known_extensions) |extension| {
        if (std.mem.endsWith(u8, name, extension)) return name[0 .. name.len - extension.len];
    }
    return name;
}

fn luaCmoduleExtensions() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{".dll"},
        .macos => &.{ ".dylib", ".so" },
        else => &.{".so"},
    };
}

test "native module projection ignores source-library suffixes" {
    try std.testing.expectEqualStrings("synthetic_make_module", luaCmoduleLogicalName("synthetic_make_module.so"));
    try std.testing.expectEqualStrings("platform.core", luaCmoduleLogicalName("platform.core.dylib"));
    try std.testing.expectEqualStrings("platform.core", luaCmoduleLogicalName("platform.core.dll"));
}
