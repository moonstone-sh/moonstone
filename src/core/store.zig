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
    cmake_args: []const []const u8 = &.{},
    runtime_hash: []const u8 = "",
    lua_abi: []const u8 = "",
    target: []const u8 = "native",
    sources: []const []const u8 = &.{},
    output_module: []const u8 = "",
    output_path: []const u8 = "",
    collect: manifest.CollectConfig = .{},
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
    const cmake_args_str = try std.mem.join(allocator, ",", options.cmake_args);
    defer allocator.free(cmake_args_str);

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
        \\cmake_args={s}
        \\runtime_hash={s}
        \\lua_abi={s}
        \\target={s}
        \\sources={s}
        \\output_module={s}
        \\output_path={s}
        \\collect={s}
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
        cmake_args_str,
        options.runtime_hash,
        options.lua_abi,
        options.target,
        sources_str,
        options.output_module,
        options.output_path,
        collect_str.items,
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
    defer { var p = paths; p.deinit(allocator); }

    const tar_path = try std.fs.path.join(allocator, &.{ paths.tmp, "local-artifact.tar.gz" });
    defer allocator.free(tar_path);

    const tar_result = try std.process.run(allocator, io, .{
        .argv = &.{
            "tar",
            "-czf", tar_path, "-C", project_path, ".",
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
        .compat = .{
            .runtime_version = "lua@5.4", // Placeholder for local
            .lua_abi = lua_abi,
            .runtime_artifact_hash = "",
        },

        .provides = .{
            .runtime = &.{},
            .bin = &.{},
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
    const paths = try fs.resolve_moonstone(allocator, environ_map, io);
    defer { var p = paths; p.deinit(allocator); }

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
    
    // Atomic rename isn't possible across devices if store is elsewhere, 
    // but in v0 we assume local tmp/store.
    std.Io.Dir.cwd().deleteTree(io, final_art_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try std.Io.Dir.cwd().createDirPath(io, final_art_path);
    
    // We need to move the unpacked contents into 'files'
    _ = try std.process.run(allocator, io, .{
        .argv = &.{ "mv", unpacked_path, files_path },
    });

    // 2. Generate store manifest.toml
    const source_hash = remote_art.hash;
    const artifact_hash = remote_art.hash;
    
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
        },
        .compat = .{
            .runtime_version = "lua@unknown", // TODO: Get from desc
            .lua_abi = remote_art.lua_abi,
            .lua_api = remote_art.lua_abi,
            .runtime_artifact_hash = "", // TODO: Get from context
        },
        .dependencies = dependencies,

        .provides = .{
            .runtime = remote_art.provides.runtime,
            .bin = remote_art.provides.bin,
            .headers = remote_art.provides.headers,
            .native_lib = remote_art.provides.native_lib,
            .lua_module = remote_art.provides.lua_module,
            .lua_cmodule = remote_art.provides.lua_cmodule,
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
