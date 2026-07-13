const std = @import("std");
const moonstone = @import("moonstone");
const c = moonstone.store.driver.c;
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const table = @import("../table.zig");

fn bindNullable(stmt: ?*c.sqlite3_stmt, index: c_int, value: ?[]const u8, transient: c.sqlite3_destructor_type) void {
    if (value) |v| {
        _ = c.sqlite3_bind_text(stmt, index, v.ptr, @intCast(v.len), transient);
    } else {
        _ = c.sqlite3_bind_null(stmt, index);
    }
}

pub const StoreListCommand = struct {
    pub const name = "list";
    pub const description = "List content in the local store or link registry";

    links: bool = false,
    interpreters: bool = false,
    json: bool = false,
    search: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    resolver: ?[]const u8 = null,
    target: ?[]const u8 = null,
    abi: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store list [flags]
            \\
            \\List content currently installed or registered in Moonstone.
            \\
            \\Flags:
            \\  --links     List globally registered local links
            \\  --interpreters List installed Lua interpreters
            \\  --search <q> Filter by package name (trigram-backed for 3+ chars)
            \\  --kind <k>  Filter by kind (lib, bin, interpreter)
            \\  --resolver <r> Filter by resolver (moonstone, rocks)
            \\  --target <t> Filter by target triple
            \\  --abi <abi> Filter by Lua ABI
            \\  --json      Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn run(self: StoreListCommand, ctx: *router.Context) !void {
        if (self.links) {
            try self.runLinks(ctx);
            return;
        }
        if (self.interpreters) {
            try self.runInterpreters(ctx);
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

        var idx = try moonstone.store.driver.StoreDriver.init(ctx.allocator, index_db_path_z);
        defer idx.deinit();

        const search_uses_trigrams = if (self.search) |q| q.len >= 3 else false;
        const sql =
            \\SELECT DISTINCT a.name, a.version, a.kind, a.runtime, a.lua_abi, a.target, a.resolver, a.runtime_artifact_hash, a.artifact_hash
            \\FROM artifacts a
            \\LEFT JOIN artifact_name_trigrams t ON t.artifact_hash = a.artifact_hash
            \\WHERE (? IS NULL OR a.kind = ?)
            \\  AND (? IS NULL OR a.resolver = ?)
            \\  AND (? IS NULL OR a.target = ?)
            \\  AND (? IS NULL OR a.lua_abi = ?)
            \\  AND (? IS NULL OR lower(a.name) LIKE lower(?))
            \\  AND (? IS NULL OR t.trigram = ?)
            \\ORDER BY a.name, a.version, a.target, a.lua_abi;
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SQLitePrepareError;
        }
        defer _ = c.sqlite3_finalize(stmt);
        const transient = moonstone.store.driver.moonstone_sqlite_transient_ptr;
        var name_like: ?[]const u8 = null;
        defer if (name_like) |value| ctx.allocator.free(value);
        var name_tri: ?[]const u8 = null;
        defer if (name_tri) |value| ctx.allocator.free(value);
        if (self.search) |q| {
            name_like = try std.fmt.allocPrint(ctx.allocator, "%{s}%", .{q});
            if (search_uses_trigrams) {
                const lower = try std.ascii.allocLowerString(ctx.allocator, q[0..3]);
                name_tri = lower;
            }
        }
        const kind_filter = if (self.kind) |k| if (std.mem.eql(u8, k, "interpreter")) "runtime" else k else null;
        bindNullable(stmt, 1, kind_filter, transient);
        bindNullable(stmt, 2, kind_filter, transient);
        bindNullable(stmt, 3, self.resolver, transient);
        bindNullable(stmt, 4, self.resolver, transient);
        bindNullable(stmt, 5, self.target, transient);
        bindNullable(stmt, 6, self.target, transient);
        bindNullable(stmt, 7, self.abi, transient);
        bindNullable(stmt, 8, self.abi, transient);
        bindNullable(stmt, 9, name_like, transient);
        bindNullable(stmt, 10, name_like, transient);
        bindNullable(stmt, 11, name_tri, transient);
        bindNullable(stmt, 12, name_tri, transient);

        if (emitter) |e| {
            try e.emit(ctx.io, .START, "store-list", "begin", .{});
        } else {
            var widths: [9]usize = undefined;
            table.fitWidths(table.terminalWidth(ctx.env), &.{ 16, 10, 7, 8, 7, 10, 8, 10, 12 }, &.{ true, false, false, true, false, true, false, true, false }, &widths);
            try table.printRow(ctx.stdout, &widths, &.{ "Name", "Version", "Kind", "Interp", "ABI", "Target", "Resolver", "RuntimeHash", "Hash" });
            try table.printRule(ctx.stdout, &widths);
        }

        var count: usize = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            count += 1;
            const p_name = std.mem.span(c.sqlite3_column_text(stmt, 0));
            const version = std.mem.span(c.sqlite3_column_text(stmt, 1));
            const kind = std.mem.span(c.sqlite3_column_text(stmt, 2));
            const public_kind = if (std.mem.eql(u8, kind, "runtime")) "interpreter" else kind;
            const runtime = if (c.sqlite3_column_text(stmt, 3)) |r| std.mem.span(r) else "";
            const abi = if (c.sqlite3_column_text(stmt, 4)) |r| std.mem.span(r) else "";
            const target = if (c.sqlite3_column_text(stmt, 5)) |r| std.mem.span(r) else "";
            const resolver = if (c.sqlite3_column_text(stmt, 6)) |r| std.mem.span(r) else "";
            const runtime_hash = if (c.sqlite3_column_text(stmt, 7)) |r| std.mem.span(r) else "";
            const hash = std.mem.span(c.sqlite3_column_text(stmt, 8));

            if (emitter) |e| {
                try e.emit(ctx.io, .STATUS, p_name, "entry", .{
                    .name = p_name,
                    .version = version,
                    .kind = public_kind,
                    .runtime = runtime,
                    .lua_abi = abi,
                    .target = target,
                    .resolver = resolver,
                    .runtime_hash = runtime_hash,
                    .hash = hash,
                });
            } else {
                var widths: [9]usize = undefined;
                table.fitWidths(table.terminalWidth(ctx.env), &.{ 16, 10, 7, 8, 7, 10, 8, 10, 12 }, &.{ true, false, false, true, false, true, false, true, false }, &widths);
                const runtime_display = if (runtime.len > 0) runtime else "-";
                const abi_display = if (abi.len > 0) abi else "-";
                const target_display = if (target.len > 0) target else "-";
                const resolver_display = if (resolver.len > 0) resolver else "-";
                const runtime_hash_display = if (runtime_hash.len >= 12) runtime_hash[0..12] else if (runtime_hash.len > 0) runtime_hash else "-";
                const hash_display = if (hash.len >= 12) hash[0..12] else hash;
                try table.printRow(ctx.stdout, &widths, &.{ p_name, version, public_kind, runtime_display, abi_display, target_display, resolver_display, runtime_hash_display, hash_display });
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
        defer {
            var p = paths;
            p.deinit(allocator);
        }

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

    fn runInterpreters(self: StoreListCommand, ctx: *router.Context) !void {
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
        defer {
            var p = paths;
            p.deinit(allocator);
        }

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
