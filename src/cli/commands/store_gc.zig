const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StoreGcCommand = struct {
    pub const name = "gc";
    pub const description = "Garbage collect unreferenced store artifacts";

    dry_run: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store gc [flags]
            \\
            \\Identify and remove artifacts from the store that are not referenced
            \\by any local project's moonstone.lock.
            \\
            \\Flags:
            \\  --dry-run     Show what would be deleted without actually deleting
            \\
        , .{});
    }

    pub fn run(self: StoreGcCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        var reachable = std.StringHashMap(void).init(allocator);
        defer {
            var it = reachable.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            reachable.deinit();
        }

        // 1. Scan registered projects
        var projects_dir = std.Io.Dir.cwd().openDir(io, paths.projects, .{ .iterate = true }) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            return err;
        };
        if (projects_dir) |*pdir| {
            defer pdir.close(io);
            var it = pdir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .sym_link and entry.kind != .directory) continue;
                
                const proj_reg_path = try std.fs.path.join(allocator, &.{ paths.projects, entry.name });
                defer allocator.free(proj_reg_path);

                const proj_root = if (entry.kind == .sym_link) blk: {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const len = pdir.readLink(io, entry.name, &buf) catch continue;
                    break :blk try allocator.dupe(u8, buf[0..len]);
                } else try allocator.dupe(u8, proj_reg_path);
                defer allocator.free(proj_root);

                const lock_path = try std.fs.path.join(allocator, &.{ proj_root, "moonstone.lock" });
                defer allocator.free(lock_path);

                const lock_content = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, std.Io.Limit.limited(50 * 1024 * 1024)) catch continue;
                defer allocator.free(lock_content);

                var lf = moonstone.domain.lockfile.LockFile.parse(allocator, lock_content) catch continue;
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

        // 2. Scan store for candidates
        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

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
                        var parts = std.mem.splitScalar(u8, art_entry.name, '-');
                        const hash_part = parts.first();
                        const full_hash = try std.fmt.allocPrint(allocator, "b3:{s}", .{hash_part});
                        try candidates.append(allocator, full_hash);
                    }
                }
            }
        }

        var deleted: usize = 0;
        var freed_bytes: usize = 0;

        for (candidates.items) |hash| {
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
                        try stdout.print("Would GC: {s} ({d} bytes)\n", .{ hash, size });
                    } else {
                        try stdout.print("GC: {s} ({d} bytes)\n", .{ hash, size });
                    }
                    break;
                }
            }
        }

        if (self.dry_run) {
            try stdout.print("Would delete {d} artifact(s), freeing {d} bytes\n", .{ deleted, freed_bytes });
        } else {
            try stdout.print("Deleted {d} artifact(s), freed {d} bytes\n", .{ deleted, freed_bytes });
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
