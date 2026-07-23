const std = @import("std");
const manifest = @import("domain/manifest.zig");
const fs = @import("platform/fs.zig");
const driver_mod = @import("store/driver.zig");
const hash = @import("identity/hash.zig");

pub const RecipeOptions = struct {
    kind: []const u8,
    name: []const u8,
    version: []const u8,
    source_hash: []const u8 = "",
    materializer: []const u8 = "prebuilt",
    strategy: []const u8 = "registry",
    zig_version: []const u8 = "",
    cmake_version: []const u8 = "",
    ldflags: []const []const u8 = &.{},
    runtime_hash: []const u8 = "",
    lua_abi: []const u8 = "",
    target: []const u8 = "native",
    sources: []const []const u8 = &.{},
    output_module: []const u8 = "",
    output_path: []const u8 = "",
    collect: manifest.CollectConfig = .{},
    build_env: []const []const u8 = &.{},
};

pub const SourcePayloadOptions = struct {
    source_kind: []const u8 = "",
    source_payload_path: ?[]const u8 = null,
    source_url: []const u8 = "",
    rockspec: []const u8 = "",
    rockspec_hash: []const u8 = "",
    rockspec_payload_path: ?[]const u8 = null,
};

/// Compute a deterministic recipe hash for artifacts.
pub fn computeRecipeHash(
    allocator: std.mem.Allocator,
    options: RecipeOptions,
) ![]const u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const sources_str = try std.mem.join(allocator, ",", options.sources);
    defer allocator.free(sources_str);
    const ldflags_str = try std.mem.join(allocator, ",", options.ldflags);
    defer allocator.free(ldflags_str);

    var collect_str = std.ArrayList(u8).empty;
    defer collect_str.deinit(allocator);
    for (options.collect.lua_cmodules) |p| {
        const s = try std.fmt.allocPrint(allocator, "cmod:{s}:{s},", .{ p.name, p.path });
        defer allocator.free(s);
        try collect_str.appendSlice(allocator, s);
    }
    for (options.collect.lua_modules) |p| {
        const s = try std.fmt.allocPrint(allocator, "mod:{s}:{s},", .{ p.name, p.path });
        defer allocator.free(s);
        try collect_str.appendSlice(allocator, s);
    }
    for (options.collect.bins) |p| {
        const s = try std.fmt.allocPrint(allocator, "bin:{s}:{s},", .{ p.name, p.path });
        defer allocator.free(s);
        try collect_str.appendSlice(allocator, s);
    }
    for (options.collect.headers) |p| {
        const s = try std.fmt.allocPrint(allocator, "hdr:{s}:{s},", .{ p.name, p.path });
        defer allocator.free(s);
        try collect_str.appendSlice(allocator, s);
    }
    for (options.collect.native_lib) |p| {
        const s = try std.fmt.allocPrint(allocator, "lib:{s}:{s},", .{ p.name, p.path });
        defer allocator.free(s);
        try collect_str.appendSlice(allocator, s);
    }

    var sorted_build_env = std.ArrayList([]const u8).empty;
    defer sorted_build_env.deinit(allocator);
    for (options.build_env) |env| {
        try sorted_build_env.append(allocator, env);
    }
    std.mem.sort([]const u8, sorted_build_env.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    const build_env_str = try std.mem.join(allocator, ",", sorted_build_env.items);
    defer allocator.free(build_env_str);

    const recipe_str = try std.fmt.allocPrint(allocator,
        \\moonstone:recipe:v2
        \\kind={s}
        \\name={s}
        \\version={s}
        \\source_hash={s}
        \\materializer={s}
        \\strategy={s}
        \\zig_version={s}
        \\cmake_version={s}
        \\ldflags={s}
        \\runtime_hash={s}
        \\lua_abi={s}
        \\target={s}
        \\sources={s}
        \\output_module={s}
        \\output_path={s}
        \\collect={s}
        \\build_env={s}
        \\
    , .{
        options.kind,
        options.name,
        options.version,
        options.source_hash,
        options.materializer,
        options.strategy,
        options.zig_version,
        options.cmake_version,
        ldflags_str,
        options.runtime_hash,
        options.lua_abi,
        options.target,
        sources_str,
        options.output_module,
        options.output_path,
        collect_str.items,
        build_env_str,
    });
    defer allocator.free(recipe_str);

    var hash_buf: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(recipe_str, &hash_buf, .{});
    const hex = std.fmt.bytesToHex(hash_buf, .lower);
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{hex});
}

/// Materialize a local project into the content-addressed store.
/// Returns the artifact_hash of the stored artifact.
pub fn materializeLocalProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    project_path: []const u8,
    name: []const u8,
    version: []const u8,
    kind: manifest.Kind,
    lua_abi: []const u8,
) ![]const u8 {
    const paths = try fs.resolve_moonstone(allocator, environ_map, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    const tar_path = try std.fs.path.join(allocator, &.{ paths.tmp, "local-artifact.tar.gz" });
    defer allocator.free(tar_path);

    const tar_result = try std.process.run(allocator, io, .{
        .argv = &.{
            "tar",
            "-czf",
            tar_path,
            "-C",
            project_path,
            ".",
        },
    });
    defer allocator.free(tar_result.stdout);
    defer allocator.free(tar_result.stderr);
    if (tar_result.term != .exited or tar_result.term.exited != 0) {
        return error.TarCreationFailed;
    }

    const artifact_hash = try hash.blake3_file(allocator, io, tar_path);
    defer allocator.free(artifact_hash);

    const art_hash = artifact_hash[3..];
    const h0h1 = art_hash[0..2];
    const h2h3 = art_hash[2..4];
    const shard_path = try std.fs.path.join(allocator, &.{ paths.store, "b3", h0h1, h2h3 });
    defer allocator.free(shard_path);
    try std.Io.Dir.cwd().createDirPath(io, shard_path);

    const art_folder_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ art_hash, name, version });
    defer allocator.free(art_folder_name);
    const final_art_path = try std.fs.path.join(allocator, &.{ shard_path, art_folder_name });
    defer allocator.free(final_art_path);

    const files_path = try std.fs.path.join(allocator, &.{ final_art_path, "files" });
    defer allocator.free(files_path);
    try std.Io.Dir.cwd().createDirPath(io, final_art_path);
    try std.Io.Dir.cwd().createDirPath(io, files_path);

    const extract_result = try std.process.run(allocator, io, .{
        .argv = &.{ "tar", "-xzf", tar_path, "-C", files_path },
    });
    defer allocator.free(extract_result.stdout);
    defer allocator.free(extract_result.stderr);
    if (extract_result.term != .exited or extract_result.term.exited != 0) {
        return error.TarExtractionFailed;
    }

    const mt_path = try std.fs.path.join(allocator, &.{ project_path, "moonstone.toml" });
    defer allocator.free(mt_path);
    const source_hash = try hash.blake3_file(allocator, io, mt_path);
    defer allocator.free(source_hash);

    const recipe_hash = try computeRecipeHash(allocator, .{
        .kind = @tagName(kind),
        .name = name,
        .version = version,
        .strategy = "local",
        .target = "native",
        .lua_abi = lua_abi,
    });
    defer allocator.free(recipe_hash);

    // StoreIndex modules from src/
    var lua_modules = std.ArrayList(manifest.FeatureProvision).empty;
    defer {
        for (lua_modules.items) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        lua_modules.deinit(allocator);
    }

    const src_path = try std.fs.path.join(allocator, &.{ project_path, "src" });
    defer allocator.free(src_path);

    if (std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true })) |src_dir| {
        var it = src_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) {
                // For now, assume top-level directories in src/ are modules
                try lua_modules.append(allocator, .{
                    .name = try allocator.dupe(u8, entry.name),
                    .path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.name}),
                });
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".lua")) {
                const mod_name = entry.name[0 .. entry.name.len - 4];
                try lua_modules.append(allocator, .{
                    .name = try allocator.dupe(u8, mod_name),
                    .path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.name}),
                });
            }
        }
        src_dir.close(io);
    } else |_| {}

    const sm = manifest.StoreManifest{
        .artifact = .{
            .name = name,
            .version = version,
            .kind = kind,
            .source_hash = source_hash,
            .recipe_hash = recipe_hash,
            .artifact_hash = artifact_hash,
            .target = "native",
        },
        .origin = .{
            .resolver = "local",
            .source = project_path,
        },
        .compat = .{
            .runtime_version = "lua@5.4", // Placeholder for local
            .lua_abi = lua_abi,
            .lua_api = lua_abi,
            .runtime_artifact_hash = "",
        },

        .provides = .{
            .runtime = &.{},
            .bin = &.{},
            .bin_lua = &.{},
            .headers = &.{},
            .native_lib = &.{},
            .lua_module = try allocator.dupe(manifest.FeatureProvision, lua_modules.items),
            .lua_cmodule = &.{},
        },
    };

    const manifest_path = try std.fs.path.join(allocator, &.{ final_art_path, "manifest.toml" });
    defer allocator.free(manifest_path);
    const manifest_file = try std.Io.Dir.cwd().createFile(io, manifest_path, .{});
    defer manifest_file.close(io);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try sm.serialize(allocator, &aw.writer);
    try aw.writer.flush();
    try manifest_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

    const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
    defer allocator.free(index_db_path);
    const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
    defer allocator.free(index_db_path_z);

    var idx = try driver_mod.StoreDriver.init(allocator, index_db_path_z);
    defer idx.deinit();

    try idx.register_artifact(allocator, sm, final_art_path, manifest_path);

    return try allocator.dupe(u8, artifact_hash);
}

pub fn commit_to_store(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    unpacked_path: []const u8,
    remote_desc: manifest.RemotePackageDescriptor,
    remote_art: manifest.RemoteArtifact,
    resolver: []const u8,
    source: []const u8,
    dependencies: []const manifest.StoreDependency,
) ![]const u8 {
    return try commit_to_store_with_sources(allocator, io, environ_map, unpacked_path, remote_desc, remote_art, resolver, source, dependencies, .{});
}

pub fn commit_to_store_with_sources(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    unpacked_path: []const u8,
    remote_desc: manifest.RemotePackageDescriptor,
    remote_art: manifest.RemoteArtifact,
    resolver: []const u8,
    source: []const u8,
    dependencies: []const manifest.StoreDependency,
    source_payloads: SourcePayloadOptions,
) ![]const u8 {
    const paths = try fs.resolve_moonstone(allocator, environ_map, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    const art_hash = remote_art.hash[3..]; // Strip b3:
    const h0h1 = art_hash[0..2];
    const h2h3 = art_hash[2..4];

    const shard_path = try std.fs.path.join(allocator, &.{ paths.store, "b3", h0h1, h2h3 });
    defer allocator.free(shard_path);
    try std.Io.Dir.cwd().createDirPath(io, shard_path);

    const art_folder_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ art_hash, remote_desc.package.name, remote_desc.package.version });
    defer allocator.free(art_folder_name);

    const final_art_path = try std.fs.path.join(allocator, &.{ shard_path, art_folder_name });
    defer allocator.free(final_art_path);

    // 1. Move unpacked files to art_path/files
    const files_path = try std.fs.path.join(allocator, &.{ final_art_path, "files" });
    defer allocator.free(files_path);

    if (try isCompleteArtifact(allocator, io, final_art_path, remote_art.hash)) {
        try registerCompleteArtifact(allocator, io, paths.index, final_art_path);
        if (!isPathWithin(unpacked_path, final_art_path)) {
            std.Io.Dir.cwd().deleteTree(io, unpacked_path) catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
        return try allocator.dupe(u8, final_art_path);
    }

    if (isPathWithin(unpacked_path, final_art_path)) return error.InvalidStoreCommitPath;

    // Atomic rename isn't possible across devices if store is elsewhere,
    // but in v0 we assume local tmp/store.
    std.Io.Dir.cwd().deleteTree(io, final_art_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try std.Io.Dir.cwd().createDirPath(io, final_art_path);

    var stored_source_payload: []const u8 = "";
    var stored_rockspec_payload: []const u8 = "";

    if (source_payloads.source_payload_path != null or source_payloads.rockspec_payload_path != null) {
        const sources_dir = try std.fs.path.join(allocator, &.{ final_art_path, "sources" });
        defer allocator.free(sources_dir);
        try std.Io.Dir.cwd().createDirPath(io, sources_dir);

        if (source_payloads.source_payload_path) |payload_path| {
            const dest_name = std.fs.path.basename(payload_path);
            const dest_path = try std.fs.path.join(allocator, &.{ sources_dir, dest_name });
            defer allocator.free(dest_path);
            const cp_res = try std.process.run(allocator, io, .{ .argv = &.{ "cp", payload_path, dest_path } });
            defer allocator.free(cp_res.stdout);
            defer allocator.free(cp_res.stderr);
            if (cp_res.term != .exited or cp_res.term.exited != 0) return error.CopyFailed;
            stored_source_payload = try std.fmt.allocPrint(allocator, "sources/{s}", .{dest_name});
        }

        if (source_payloads.rockspec_payload_path) |payload_path| {
            const dest_name = std.fs.path.basename(payload_path);
            const dest_path = try std.fs.path.join(allocator, &.{ sources_dir, dest_name });
            defer allocator.free(dest_path);
            const cp_res = try std.process.run(allocator, io, .{ .argv = &.{ "cp", payload_path, dest_path } });
            defer allocator.free(cp_res.stdout);
            defer allocator.free(cp_res.stderr);
            if (cp_res.term != .exited or cp_res.term.exited != 0) return error.CopyFailed;
            stored_rockspec_payload = try std.fmt.allocPrint(allocator, "sources/{s}", .{dest_name});
        }
    }
    defer if (stored_source_payload.len > 0) allocator.free(stored_source_payload);
    defer if (stored_rockspec_payload.len > 0) allocator.free(stored_rockspec_payload);

    // We need to move the unpacked contents into 'files' atomically
    std.Io.Dir.renameAbsolute(unpacked_path, files_path, io) catch |err| {
        // Fallback if renaming across mount points fails, though in cache it should be on the same volume
        if (err == error.RenameAcrossMountPoints) {
            _ = try std.process.run(allocator, io, .{
                .argv = &.{ "mv", unpacked_path, files_path },
            });
        } else {
            return err;
        }
    };

    // 2. Generate store manifest.toml
    const source_hash = if (remote_art.source_hash.len > 0) remote_art.source_hash else remote_art.hash;
    const artifact_hash = remote_art.hash;

    const runtime_version = if (isResolvableRuntimeSpec(remote_art.runtime))
        remote_art.runtime
    else if (remote_desc.runtime_bundled) |rb|
        try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rb.name, rb.version })
    else
        "";
    defer if (!isResolvableRuntimeSpec(remote_art.runtime) and remote_desc.runtime_bundled != null) allocator.free(runtime_version);

    const runtime_artifact_hash = if (isResolvableRuntimeSpec(remote_art.runtime) and remote_art.runtime_artifact_hash.len > 0)
        remote_art.runtime_artifact_hash
    else if (remote_desc.runtime_bundled) |rb|
        rb.artifact_hash
    else
        "";

    const sm = manifest.StoreManifest{
        .artifact = .{
            .name = remote_desc.package.name,
            .version = remote_desc.package.version,
            .kind = remote_desc.package.kind,
            .source_hash = source_hash,
            .recipe_hash = remote_art.recipe_hash,
            .artifact_hash = artifact_hash,
            .target = remote_art.target,
        },
        .origin = .{
            .resolver = resolver,
            .source = source,
            .source_kind = source_payloads.source_kind,
            .source_payload = stored_source_payload,
            .source_url = source_payloads.source_url,
            .rockspec = source_payloads.rockspec,
            .rockspec_hash = source_payloads.rockspec_hash,
            .rockspec_payload = stored_rockspec_payload,
        },
        .compat = .{
            .runtime_version = runtime_version,
            .lua_abi = remote_art.lua_abi,
            .lua_api = remote_art.lua_api,
            .runtime_artifact_hash = runtime_artifact_hash,
        },
        .provides = remote_art.provides,
        .dependencies = dependencies,
    };

    const manifest_path = try std.fs.path.join(allocator, &.{ final_art_path, "manifest.toml" });
    defer allocator.free(manifest_path);
    const manifest_file = try std.Io.Dir.cwd().createFile(io, manifest_path, .{});
    defer manifest_file.close(io);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try sm.serialize(allocator, &aw.writer);
    try aw.writer.flush();
    try manifest_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

    // 3. Register in SQLite index
    const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
    defer allocator.free(index_db_path);
    const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
    defer allocator.free(index_db_path_z);

    var idx = try driver_mod.StoreDriver.init(allocator, index_db_path_z);
    defer idx.deinit();

    try idx.register_artifact(allocator, sm, final_art_path, manifest_path);

    return try allocator.dupe(u8, final_art_path);
}

fn isCompleteArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    artifact_path: []const u8,
    expected_hash: []const u8,
) !bool {
    const files_path = try std.fs.path.join(allocator, &.{ artifact_path, "files" });
    defer allocator.free(files_path);
    var files_dir = std.Io.Dir.cwd().openDir(io, files_path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return false;
        return err;
    };
    files_dir.close(io);

    const manifest_path = try std.fs.path.join(allocator, &.{ artifact_path, "manifest.toml" });
    defer allocator.free(manifest_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer allocator.free(content);

    var stored_manifest = manifest.StoreManifest.parse(allocator, content) catch return false;
    defer stored_manifest.deinit(allocator);
    return std.mem.eql(u8, stored_manifest.artifact.artifact_hash, expected_hash);
}

fn registerCompleteArtifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    index_path: []const u8,
    artifact_path: []const u8,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ artifact_path, "manifest.toml" });
    defer allocator.free(manifest_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);
    var stored_manifest = try manifest.StoreManifest.parse(allocator, content);
    defer stored_manifest.deinit(allocator);

    try std.Io.Dir.cwd().createDirPath(io, index_path);
    const index_db_path = try std.fs.path.join(allocator, &.{ index_path, "index.sqlite" });
    defer allocator.free(index_db_path);
    const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
    defer allocator.free(index_db_path_z);

    var idx = try driver_mod.StoreDriver.init(allocator, index_db_path_z);
    defer idx.deinit();
    try idx.register_artifact(allocator, stored_manifest, artifact_path, manifest_path);
}

fn isPathWithin(path: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, path, parent)) return false;
    return path.len == parent.len or path[parent.len] == std.fs.path.sep;
}

fn isResolvableRuntimeSpec(runtime_spec: []const u8) bool {
    if (runtime_spec.len == 0) return false;
    if (std.mem.eql(u8, runtime_spec, "lua@unknown")) return false;
    if (std.mem.startsWith(u8, runtime_spec, "table:")) return false;
    if (std.mem.indexOfScalar(u8, runtime_spec, '@')) |at| return at > 0 and at + 1 < runtime_spec.len;
    return true;
}

test "computeRecipeHash is deterministic" {
    const allocator = std.testing.allocator;
    const h1 = try computeRecipeHash(allocator, .{
        .kind = "lib",
        .name = "my-lib",
        .version = "0.1.0",
        .strategy = "local",
        .target = "native",
        .lua_abi = "lua54",
    });
    defer allocator.free(h1);
    const h2 = try computeRecipeHash(allocator, .{
        .kind = "lib",
        .name = "my-lib",
        .version = "0.1.0",
        .strategy = "local",
        .target = "native",
        .lua_abi = "lua54",
    });
    defer allocator.free(h2);
    try std.testing.expectEqualStrings(h1, h2);
    try std.testing.expect(std.mem.startsWith(u8, h1, "b3:"));
}

test "computeRecipeHash differs by inputs" {
    const allocator = std.testing.allocator;
    const h1 = try computeRecipeHash(allocator, .{
        .kind = "lib",
        .name = "my-lib",
        .version = "0.1.0",
        .strategy = "local",
        .target = "native",
        .lua_abi = "lua54",
    });
    defer allocator.free(h1);
    const h2 = try computeRecipeHash(allocator, .{
        .kind = "lib",
        .name = "my-lib",
        .version = "0.2.0",
        .strategy = "local",
        .target = "native",
        .lua_abi = "lua54",
    });
    defer allocator.free(h2);
    try std.testing.expect(!std.mem.eql(u8, h1, h2));
}

test "commit_to_store reuses complete artifacts without deleting staging or itself" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", tmp_path);
    try env.put("MOONSTONE_HOME", tmp_path);

    const first_source = try std.fs.path.join(allocator, &.{ tmp_path, "first-source" });
    defer allocator.free(first_source);
    try std.Io.Dir.cwd().createDirPath(io, first_source);
    const first_file = try std.fs.path.join(allocator, &.{ first_source, "module.lua" });
    defer allocator.free(first_file);
    const first_handle = try std.Io.Dir.cwd().createFile(io, first_file, .{});
    defer first_handle.close(io);
    try first_handle.writeStreamingAll(io, "return 'first'\n");

    const second_source = try std.fs.path.join(allocator, &.{ tmp_path, "second-source" });
    defer allocator.free(second_source);
    try std.Io.Dir.cwd().createDirPath(io, second_source);
    const second_file = try std.fs.path.join(allocator, &.{ second_source, "module.lua" });
    defer allocator.free(second_file);
    const second_handle = try std.Io.Dir.cwd().createFile(io, second_file, .{});
    defer second_handle.close(io);
    try second_handle.writeStreamingAll(io, "return 'second'\n");

    const descriptor: manifest.RemotePackageDescriptor = .{
        .package = .{
            .name = "store-idempotence",
            .version = "1.0.0",
            .kind = .lib,
        },
        .compat = .{},
    };
    const artifact: manifest.RemoteArtifact = .{
        .url = "",
        .hash = "b3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .format = "tar.gz",
    };

    const raw_hash = artifact.hash[3..];
    const paths = try fs.resolve_moonstone(allocator, &env, io);
    defer {
        var owned_paths = paths;
        owned_paths.deinit(allocator);
    }
    const partial_path = try std.fs.path.join(allocator, &.{
        paths.store,
        "b3",
        raw_hash[0..2],
        raw_hash[2..4],
        raw_hash ++ "-store-idempotence-1.0.0",
    });
    defer allocator.free(partial_path);
    try std.Io.Dir.cwd().createDirPath(io, partial_path);
    const stale_path = try std.fs.path.join(allocator, &.{ partial_path, "stale" });
    defer allocator.free(stale_path);
    const stale_file = try std.Io.Dir.cwd().createFile(io, stale_path, .{});
    defer stale_file.close(io);
    try stale_file.writeStreamingAll(io, "incomplete");

    const first_path = try commit_to_store(allocator, io, &env, first_source, descriptor, artifact, "moonstone", "test", &.{});
    defer allocator.free(first_path);
    const index_file = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
    defer allocator.free(index_file);
    try std.Io.Dir.cwd().deleteFile(io, index_file);
    const second_path = try commit_to_store(allocator, io, &env, second_source, descriptor, artifact, "moonstone", "test", &.{});
    defer allocator.free(second_path);
    try std.testing.expectEqualStrings(first_path, second_path);
    const rebuilt_index = try std.Io.Dir.cwd().openFile(io, index_file, .{});
    rebuilt_index.close(io);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(io, second_source, .{}));
    const files_path = try std.fs.path.join(allocator, &.{ first_path, "files" });
    defer allocator.free(files_path);
    const nested_path = try commit_to_store(allocator, io, &env, files_path, descriptor, artifact, "moonstone", "test", &.{});
    defer allocator.free(nested_path);
    try std.testing.expectEqualStrings(first_path, nested_path);

    const stored_file = try std.fs.path.join(allocator, &.{ files_path, "module.lua" });
    defer allocator.free(stored_file);
    const stored_content = try std.Io.Dir.cwd().readFileAlloc(io, stored_file, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(stored_content);
    try std.testing.expectEqualStrings("return 'first'\n", stored_content);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, stale_path, .{}));
}
