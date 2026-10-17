const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StorePruneCommand = struct {
    pub const name = "prune";
    pub const description = "Prune unreferenced store artifacts";

    dry_run: bool = false,
    compact: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store prune [flags]
            \\
            \\Identify and remove artifacts from the store that are not referenced
            \\by any local project's moonstone.lock.
            \\
            \\Flags:
            \\  --compact     Reclaim index space after pruning
            \\  --dry-run     Show what would be deleted without actually deleting
            \\
        , .{});
    }

    pub fn run(self: StorePruneCommand, ctx: *router.Context) !void {
        return self.runSelected(ctx, null, false);
    }

    pub fn runSelected(self: StorePruneCommand, ctx: *router.Context, selected_hash: ?[]const u8, quiet: bool) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        var reachable = std.StringHashMap(void).init(allocator);
        defer {
            var it = reachable.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            reachable.deinit();
        }

        // 1. Scan store for links and clean up stale ones
        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        // The global selection is a live reference even without a project.
        const sql = moonstone.store.driver.c;
        var selected_stmt: ?*sql.sqlite3_stmt = null;
        if (sql.sqlite3_prepare_v2(idx.db, "SELECT artifact_hash, name, version FROM artifacts WHERE kind = 'runtime';", -1, &selected_stmt, null) != sql.SQLITE_OK) return error.SQLitePrepareError;
        {
            defer _ = sql.sqlite3_finalize(selected_stmt);
            while (sql.sqlite3_step(selected_stmt) == sql.SQLITE_ROW) {
                const hash = std.mem.span(sql.sqlite3_column_text(selected_stmt, 0));
                const runtime_name = std.mem.span(sql.sqlite3_column_text(selected_stmt, 1));
                const version = std.mem.span(sql.sqlite3_column_text(selected_stmt, 2));
                if (try @import("interpreter_remove.zig").isGlobalDefault(ctx, runtime_name, version)) {
                    if (!reachable.contains(hash)) try reachable.put(try allocator.dupe(u8, hash), {});
                }
            }
        }

        {
            var lr = moonstone.store.links.LinkStore.init(&idx);
            const links = try lr.list();
            defer moonstone.store.links.deinitEntries(links, allocator);

            for (links) |link| {
                const toml_path = try std.fs.path.join(allocator, &.{ link.path, "moonstone.toml" });
                defer allocator.free(toml_path);

                var is_valid = true;
                if (std.Io.Dir.cwd().access(io, toml_path, .{})) |_| {
                    const content = std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| blk: {
                        if (err == error.FileNotFound) {
                            is_valid = false;
                            break :blk null;
                        }
                        return err;
                    };
                    if (content) |c| {
                        defer allocator.free(c);
                        if (moonstone.domain.manifest.MoonstoneToml.parse(allocator, c)) |mt| {
                            var mut_mt = mt;
                            mut_mt.deinit(allocator);
                        } else |_| {
                            is_valid = false;
                        }
                    }
                } else |_| {
                    is_valid = false;
                }

                if (!is_valid and selected_hash == null) {
                    if (self.dry_run) {
                        if (!quiet) try stdout.print("Would unregister stale link: {s} -> {s}\n", .{ link.name, link.path });
                    } else {
                        try lr.unregister(link.name);
                        if (!quiet) try stdout.print("Unregistered stale link: {s}\n", .{link.name});
                    }
                } else {
                    if (link.mode == .artifact) {
                        if (try ownedArtifactHash(allocator, io, paths.store, link.path)) |hash| {
                            if (!reachable.contains(hash)) try reachable.put(hash, {}) else allocator.free(hash);
                        }
                    }
                }
            }
        }

        // 2. Scan registered projects
        var projects_dir = std.Io.Dir.cwd().openDir(io, paths.projects, .{ .iterate = true }) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            return err;
        };
        if (projects_dir) |*pdir| {
            defer pdir.close(io);
            var it = pdir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .sym_link and entry.kind != .directory and !(entry.kind == .file and std.mem.endsWith(u8, entry.name, ".path"))) continue;

                const proj_reg_path = try std.fs.path.join(allocator, &.{ paths.projects, entry.name });
                defer allocator.free(proj_reg_path);

                const proj_root = if (entry.kind == .file) try @import("project_registry.zig").readRoot(allocator, io, proj_reg_path) else if (entry.kind == .sym_link) blk: {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const len = pdir.readLink(io, entry.name, &buf) catch continue;
                    break :blk try allocator.dupe(u8, buf[0..len]);
                } else try allocator.dupe(u8, proj_reg_path);
                defer allocator.free(proj_root);

                const lock_path = try std.fs.path.join(allocator, &.{ proj_root, "moonstone.lock" });
                defer allocator.free(lock_path);

                const env_path = try std.fs.path.join(allocator, &.{ proj_root, ".moonstone/env/env.toml" });
                defer allocator.free(env_path);
                const env_content = std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, std.Io.Limit.limited(50 * 1024 * 1024)) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => return err,
                };
                if (env_content) |content| {
                    defer allocator.free(content);
                    var offset: usize = 0;
                    while (std.mem.indexOfPos(u8, content, offset, "b3:")) |start| {
                        offset = start + 3;
                        if (content.len - start < 67) continue;
                        const hash = content[start..][0..67];
                        var valid = true;
                        for (hash[3..]) |ch| if (!std.ascii.isHex(ch)) {
                            valid = false;
                            break;
                        };
                        if (valid and !reachable.contains(hash)) try reachable.put(try allocator.dupe(u8, hash), {});
                    }
                }
                const lock_content = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, std.Io.Limit.limited(50 * 1024 * 1024)) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer allocator.free(lock_content);

                var lf = moonstone.domain.lockfile.LockFile.parse(allocator, lock_content) catch return error.InvalidProjectLockfile;
                defer lf.deinit();

                for (lf.packages.items) |pkg| {
                    if (pkg.artifact_hash.len > 0) {
                        if (!reachable.contains(pkg.artifact_hash)) {
                            try reachable.put(try allocator.dupe(u8, pkg.artifact_hash), {});
                        }
                    }
                }
            }
        }

        // 3. Scan store for candidates
        var candidates = std.ArrayList([]const u8).empty;
        defer {
            for (candidates.items) |h| allocator.free(h);
            candidates.deinit(allocator);
        }

        const store_b3 = try std.fs.path.join(allocator, &.{ paths.store, "b3" });
        defer allocator.free(store_b3);

        const b3_dir = std.Io.Dir.cwd().openDir(io, store_b3, .{ .iterate = true }) catch null;
        if (b3_dir) |dir| {
            defer dir.close(io);
            var h0h1_it = dir.iterate();
            while (try h0h1_it.next(io)) |h0h1_entry| {
                if (h0h1_entry.kind != .directory) continue;
                const h0h1_path = try std.fs.path.join(allocator, &.{ store_b3, h0h1_entry.name });
                defer allocator.free(h0h1_path);
                var h0h1_dir = std.Io.Dir.cwd().openDir(io, h0h1_path, .{ .iterate = true }) catch continue;
                defer h0h1_dir.close(io);
                var h2h3_it = h0h1_dir.iterate();
                while (try h2h3_it.next(io)) |h2h3_entry| {
                    if (h2h3_entry.kind != .directory) continue;
                    const h2h3_path = try std.fs.path.join(allocator, &.{ h0h1_path, h2h3_entry.name });
                    defer allocator.free(h2h3_path);
                    var h2h3_dir = std.Io.Dir.cwd().openDir(io, h2h3_path, .{ .iterate = true }) catch continue;
                    defer h2h3_dir.close(io);
                    var art_it = h2h3_dir.iterate();
                    while (try art_it.next(io)) |art_entry| {
                        if (art_entry.kind != .directory) continue;
                        const candidate_path = try std.fs.path.join(allocator, &.{ h2h3_path, art_entry.name });
                        defer allocator.free(candidate_path);
                        if (try ownedArtifactHash(allocator, io, paths.store, candidate_path)) |hash| try candidates.append(allocator, hash);
                    }
                }
            }
        }

        var deleted: usize = 0;
        var freed_bytes: usize = 0;

        for (candidates.items) |hash| {
            if (selected_hash) |selected| if (!std.mem.eql(u8, selected, hash)) continue;
            if (reachable.contains(hash)) continue;

            const art_hash = hash[3..];
            const h0h1 = art_hash[0..2];
            const h2h3 = art_hash[2..4];
            const shard_dir_path = try std.fs.path.join(allocator, &.{ paths.store, "b3", h0h1, h2h3 });
            defer allocator.free(shard_dir_path);

            var dir = std.Io.Dir.cwd().openDir(io, shard_dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var iter = dir.iterate();
            while (try iter.next(io)) |entry| {
                if (std.mem.startsWith(u8, entry.name, art_hash)) {
                    const art_path = try std.fs.path.join(allocator, &.{ shard_dir_path, entry.name });
                    defer allocator.free(art_path);

                    const size = try calculateDirSize(allocator, io, art_path);

                    if (!self.dry_run) {
                        try idx.delete_artifact(hash);
                        try dir.deleteTree(io, entry.name);
                    }

                    deleted += 1;
                    freed_bytes += size;

                    if (self.dry_run) {
                        if (!quiet) try stdout.print("Would GC: {s} ({d} bytes)\n", .{ hash, size });
                    } else {
                        if (!quiet) try stdout.print("GC: {s} ({d} bytes)\n", .{ hash, size });
                    }
                    break;
                }
            }
        }

        if (self.compact and !self.dry_run) {
            const sql_c = moonstone.store.driver.c;
            if (sql_c.sqlite3_exec(idx.db, "VACUUM;", null, null, null) != sql_c.SQLITE_OK) return error.SQLiteExecError;
            if (!quiet) try stdout.print("Index compacted.\n", .{});
        }
        if (self.dry_run) {
            if (!quiet) try stdout.print("Would delete {d} artifact(s), freeing {d} bytes\n", .{ deleted, freed_bytes });
        } else {
            if (!quiet) try stdout.print("Deleted {d} artifact(s), freed {d} bytes\n", .{ deleted, freed_bytes });
        }
    }
};

fn calculateDirSize(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    var size: usize = 0;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const entry_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(entry_path);

        if (entry.kind == .directory) {
            size += try calculateDirSize(allocator, io, entry_path);
        } else if (entry.kind == .file) {
            const stat = try std.Io.Dir.cwd().statFile(io, entry_path, .{});
            size += @intCast(stat.size);
        }
    }
    return size;
}

// Only canonical CAS materializations may be reclaimed. Never infer ownership
// from a registration name or follow an external source directory.
pub fn ownedArtifactHash(allocator: std.mem.Allocator, io: std.Io, store: []const u8, path: []const u8) !?[]const u8 {
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, store, allocator) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(root);
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(canonical);
    const relative = try std.fs.path.relative(allocator, root, null, root, canonical);
    defer allocator.free(relative);
    var parts = std.mem.tokenizeAny(u8, relative, "/\\");
    if (!std.mem.eql(u8, parts.next() orelse return null, "b3")) return null;
    const first = parts.next() orelse return null;
    const second = parts.next() orelse return null;
    const leaf = parts.next() orelse return null;
    if (leaf.len < 64) return null;
    if (parts.next() != null) {
        const manifest = try std.fs.path.join(allocator, &.{ canonical, "manifest.toml" });
        defer allocator.free(manifest);
        std.Io.Dir.cwd().access(io, manifest, .{}) catch return null;
    }
    const hash = leaf[0..64];
    for (hash) |ch| if (!std.ascii.isHex(ch)) return null;
    if (!std.mem.eql(u8, first, hash[0..2]) or !std.mem.eql(u8, second, hash[2..4])) return null;
    if (leaf.len > 64 and leaf[64] != '-') return null;
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{hash});
}
