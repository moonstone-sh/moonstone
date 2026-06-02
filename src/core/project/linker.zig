const std = @import("std");
const manifest = @import("../domain/manifest.zig");
const driver_mod = @import("../store/driver.zig");

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

pub fn link_project_env(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: std.Io.Dir,
    index: driver_mod.StoreDriver,
    artifact_hashes: []const []const u8,
    live_links: []const LiveLink,
) !void {
    try link_project_env_at(allocator, io, project_root, index, artifact_hashes, live_links, ".moonstone/env");
}

pub fn link_project_env_at(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: std.Io.Dir,
    index: driver_mod.StoreDriver,
    artifact_hashes: []const []const u8,
    live_links: []const LiveLink,
    env_path: []const u8,
) !void {
    const MapType = struct { path: []const u8, artifact_hash: []const u8 };
    const UnmanagedMap = std.StringArrayHashMapUnmanaged(MapType);

    var bin_map = UnmanagedMap.empty;
    defer {
        var it = bin_map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.path);
            allocator.free(e.value_ptr.artifact_hash);
        }
        bin_map.deinit(allocator);
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

    // 2. Query all provisions and check for conflicts
    for (artifact_hashes) |hash| {
        const art_path = try index.get_artifact_path(hash) orelse return error.ArtifactMissingFromStoreIndex;
        defer allocator.free(art_path);

        if (try index.get_provision_runtime(hash)) |r| {
            if (runtime_info) |existing| {
                if (!std.mem.eql(u8, existing.abi, r.abi)) {
                    return error.ABIMismatch;
                }
            }
            runtime_info = r;
        }

        const provs = try index.get_provisions(hash);
        defer {
            for (provs.bins) |p| {
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
            allocator.free(provs.headers);
            allocator.free(provs.libs);
            allocator.free(provs.lua_modules);
            allocator.free(provs.lua_cmodules);
        }

        for (provs.bins) |b| {
            if (bin_map.get(b.name)) |_| {
                return error.BinConflict;
            }
            const abs_bin_path = try std.fs.path.join(allocator, &.{ art_path, "files", b.path });
            try bin_map.put(allocator, try allocator.dupe(u8, b.name), .{
                .path = abs_bin_path,
                .artifact_hash = try allocator.dupe(u8, hash),
            });
        }

        for (provs.lua_modules) |m| {
            const abs_lua_path = try std.fs.path.join(allocator, &.{ art_path, "files", m.path });
            try lua_map.put(allocator, try allocator.dupe(u8, m.name), .{
                .path = abs_lua_path,
                .artifact_hash = try allocator.dupe(u8, hash),
            });
        }

        for (provs.lua_cmodules) |m| {
            const abs_cmod_path = try std.fs.path.join(allocator, &.{ art_path, "files", m.path });
            try cmod_map.put(allocator, try allocator.dupe(u8, m.name), .{
                .path = abs_cmod_path,
                .artifact_hash = try allocator.dupe(u8, hash),
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

    // 4. Link binaries from store artifacts
    var bit = bin_map.iterator();
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
            }
        } else if (ll.pkg_kind == .lib or ll.pkg_kind == .script) {
            // For library packages, link lua modules from source project's src/
            var module_name = try allocator.dupe(u8, ll.pkg_name);
            defer allocator.free(module_name);
            var i: usize = 0;
            while (i < module_name.len) : (i += 1) {
                if (module_name[i] == '-') module_name[i] = '_';
            }

            const module_dir_name = try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, module_name });
            defer allocator.free(module_dir_name);

            const module_lua_name = try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}.lua", .{ lua_ver_dot, module_name });
            defer allocator.free(module_lua_name);

            const module_subdir_path = try std.fs.path.join(allocator, &.{ ll.source_path, "src", module_name });
            defer allocator.free(module_subdir_path);

            const module_single_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.lua", .{ ll.source_path, module_name });
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
                // 2. Single-file layout: <source>/src/<module>.lua  (e.g. "moon init --template lib" output)
                const share_lua_dir = std.fs.path.dirname(module_lua_name) orelse "share/lua";
                env_dir.createDirPath(io, share_lua_dir) catch |create_err| {

                    return create_err;
                };
                env_dir.symLink(io, module_single_path, module_lua_name, .{}) catch |link_err| {

                    return link_err;
                };
            }
        }
    }

    // 6. Fallback linking for artifacts without successful module metadata linking
    for (artifact_hashes) |hash| {
        const art_path = try index.get_artifact_path(hash) orelse continue;
        defer allocator.free(art_path);

        // Try files/lua/ first
        const lua_files_path = try std.fs.path.join(allocator, &.{ art_path, "files", "lua" });
        defer allocator.free(lua_files_path);
        
        var lua_dir = std.Io.Dir.openDirAbsolute(io, lua_files_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                // Try files/src/
                const src_files_path = try std.fs.path.join(allocator, &.{ art_path, "files", "src" });
                defer allocator.free(src_files_path);
                var src_dir = std.Io.Dir.openDirAbsolute(io, src_files_path, .{ .iterate = true }) catch |err2| {
                    if (err2 == error.FileNotFound) continue;
                    return err2;
                };
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
                continue;
            }
            return err;
        };
        defer lua_dir.close(io);

        var it = lua_dir.iterate();
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

    refreshLspConfig(io, project_root);
}

fn refreshLspConfig(io: std.Io, project_root: std.Io.Dir) void {
    const file = project_root.openFile(io, ".luarc.json", .{ .mode = .read_write }) catch return;
    defer file.close(io);
    file.setTimestampsNow(io) catch {};
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
