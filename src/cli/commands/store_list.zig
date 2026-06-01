const std = @import("std");
const moonstone = @import("moonstone");
const c = moonstone.store.driver.c;
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const StoreListCommand = struct {
    pub const name = "list";
    pub const description = "List content in the local store or link registry";

    links: bool = false,
    runtimes: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store list [flags]
            \\
            \\List content currently installed or registered in Moonstone.
            \\
            \\Flags:
            \\  --links     List globally registered local links
            \\  --runtimes  List installed Lua runtimes
            \\  --json      Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn run(self: StoreListCommand, ctx: *router.Context) !void {
        if (self.links) {
            try self.runLinks(ctx);
            return;
        }
        if (self.runtimes) {
            try self.runRuntimes(ctx);
            return;
        }

        var emitter_obj = if (self.json) ndjson.Emitter.init(ctx.allocator, ctx.stdout, "store-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;

        const paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
        defer {
            var p = paths;
            p.deinit(ctx.allocator);
        }

        try std.Io.Dir.cwd().createDirPath(ctx.io, paths.index);
        const index_db_path = try std.fs.path.join(ctx.allocator, &.{ paths.index, "index.sqlite" });
        defer ctx.allocator.free(index_db_path);
        const index_db_path_z = try ctx.allocator.dupeZ(u8, index_db_path);
        defer ctx.allocator.free(index_db_path_z);

        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(index_db_path_z, &db) != c.SQLITE_OK) {
            return error.SQLiteOpenError;
        }
        defer _ = c.sqlite3_close(db);

        const sql = "SELECT name, version, kind, runtime, artifact_hash FROM artifacts ORDER BY name, version;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (emitter) |e| {
            try e.emit(ctx.io, .START, "store-list", "begin", .{});
        } else {
            try ctx.stdout.print("{s: <20} {s: <10} {s: <10} {s: <10} {s}\n", .{ "Name", "Version", "Kind", "Runtime", "Hash" });
            try ctx.stdout.print("--------------------------------------------------------------------------------\n", .{});
        }

        var count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            count += 1;
            const p_name = std.mem.span(c.sqlite3_column_text(stmt, 0));
            const version = std.mem.span(c.sqlite3_column_text(stmt, 1));
            const kind = std.mem.span(c.sqlite3_column_text(stmt, 2));
            const runtime = if (c.sqlite3_column_text(stmt, 3)) |r| std.mem.span(r) else "-";
            const hash = std.mem.span(c.sqlite3_column_text(stmt, 4));

            if (emitter) |e| {
                try e.emit(ctx.io, .STATUS, p_name, "entry", .{
                    .name = p_name,
                    .version = version,
                    .kind = kind,
                    .runtime = runtime,
                    .hash = hash,
                });
            } else {
                try ctx.stdout.print("{s: <20} {s: <10} {s: <10} {s: <10} {s}\n", .{ p_name, version, kind, runtime, hash[0..12] });
            }
        }

        if (emitter) |e| {
            try e.terminate(ctx.io, "store-list", "ok", .{ .count = count });
        }
    }

    fn runLinks(self: StoreListCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, "links-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, "links-list", "begin", .{});
        }

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        const lr = moonstone.store.links.LinkStore.init(&idx);
        const entries = try lr.list();
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }

        if (emitter == null) {
            try stdout.print("{s: <20} {s: <10} {s}\n", .{ "Name", "Version", "Path" });
            try stdout.print("--------------------------------------------------------------------------------\n", .{});
        }

        for (entries) |entry| {
            if (emitter) |e| {
                try e.emit(io, .STATUS, entry.name, "link", .{
                    .name = entry.name,
                    .version = entry.version,
                    .path = entry.path,
                    .kind = entry.kind,
                });
            } else {
                try stdout.print("{s: <20} {s: <10} {s}\n", .{ entry.name, entry.version, entry.path });
            }
        }

        if (emitter) |e| {
            try e.terminate(io, "links-list", "ok", .{ .count = entries.len });
        } else if (entries.len == 0) {
            try stdout.print("(no registered links found)\n", .{});
        }
    }

    fn runRuntimes(self: StoreListCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, "runtimes-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, "runtimes-list", "begin", .{});
        }

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        const sql = "SELECT DISTINCT name, version, lua_abi FROM artifacts WHERE kind = 'runtime' ORDER BY name, version;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
        defer _ = c.sqlite3_finalize(stmt);

        if (emitter == null) {
            try stdout.print("{s: <20} {s: <10} {s}\n", .{ "Name", "Version", "ABI" });
            try stdout.print("--------------------------------------------------------------------------------\n", .{});
        }

        var count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            count += 1;
            const r_name = std.mem.span(c.sqlite3_column_text(stmt, 0));
            const version = std.mem.span(c.sqlite3_column_text(stmt, 1));
            const abi = std.mem.span(c.sqlite3_column_text(stmt, 2));

            if (emitter) |e| {
                try e.emit(io, .STATUS, r_name, "runtime", .{
                    .name = r_name,
                    .version = version,
                    .abi = abi,
                });
            } else {
                try stdout.print("{s: <20} {s: <10} {s}\n", .{ r_name, version, abi });
            }
        }

        if (emitter) |e| {
            try e.terminate(io, "runtimes-list", "ok", .{ .count = count });
        } else if (count == 0) {
            try stdout.print("(no runtimes found)\n", .{});
        }
    }
};
