const std = @import("std");
const UNIQUE_BUILD_MARKER = "UNIQUE_BUILD_MARKER_20250608_1847";
const manifest = @import("../domain/manifest.zig");
const package_spec = @import("../domain/package_spec.zig");
const driver_mod = @import("../store/driver.zig");
const semver = @import("../domain/semver.zig");

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

    try writeScopedPathPrepend(&aw.writer, bin_dir_path, scoped_runtime_bin_path);

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

fn writeScopedPathPrepend(
    writer: *std.Io.Writer,
    tool_bin_dir: []const u8,
    runtime_bin_dir: ?[]const u8,
) !void {
    try writer.print("path_prepend = [", .{});
    if (runtime_bin_dir) |runtime_path| {
        try writer.print("\"{s}\", ", .{runtime_path});
    }
    try writer.print("\"{s}\"]\n", .{tool_bin_dir});
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

    try writeScopedPathPrepend(&scope_aw.writer, bin_dir_path, effective_runtime_bin_path);

    if (include_module_paths) {
        const art_path = try index.get_artifact_path(artifact_hash) orelse return;
        defer allocator.free(art_path);

        const provs = try index.get_provisions(artifact_hash);
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
            allocator.free(provs.bins);
            allocator.free(provs.bin_luas);
            allocator.free(provs.headers);
            allocator.free(provs.libs);
            allocator.free(provs.lua_modules);
            allocator.free(provs.lua_cmodules);
        }

        if (provs.lua_modules.len > 0) {
            try scope_aw.writer.print("lua_path = [", .{});
            var first = true;
            for (provs.lua_modules) |m| {
                const mod_dir = std.fs.path.dirname(m.path) orelse continue;
                const abs_mod_dir = try std.fs.path.join(allocator, &.{ art_path, "files", mod_dir });
                defer allocator.free(abs_mod_dir);
                const lua_file_pattern = try std.fs.path.join(allocator, &.{ abs_mod_dir, "?.lua" });
                defer allocator.free(lua_file_pattern);
                const lua_init_pattern = try std.fs.path.join(allocator, &.{ abs_mod_dir, "?", "init.lua" });
                defer allocator.free(lua_init_pattern);
                if (!first) try scope_aw.writer.print(", ", .{});
                try scope_aw.writer.print("\"{s}\", \"{s}\"", .{ lua_file_pattern, lua_init_pattern });
                first = false;
            }
            try scope_aw.writer.print("]\n", .{});
        }
        if (provs.lua_cmodules.len > 0) {
            try scope_aw.writer.print("lua_cpath = [", .{});
            var first = true;
            for (provs.lua_cmodules) |m| {
                const mod_dir = std.fs.path.dirname(m.path) orelse continue;
                const abs_mod_dir = try std.fs.path.join(allocator, &.{ art_path, "files", mod_dir });
                defer allocator.free(abs_mod_dir);
                const cmod_so_pattern = try std.fs.path.join(allocator, &.{ abs_mod_dir, "?.so" });
                defer allocator.free(cmod_so_pattern);
                const cmod_dylib_pattern = try std.fs.path.join(allocator, &.{ abs_mod_dir, "?.dylib" });
                defer allocator.free(cmod_dylib_pattern);
                if (!first) try scope_aw.writer.print(", ", .{});
                try scope_aw.writer.print("\"{s}\", \"{s}\"", .{ cmod_so_pattern, cmod_dylib_pattern });
                first = false;
            }
            try scope_aw.writer.print("]\n", .{});
        }
    }

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
    const shim = try std.fmt.allocPrint(allocator,
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

    bin_dir.deleteFile(io, bin_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    const file = try bin_dir.createFile(io, bin_name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, shim);
    try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
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
            allocator.free(provs.bins);
            allocator.free(provs.bin_luas);
            allocator.free(provs.headers);
            allocator.free(provs.libs);
            allocator.free(provs.lua_modules);
            allocator.free(provs.lua_cmodules);
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
                    const abs_lua_path = try std.fs.path.join(allocator, &.{ art_path, "files", m.path });
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

        bin_dir.symLink(io, target_path, name, .{}) catch |err| {
            if (err == error.PathAlreadyExists) {
                try bin_dir.deleteFile(io, name);
                try bin_dir.symLink(io, target_path, name, .{});
            } else {
                return err;
            }
        };

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
            try writeRuntimeScope(allocator, io, env_dir, index, "bin-runtime", name, target_path, entry.value_ptr.artifact_hash, false, scoped_runtime_bin_path);
        }
    }

    // 4a. Create tool scope directories
    var tit = tool_bin_map.iterator();
    while (tit.next()) |entry| {
        const bin_name = entry.key_ptr.*;
        const bin_info = entry.value_ptr.*;
        try writeRuntimeScope(allocator, io, env_dir, index, "bin-runtime", bin_name, bin_info.path, bin_info.artifact_hash, true, null);
    }

    // 4a-bis. Create helper scope directories
    var hit = helper_bin_map.iterator();
    while (hit.next()) |entry| {
        const bin_name = entry.key_ptr.*;
        const bin_info = entry.value_ptr.*;
        try writeRuntimeScope(allocator, io, env_dir, index, "bin-helper", bin_name, bin_info.path, bin_info.artifact_hash, false, null);
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
            const ext = if (std.mem.endsWith(u8, mod_name, ".so")) @as(usize, 3) else @as(usize, 0);
            const clean_name = mod_name[0 .. mod_name.len - ext];
            const slash_name = try std.mem.replaceOwned(u8, allocator, clean_name, ".", "/");
            defer allocator.free(slash_name);
            break :blk try std.fmt.allocPrint(allocator, "lib/lua/{s}/{s}.so", .{ lua_ver_dot, slash_name });
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

        dest_dir.symLink(io, target_path, dest_name, .{}) catch |err| {
            if (err == error.PathAlreadyExists) {
                try dest_dir.deleteFile(io, dest_name);
                try dest_dir.symLink(io, target_path, dest_name, .{});
            } else {
                return err;
            }
        };
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
            const ext = if (std.mem.endsWith(u8, mod_name, ".lua")) @as(usize, 4) else @as(usize, 0);
            const clean_name = mod_name[0 .. mod_name.len - ext];
            const slash_name = try std.mem.replaceOwned(u8, allocator, clean_name, ".", "/");
            defer allocator.free(slash_name);
            if (is_dir.?) {
                break :blk try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, slash_name });
            } else {
                break :blk try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}.lua", .{ lua_ver_dot, slash_name });
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

        dest_dir.symLink(io, target_path, dest_name, .{}) catch |err| {
            if (err == error.PathAlreadyExists) {
                try dest_dir.deleteFile(io, dest_name);
                try dest_dir.symLink(io, target_path, dest_name, .{});
            } else {
                return err;
            }
        };
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
                bin_dir.symLink(io, src_file, sub_entry.name, .{}) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        try bin_dir.deleteFile(io, sub_entry.name);
                        try bin_dir.symLink(io, src_file, sub_entry.name, .{});
                    } else {
                        return err;
                    }
                };
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
                    try symlinkTree(allocator, io, ddir, module_subdir_path);
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
                    env_dir.symLink(io, module_single_path, module_lua_name, .{}) catch |link_err| {
                        if (link_err != error.PathAlreadyExists) return link_err;
                    };
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
        try linkPackageIntoLibexec(io, libexec_dir, ll_local, ll.source_path);
    }

    // 6. Fallback linking for artifacts without successful module metadata linking
    for (projected_artifacts) |pa| {
        const hash = pa.artifact_hash;
        const policy = pa.role.getProjectionPolicy();

        if (policy.metadata_only) continue;

        const art_path = try index.get_artifact_path(hash) orelse continue;
        defer allocator.free(art_path);

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
                        try symlinkTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".lua")) {
                        try env_dir.symLink(io, mod_src, mod_dest, .{});
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
                    try symlinkTree(allocator, io, ddir, mod_src);
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
                        try symlinkTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".lua")) {
                        try env_dir.symLink(io, mod_src, mod_dest, .{});
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
                        try symlinkTree(allocator, io, ddir, mod_src);
                    } else if (sub_entry.kind == .file and std.mem.endsWith(u8, sub_entry.name, ".lua")) {
                        try env_dir.symLink(io, mod_src, mod_dest, .{});
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
        try linkPackageIntoLibexec(io, libexec_dir, pa_local, pa_path);
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

    refreshLspConfig(allocator, io, project_root);
}

fn refreshLspConfig(allocator: std.mem.Allocator, io: std.Io, project_root: std.Io.Dir) void {
    const content = project_root.readFileAlloc(io, ".luarc.json", allocator, std.Io.Limit.limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    const legacy_path = ".moonstone/env/lua/";
    if (std.mem.indexOf(u8, content, legacy_path) != null) {
        const migrated = std.mem.replaceOwned(u8, allocator, content, legacy_path, ".moonstone/env/share/lua/") catch return;
        defer allocator.free(migrated);

        const file = project_root.createFile(io, ".luarc.json", .{}) catch return;
        defer file.close(io);
        file.writeStreamingAll(io, migrated) catch return;
        return;
    }

    const file = project_root.openFile(io, ".luarc.json", .{ .mode = .read_write }) catch return;
    defer file.close(io);
    file.setTimestampsNow(io) catch {};
}

fn linkPackageIntoLibexec(
    io: std.Io,
    libexec_dir: std.Io.Dir,
    local_name: []const u8,
    src_path: []const u8,
) !void {
    libexec_dir.deleteTree(io, local_name) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    libexec_dir.symLink(io, src_path, local_name, .{}) catch |err| {
        if (err == error.PathAlreadyExists) {
            try libexec_dir.deleteFile(io, local_name);
            try libexec_dir.symLink(io, src_path, local_name, .{});
        } else return err;
    };
}

fn symlinkTree(allocator: std.mem.Allocator, io: std.Io, dest_parent_dir: std.Io.Dir, src_path: []const u8) !void {
    var src_dir = std.Io.Dir.openDirAbsolute(io, src_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer src_dir.close(io);

    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        const src_file = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_file);

        if (entry.kind == .directory) {
            try dest_parent_dir.createDirPath(io, entry.name);
            var sub_dest_dir = try dest_parent_dir.openDir(io, entry.name, .{});
            defer sub_dest_dir.close(io);
            try symlinkTree(allocator, io, sub_dest_dir, src_file);
        } else {
            dest_parent_dir.symLink(io, src_file, entry.name, .{}) catch |err| {
                if (err == error.PathAlreadyExists) {
                    try dest_parent_dir.deleteFile(io, entry.name);
                    try dest_parent_dir.symLink(io, src_file, entry.name, .{});
                } else return err;
            };
        }
    }
}

test "link_project_env basic" {
    // This is an integration test that requires filesystem setup.
    // We verify the struct compiles correctly.
    _ = LiveLink{ .name = "test", .source_path = "/tmp", .mode = "live", .pkg_name = "test", .pkg_version = "0.1.0", .pkg_kind = .lib };
}

test "shim generation does not hardcode lua versions" {
    const allocator = std.testing.allocator;
    const io = std.Io.default;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try liveLinkScriptCommand(allocator, io, tmp.dir, "dummy_bin", "/fake/source", "dummy_cmd");

    const content = try tmp.dir.readFileAlloc(io, "dummy_bin", allocator, 4096);
    defer allocator.free(content);

    // Should contain the dynamic loop
    try std.testing.expect(std.mem.indexOf(u8, content, "for d in \"$TOOL_ROOT/.moonstone/env/share/lua/\"*; do") != null);

    // Should NOT contain the old hardcoded versions
    try std.testing.expect(std.mem.indexOf(u8, content, "share/lua/5.1/") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "share/lua/5.4/") == null);
}
