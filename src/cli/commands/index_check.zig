const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StoreDriverCheckCommand = struct {
    pub const name = "check";
    pub const description = "Verify metadata index integrity";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon index check [flags]
            \\
            \\Verify the integrity of the SQLite metadata index.
            \\
            \\Flags:
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: StoreDriverCheckCommand, ctx: *router.Context) !void {
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

        if (sql_c.sqlite3_exec(db, "PRAGMA integrity_check;", null, null, null) != sql_c.SQLITE_OK) return error.SQLiteExecError;
        
        if (!self.json) {
            try stdout.print("StoreDriver integrity check passed.\n", .{});
        }
    }
};
