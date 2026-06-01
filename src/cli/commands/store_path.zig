const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StorePathCommand = struct {
    pub const name = "path";
    pub const description = "Derive store path for a package or hash";

    positionals: []const []const u8 = &.{},
    files: bool = false,
    manifest: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store path [flags] <spec>
            \\
            \\Derive the local store path for a package or raw hash.
            \\
            \\Arguments:
            \\  <spec>        Package spec (name[@version]) or b3:<hash>
            \\
            \\Flags:
            \\  --files       Return path to 'files' directory
            \\  --manifest    Return path to 'manifest.toml'
            \\  --json        Output as JSON
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        _ = args;
        const paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
        defer { var p = paths; p.deinit(ctx.allocator); }
        const index_db = try std.fs.path.join(ctx.allocator, &.{ paths.index, "index.sqlite" });
        defer ctx.allocator.free(index_db);
        const index_db_z = try ctx.allocator.dupeZ(u8, index_db);
        defer ctx.allocator.free(index_db_z);

        const c = moonstone.store.driver.c;
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(index_db_z, &db) != c.SQLITE_OK) return &.{};
        defer _ = c.sqlite3_close(db);

        const sql = "SELECT DISTINCT name FROM artifacts;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return &.{};
        defer _ = c.sqlite3_finalize(stmt);

        var list = std.ArrayList([]const u8).empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const name_val = std.mem.span(c.sqlite3_column_text(stmt, 0));
            try list.append(ctx.allocator, try ctx.allocator.dupe(u8, name_val));
        }
        return list.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: StorePathCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        if (self.positionals.len == 0) return error.MissingArgument;
        const spec = self.positionals[0];

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);

        // 1. If it's a raw hash, we can derive the path without the index
        if (std.mem.startsWith(u8, spec, "b3:")) {
            const hash = spec[3..];
            if (hash.len < 4) return error.InvalidHash;

            const h0h1 = hash[0..2];
            const h2h3 = hash[2..4];

            const shard_path = try std.fs.path.join(allocator, &.{ paths.store, "b3", h0h1, h2h3 });
            defer allocator.free(shard_path);

            var shard_dir = std.Io.Dir.cwd().openDir(io, shard_path, .{ .iterate = true }) catch |err| {
                if (err == error.FileNotFound) return error.ArtifactNotFound;
                return err;
            };
            defer shard_dir.close(io);

            var it = shard_dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, hash)) {
                    const full_art_path = try std.fs.path.join(allocator, &.{ shard_path, entry.name });
                    defer allocator.free(full_art_path);
                    return try self.print_result(allocator, io, stdout, full_art_path);
                }
            }
            return error.ArtifactNotFound;
        }

        // 2. Otherwise, use the index
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        const sql_c = moonstone.store.driver.c;
        var db: ?*sql_c.sqlite3 = null;
        if (sql_c.sqlite3_open(index_db_path_z, &db) != sql_c.SQLITE_OK) return error.SQLiteOpenError;
        defer _ = sql_c.sqlite3_close(db);

        var pkg_name = spec;
        var pkg_ver: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, spec, '@')) |pos| {
            pkg_name = spec[0..pos];
            pkg_ver = spec[pos + 1 ..];
        }

        var stmt: ?*sql_c.sqlite3_stmt = null;
        const sql = if (pkg_ver != null)
            "SELECT path FROM artifacts WHERE name = ? AND version = ? LIMIT 1;"
        else
            "SELECT path FROM artifacts WHERE name = ? ORDER BY created_at DESC LIMIT 1;";

        if (sql_c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sql_c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = sql_c.sqlite3_finalize(stmt);

        const transient = @import("command.zig").moonstone_sqlite_transient();
        _ = sql_c.sqlite3_bind_text(stmt, 1, pkg_name.ptr, @intCast(pkg_name.len), transient);
        if (pkg_ver) |v| {
            _ = sql_c.sqlite3_bind_text(stmt, 2, v.ptr, @intCast(v.len), transient);
        }

        if (sql_c.sqlite3_step(stmt) == sql_c.SQLITE_ROW) {
            const art_path = std.mem.span(sql_c.sqlite3_column_text(stmt, 0));
            try self.print_result(allocator, io, stdout, art_path);
        } else {
            return error.ArtifactNotFound;
        }
    }

    fn print_result(self: StorePathCommand, allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, art_path: []const u8) !void {
        var path_to_print: []const u8 = art_path;
        var to_free: ?[]const u8 = null;
        defer if (to_free) |p| allocator.free(p);

        if (self.manifest) {
            path_to_print = try std.fs.path.join(allocator, &.{ art_path, "manifest.toml" });
            to_free = path_to_print;
        } else if (self.files) {
            path_to_print = try std.fs.path.join(allocator, &.{ art_path, "files" });
            to_free = path_to_print;
        }

        if (self.json) {
            try stdout.print("{{\"path\": \"{s}\"}}\n", .{path_to_print});
        } else {
            try stdout.print("{s}\n", .{path_to_print});
        }
        _ = io;
    }
};
