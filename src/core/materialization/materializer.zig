const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const registry = @import("../registry/registry.zig");
const fs = @import("../platform/fs.zig");
const store = @import("../store.zig");
const resolver = @import("../resolution/root.zig");
const package_spec = @import("../domain/package_spec.zig");

fn descriptorDependencies(allocator: std.mem.Allocator, desc: manifest.RemotePackageDescriptor) ![]manifest.StoreDependency {
    var dependencies = std.ArrayList(manifest.StoreDependency).empty;
    errdefer {
        for (dependencies.items) |*dependency| dependency.deinit(allocator);
        dependencies.deinit(allocator);
    }

    for (desc.dependencies) |dep| {
        try dependencies.append(allocator, .{
            .name = try allocator.dupe(u8, dep.name),
            .constraint = try allocator.dupe(u8, dep.constraint),
            .resolver = if (dep.resolver) |r| try allocator.dupe(u8, r) else null,
            .role = dep.role,
            .optional = dep.optional,
        });
    }

    return try dependencies.toOwnedSlice(allocator);
}

pub const MaterializeResult = struct {
    path: []const u8,
    artifact_hash: []const u8,

    pub fn deinit(self: MaterializeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.artifact_hash);
    }
};

pub const Materializer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    runtime_path: ?[]const u8 = null,
    on_event: ?resolver.ResolveCallback = null,
    on_event_context: ?*anyopaque = null,

    fn sourcePayloadOptions(
        self: *Materializer,
        client: *registry.RegistryClient,
        descriptor_path: []const u8,
        desc: manifest.RemotePackageDescriptor,
        art: manifest.RemoteArtifact,
        blob_path: []const u8,
        tmp_path: []const u8,
    ) !store.SourcePayloadOptions {
        if (desc.source) |src| {
            if (src.url) |source_url| {
                const source_blob = try client.fetch_blob(descriptor_path, source_url);
                defer self.allocator.free(source_blob);

                const actual_hash = blk: {
                    var hash_buf: [32]u8 = undefined;
                    std.crypto.hash.Blake3.hash(source_blob, &hash_buf, .{});
                    const actual_hex = std.fmt.bytesToHex(hash_buf, .lower);
                    break :blk try std.fmt.allocPrint(self.allocator, "b3:{s}", .{&actual_hex});
                };
                defer self.allocator.free(actual_hash);

                if (src.hash.len > 0 and !std.mem.eql(u8, actual_hash, src.hash)) return error.HashMismatch;

                const payload_name = try std.fmt.allocPrint(self.allocator, "source.{s}", .{src.format});
                defer self.allocator.free(payload_name);
                const payload_path = try std.fs.path.join(self.allocator, &.{ tmp_path, payload_name });
                const payload_file = try std.Io.Dir.cwd().createFile(self.io, payload_path, .{});
                try payload_file.writeStreamingAll(self.io, source_blob);
                payload_file.close(self.io);

                return .{
                    .source_kind = src.kind,
                    .source_payload_path = payload_path,
                };
            }
        }

        if (std.mem.eql(u8, art.kind, "source") or art.materialize != null) {
            return .{
                .source_kind = art.kind,
                .source_payload_path = blob_path,
            };
        }

        return .{};
    }

    pub fn materialize_remote(
        self: *Materializer,
        registry_url: []const u8,
        token: ?[]const u8,
        descriptor_path: []const u8,
        desc: manifest.RemotePackageDescriptor,
        artifact_idx: usize,
    ) !MaterializeResult {
        const art = desc.artifact[artifact_idx];
        const is_source = std.mem.eql(u8, art.kind, "source");

        var client = registry.RegistryClient.init(self.allocator, self.io, registry_url, token, self.environ_map);
        client.on_event = self.on_event;
        client.on_event_context = self.on_event_context;
        defer client.deinit();

        // 1. Download blob
        const blob = try client.fetch_blob(descriptor_path, art.url);
        defer self.allocator.free(blob);

        // 2. Verify BLAKE3 hash
        const actual_hash = blk: {
            var hash_buf: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(blob, &hash_buf, .{});
            const actual_hex = std.fmt.bytesToHex(hash_buf, .lower);
            break :blk try std.fmt.allocPrint(self.allocator, "b3:{s}", .{&actual_hex});
        };
        defer self.allocator.free(actual_hash);

        if (art.hash.len > 0) {
            if (!std.mem.eql(u8, actual_hash, art.hash)) {
                return error.HashMismatch;
            }
        }

        // 3. Setup tmp path and unpack
        const paths = try fs.resolve_moonstone(self.allocator, self.environ_map, self.io);
        defer {
            var p = paths;
            p.deinit(self.allocator);
        }

        const tmp_dir_name = try std.fmt.allocPrint(self.allocator, "unpack-{s}", .{actual_hash[3..15]});
        defer self.allocator.free(tmp_dir_name);

        const tmp_path = try std.fs.path.join(self.allocator, &.{ paths.tmp, tmp_dir_name });
        defer self.allocator.free(tmp_path);

        try std.Io.Dir.cwd().createDirPath(self.io, tmp_path);

        // For runtime packages, use the extracted source as the effective runtime path
        // since there is no pre-existing runtime when building the runtime itself.
        const had_runtime = self.runtime_path != null;
        if (self.runtime_path == null and desc.package.kind == .runtime) {
            self.runtime_path = tmp_path;
        }

        // Write blob to tmp for unpacking
        if (!std.mem.eql(u8, art.format, "tar.gz") and !std.mem.eql(u8, art.format, "tar.zst") and !std.mem.eql(u8, art.format, "zip")) return error.UnsupportedArchiveFormat;
        const blob_name = try std.fmt.allocPrint(self.allocator, "blob.{s}", .{art.format});
        defer self.allocator.free(blob_name);
        const blob_path = try std.fs.path.join(self.allocator, &.{ tmp_path, blob_name });
        defer self.allocator.free(blob_path);
        const blob_file = try std.Io.Dir.cwd().createFile(self.io, blob_path, .{});
        try blob_file.writeStreamingAll(self.io, blob);
        blob_file.close(self.io);

        const source_payloads = try self.sourcePayloadOptions(&client, descriptor_path, desc, art, blob_path, tmp_path);
        defer if (source_payloads.source_payload_path) |payload_path| {
            if (!std.mem.eql(u8, payload_path, blob_path)) self.allocator.free(payload_path);
        };
        const source_origin = if (desc.source) |src| (src.url orelse art.url) else art.url;
        const source_hash = if (desc.source) |src| src.hash else if (art.source_hash.len > 0) art.source_hash else if (source_payloads.source_payload_path != null) art.hash else "";

        // Unpack using system archive tools
        var tar_argv = std.ArrayList([]const u8).empty;
        defer tar_argv.deinit(self.allocator);
        var strip_arg: ?[]const u8 = null;
        if (std.mem.eql(u8, art.format, "zip")) {
            if (art.layout.strip_components > 0) return error.UnsupportedZipStripComponents;
            try tar_argv.append(self.allocator, "unzip");
            try tar_argv.append(self.allocator, "-q");
            try tar_argv.append(self.allocator, blob_path);
            try tar_argv.append(self.allocator, "-d");
            try tar_argv.append(self.allocator, tmp_path);
        } else {
            try tar_argv.append(self.allocator, "tar");
            try tar_argv.append(self.allocator, "-xf");
            try tar_argv.append(self.allocator, blob_path);
            try tar_argv.append(self.allocator, "-C");
            try tar_argv.append(self.allocator, tmp_path);
        }
        if (!std.mem.eql(u8, art.format, "zip") and art.layout.strip_components > 0) {
            strip_arg = try std.fmt.allocPrint(self.allocator, "--strip-components={d}", .{art.layout.strip_components});
            try tar_argv.append(self.allocator, strip_arg.?);
        }
        defer if (strip_arg) |sa| self.allocator.free(sa);

        const tar_res = try std.process.run(self.allocator, self.io, .{ .argv = tar_argv.items });
        if (tar_res.term != .exited or tar_res.term.exited != 0) return error.UnpackError;

        var final_art = art;
        final_art.source_hash = source_hash;

        // 4. Handle Materialization
        if (is_source and art.materialize != null) {
            const m = art.materialize.?;

            const build_out_dir_name = try std.fmt.allocPrint(self.allocator, "build-{s}", .{actual_hash[3..15]});
            defer self.allocator.free(build_out_dir_name);
            const build_out_path = try std.fs.path.join(self.allocator, &.{ paths.tmp, build_out_dir_name });
            defer self.allocator.free(build_out_path);
            try std.Io.Dir.cwd().createDirPath(self.io, build_out_path);

            const host_target = try self.get_host_target();
            defer self.allocator.free(host_target);

            if (std.mem.eql(u8, m.kind, "native_cmodule")) {
                if (self.runtime_path) |rt_path| {
                    const native_cmodule = @import("materializers/native_cmodule.zig");
                    try native_cmodule.build(self.allocator, self.io, self.environ_map, tmp_path, build_out_path, rt_path, m);

                    const zig_version_res = try std.process.run(self.allocator, self.io, .{ .argv = &.{ "zig", "version" } });
                    defer self.allocator.free(zig_version_res.stdout);
                    defer self.allocator.free(zig_version_res.stderr);
                    const zig_version = std.mem.trim(u8, zig_version_res.stdout, " \n\r");

                    const runtime_hash = if (had_runtime)
                        try @import("../identity/hash.zig").blake3_file(self.allocator, self.io, try std.fs.path.join(self.allocator, &.{ rt_path, "manifest.toml" }))
                    else
                        "";
                    defer if (had_runtime) self.allocator.free(runtime_hash);

                    const recipe_hash = try store.computeRecipeHash(self.allocator, .{
                        .kind = @tagName(desc.package.kind),
                        .name = desc.package.name,
                        .version = desc.package.version,
                        .source_hash = art.hash,
                        .materializer = m.kind,
                        .strategy = m.strategy.?,
                        .zig_version = zig_version,
                        .runtime_hash = runtime_hash,
                        .lua_abi = art.lua_abi,
                        .target = host_target,
                        .sources = m.input.?.sources,
                        .output_module = m.output.?.module,
                        .output_path = m.output.?.path,
                    });
                    defer self.allocator.free(recipe_hash);

                    var new_provides = art.provides;
                    var cmodules = std.ArrayList(manifest.FeatureProvision).empty;
                    try cmodules.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, std.fs.path.basename(m.output.?.path)),
                        .path = try self.allocator.dupe(u8, m.output.?.path),
                    });
                    new_provides.lua_cmodule = try cmodules.toOwnedSlice(self.allocator);

                    const build_files_dir = try std.Io.Dir.cwd().openDir(self.io, build_out_path, .{ .iterate = true });
                    defer build_files_dir.close(self.io);
                    const art_hash_raw = try @import("../identity/hash.zig").artifact_hash(self.allocator, self.io, build_files_dir);
                    defer self.allocator.free(art_hash_raw);
                    const art_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{art_hash_raw});
                    defer self.allocator.free(art_hash);

                    final_art.target = host_target;
                    final_art.provides = new_provides;
                    final_art.recipe_hash = recipe_hash;
                    final_art.hash = art_hash;

                    const final_path = try store.commit_to_store_with_sources(self.allocator, self.io, self.environ_map, build_out_path, desc, final_art, "moonstone", source_origin, &.{}, source_payloads);
                    return MaterializeResult{ .path = final_path, .artifact_hash = try self.allocator.dupe(u8, art_hash) };
                } else return error.MissingRuntimePath;
            } else if (std.mem.eql(u8, m.kind, "cmake")) {
                if (self.runtime_path) |rt_path| {
                    const cmake = @import("materializers/cmake.zig");
                    try cmake.build(self.allocator, self.io, self.environ_map, tmp_path, build_out_path, rt_path, art.lua_abi, m);

                    const cmake_version_res = try std.process.run(self.allocator, self.io, .{ .argv = &.{ "cmake", "--version" } });
                    defer self.allocator.free(cmake_version_res.stdout);
                    defer self.allocator.free(cmake_version_res.stderr);
                    const cmake_version = std.mem.trim(u8, cmake_version_res.stdout, " \n\r");

                    const runtime_hash = if (had_runtime)
                        try @import("../identity/hash.zig").blake3_file(self.allocator, self.io, try std.fs.path.join(self.allocator, &.{ rt_path, "manifest.toml" }))
                    else
                        "";
                    defer if (had_runtime) self.allocator.free(runtime_hash);

                    const recipe_hash = try store.computeRecipeHash(self.allocator, .{
                        .kind = @tagName(desc.package.kind),
                        .name = desc.package.name,
                        .version = desc.package.version,
                        .source_hash = art.hash,
                        .materializer = m.kind,
                        .cmake_version = cmake_version,
                        .cmake_args = m.cmake_args,
                        .runtime_hash = runtime_hash,
                        .lua_abi = art.lua_abi,
                        .target = host_target,
                        .collect = m.collect,
                    });
                    defer self.allocator.free(recipe_hash);

                    var new_provides = try art.provides.clone(self.allocator);
                    errdefer new_provides.deinit(self.allocator);

                    // Update provides from collect config only if category was empty
                    if (new_provides.lua_cmodule.len == 0 and m.collect.lua_cmodules.len > 0) {
                        var cmodules = std.ArrayList(manifest.FeatureProvision).empty;
                        for (m.collect.lua_cmodules) |p| {
                            const rel_path = if (std.mem.startsWith(u8, p.path, "${build}/"))
                                p.path["${build}/".len..]
                            else if (std.mem.eql(u8, p.path, "${build}"))
                                "."
                            else
                                p.path;
                            try cmodules.append(self.allocator, .{
                                .name = try self.allocator.dupe(u8, p.name),
                                .path = try self.allocator.dupe(u8, rel_path),
                            });
                        }
                        new_provides.lua_cmodule = try cmodules.toOwnedSlice(self.allocator);
                    }

                    const build_files_dir = try std.Io.Dir.cwd().openDir(self.io, build_out_path, .{ .iterate = true });
                    defer build_files_dir.close(self.io);
                    const art_hash_raw = try @import("../identity/hash.zig").artifact_hash(self.allocator, self.io, build_files_dir);
                    defer self.allocator.free(art_hash_raw);
                    const art_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{art_hash_raw});
                    defer self.allocator.free(art_hash);

                    final_art.target = host_target;
                    final_art.provides = new_provides;
                    final_art.recipe_hash = recipe_hash;
                    final_art.hash = art_hash;

                    const final_path = try store.commit_to_store_with_sources(self.allocator, self.io, self.environ_map, build_out_path, desc, final_art, "moonstone", source_origin, &.{}, source_payloads);
                    return MaterializeResult{ .path = final_path, .artifact_hash = try self.allocator.dupe(u8, art_hash) };
                } else return error.MissingRuntimePath;
            } else if (std.mem.eql(u8, m.kind, "command")) {
                if (self.runtime_path) |rt_path| {
                    const command_mat = @import("materializers/command.zig");
                    try command_mat.build(self.allocator, self.io, self.environ_map, tmp_path, build_out_path, rt_path, art.lua_abi, m);

                    const runtime_hash = if (had_runtime)
                        try @import("../identity/hash.zig").blake3_file(self.allocator, self.io, try std.fs.path.join(self.allocator, &.{ rt_path, "manifest.toml" }))
                    else
                        "";
                    defer if (had_runtime) self.allocator.free(runtime_hash);

                    const recipe_hash = try store.computeRecipeHash(self.allocator, .{
                        .kind = @tagName(desc.package.kind),
                        .name = desc.package.name,
                        .version = desc.package.version,
                        .source_hash = art.hash,
                        .materializer = m.kind,
                        .strategy = if (m.command) |c| c else "multi-step",
                        .runtime_hash = runtime_hash,
                        .lua_abi = art.lua_abi,
                        .target = host_target,
                    });
                    defer self.allocator.free(recipe_hash);

                    var new_provides = try art.provides.clone(self.allocator);
                    errdefer new_provides.deinit(self.allocator);

                    // Update provides from collect config only if category was empty.
                    // When using 'command' materializer, files are collected into out_path
                    // at locations specified by 'name' in the collect config.
                    if (new_provides.lua_cmodule.len == 0 and m.collect.lua_cmodules.len > 0) {
                        var clist = std.ArrayList(manifest.FeatureProvision).empty;
                        for (m.collect.lua_cmodules) |p| try clist.append(self.allocator, .{
                            .name = try self.allocator.dupe(u8, std.fs.path.basename(p.name)),
                            .path = try self.allocator.dupe(u8, p.name),
                        });
                        new_provides.lua_cmodule = try clist.toOwnedSlice(self.allocator);
                    }
                    if (new_provides.lua_module.len == 0 and m.collect.lua_modules.len > 0) {
                        var clist = std.ArrayList(manifest.FeatureProvision).empty;
                        for (m.collect.lua_modules) |p| try clist.append(self.allocator, .{
                            .name = try self.allocator.dupe(u8, std.fs.path.basename(p.name)),
                            .path = try self.allocator.dupe(u8, p.name),
                        });
                        new_provides.lua_module = try clist.toOwnedSlice(self.allocator);
                    }
                    if (new_provides.bin.len == 0 and m.collect.bins.len > 0) {
                        var clist = std.ArrayList(manifest.FeatureProvision).empty;
                        for (m.collect.bins) |p| try clist.append(self.allocator, .{
                            .name = try self.allocator.dupe(u8, std.fs.path.basename(p.name)),
                            .path = try self.allocator.dupe(u8, p.name),
                        });
                        new_provides.bin = try clist.toOwnedSlice(self.allocator);
                    }

                    const build_files_dir = try std.Io.Dir.cwd().openDir(self.io, build_out_path, .{ .iterate = true });
                    defer build_files_dir.close(self.io);
                    const art_hash_raw = try @import("../identity/hash.zig").artifact_hash(self.allocator, self.io, build_files_dir);
                    defer self.allocator.free(art_hash_raw);
                    const art_hash = try std.fmt.allocPrint(self.allocator, "b3:{s}", .{art_hash_raw});
                    defer self.allocator.free(art_hash);

                    final_art.target = host_target;
                    final_art.provides = new_provides;
                    final_art.recipe_hash = recipe_hash;
                    final_art.hash = art_hash;

                    const final_path = try store.commit_to_store_with_sources(self.allocator, self.io, self.environ_map, build_out_path, desc, final_art, "moonstone", source_origin, &.{}, source_payloads);
                    return MaterializeResult{ .path = final_path, .artifact_hash = try self.allocator.dupe(u8, art_hash) };
                } else return error.MissingRuntimePath;
            }
        }

        // 5. Move to sharded store (Default prebuilt path)
        const dependencies = try descriptorDependencies(self.allocator, desc);
        defer {
            for (dependencies) |*dependency| dependency.deinit(self.allocator);
            self.allocator.free(dependencies);
        }
        const final_path = try store.commit_to_store_with_sources(self.allocator, self.io, self.environ_map, tmp_path, desc, final_art, "moonstone", source_origin, dependencies, source_payloads);
        return MaterializeResult{ .path = final_path, .artifact_hash = try self.allocator.dupe(u8, art.hash) };
    }

    fn get_host_target(self: Materializer) ![]const u8 {
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
        return try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ arch, os });
    }
};
