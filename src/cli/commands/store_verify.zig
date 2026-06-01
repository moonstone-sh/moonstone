const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StoreVerifyCommand = struct {
    pub const name = "verify";
    pub const description = "Verify store artifacts integrity";

    all: bool = false,
    repair: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store verify [flags]
            \\
            \\Verify the integrity of all artifacts in the store.
            \\
            \\Flags:
            \\  --repair      Delete corrupted artifacts from the store and index
            \\  --json        Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: StoreVerifyCommand, ctx: *router.Context) !void {
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

        const sql = "SELECT artifact_hash, path, name, version FROM artifacts;";
        var stmt: ?*sql_c.sqlite3_stmt = null;
        if (sql_c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != sql_c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = sql_c.sqlite3_finalize(stmt);

        var total: usize = 0;
        var corrupted: usize = 0;

        while (sql_c.sqlite3_step(stmt) == sql_c.SQLITE_ROW) {
            total += 1;
            const expected_hash = std.mem.span(sql_c.sqlite3_column_text(stmt, 0));
            const art_path = std.mem.span(sql_c.sqlite3_column_text(stmt, 1));
            const p_name = std.mem.span(sql_c.sqlite3_column_text(stmt, 2));
            const version = std.mem.span(sql_c.sqlite3_column_text(stmt, 3));

            if (!self.json) {
                try stdout.print("Verifying {s}@{s}... ", .{ p_name, version });
            }

            const files_path = try std.fs.path.join(allocator, &.{ art_path, "files" });
            defer allocator.free(files_path);

            var dir = std.Io.Dir.cwd().openDir(io, files_path, .{ .iterate = true }) catch {
                if (!self.json) try stdout.print("FAILED (missing files)\n", .{});
                corrupted += 1;
                continue;
            };
            defer dir.close(io);

            const actual_hash_raw = try moonstone.identity.hash.artifact_hash(allocator, io, dir);
            defer allocator.free(actual_hash_raw);
            const actual_hash = try std.fmt.allocPrint(allocator, "b3:{s}", .{actual_hash_raw});
            defer allocator.free(actual_hash);

            if (!std.mem.eql(u8, expected_hash, actual_hash)) {
                if (!self.json) try stdout.print("CORRUPTED!\n  Expected: {s}\n  Actual:   {s}\n", .{ expected_hash, actual_hash });
                corrupted += 1;
                
                if (self.repair) {
                    if (!self.json) try stdout.print("Repairing (deleting artifact)...\n", .{});
                    var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
                    defer idx.deinit();
                    try idx.delete_artifact(expected_hash);
                    try std.Io.Dir.cwd().deleteTree(io, art_path);
                }
            } else {
                if (!self.json) try stdout.print("OK\n", .{});
            }
        }

        if (!self.json) {
            try stdout.print("\nVerification complete: {d} artifacts checked, {d} corrupted.\n", .{ total, corrupted });
        }
    }
};
