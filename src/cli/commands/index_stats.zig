const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StoreDriverStatsCommand = struct {
    pub const name = "stats";
    pub const description = "Show metadata index statistics";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon index stats [flags]
            \\
            \\Show statistics for the local metadata index.
            \\
            \\Flags:
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: StoreDriverStatsCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        const sql_c = moonstone.store.driver.c;
        var db: ?*sql_c.sqlite3 = null;
        if (sql_c.sqlite3_open(index_db_path_z, &db) != sql_c.SQLITE_OK) return error.SQLiteOpenError;
        defer _ = sql_c.sqlite3_close(db);

        const sql = "SELECT COUNT(*) FROM artifacts;";
        var stmt: ?*sql_c.sqlite3_stmt = null;
        if (sql_c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sql_c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = sql_c.sqlite3_finalize(stmt);

        if (sql_c.sqlite3_step(stmt) == sql_c.SQLITE_ROW) {
            const count = sql_c.sqlite3_column_int(stmt, 0);
            if (self.json) {
                try stdout.print("{{\"artifact_count\": {d}}}\n", .{count});
            } else {
                try stdout.print("Total artifacts in index: {d}\n", .{count});
            }
        }
    }
};
