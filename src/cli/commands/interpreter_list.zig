const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const table = @import("../table.zig");

pub const InterpreterListCommand = struct {
    pub const name = "list";
    pub const description = "List installed or available Lua interpreters";

    installed: bool = false,
    available: bool = false,
    json: bool = false,
    target: ?[]const u8 = null,
    abi: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon interpreter list [flags]
            \\
            \\List Lua interpreters.
            \\
            \\Flags:
            \\  --installed    List interpreters currently in the store (default if no flags)
            \\  --available    List interpreters available for installation in registries
            \\  --target <t>   Filter installed interpreters by target triple
            \\  --abi <abi>    Filter installed interpreters by Lua ABI
            \\  --json         Output as JSON
            \\
        , .{});
    }

    pub fn run(self: InterpreterListCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;
        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, "interpreter-list") else null;
        const emitter = if (emitter_obj) |*e| e else null;
        if (emitter) |e| try e.emit(io, .START, "interpreter-list", "begin", .{ .installed = self.installed, .available = self.available });

        const show_installed = self.installed or (!self.installed and !self.available);
        const show_available = self.available;
        var count: usize = 0;

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        if (show_installed) {
            try std.Io.Dir.cwd().createDirPath(io, paths.index);
            const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
            defer allocator.free(index_db_path);
            const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
            defer allocator.free(index_db_path_z);

            var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
            defer idx.deinit();

            if (emitter == null) {
                try stdout.print("Installed interpreters:\n", .{});
                var widths: [6]usize = undefined;
                table.fitWidths(table.terminalWidth(env), &.{ 16, 10, 8, 12, 12, 12 }, &.{ true, false, false, true, true, false }, &widths);
                try table.printRow(stdout, &widths, &.{ "Name", "Version", "ABI", "Target", "InterpreterHash", "Hash" });
                try table.printRule(stdout, &widths);
            }

            const sql = "SELECT name, version, lua_abi, target, runtime_artifact_hash, artifact_hash FROM artifacts WHERE kind = 'runtime' AND (? IS NULL OR target = ?) AND (? IS NULL OR lua_abi = ?) ORDER BY name, version, target;";
            var stmt: ?*moonstone.store.driver.c.sqlite3_stmt = null;
            const c = moonstone.store.driver.c;
            if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
            defer _ = c.sqlite3_finalize(stmt);
            const transient = moonstone.store.driver.moonstone_sqlite_transient_ptr;
            bindNullable(stmt, 1, self.target, transient);
            bindNullable(stmt, 2, self.target, transient);
            bindNullable(stmt, 3, self.abi, transient);
            bindNullable(stmt, 4, self.abi, transient);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                count += 1;
                const r_name = std.mem.span(c.sqlite3_column_text(stmt, 0));
                const version = std.mem.span(c.sqlite3_column_text(stmt, 1));
                const abi = if (c.sqlite3_column_text(stmt, 2)) |v| std.mem.span(v) else "";
                const target = if (c.sqlite3_column_text(stmt, 3)) |v| std.mem.span(v) else "";
                const interpreter_hash = if (c.sqlite3_column_text(stmt, 4)) |v| std.mem.span(v) else "";
                const hash = std.mem.span(c.sqlite3_column_text(stmt, 5));
                if (emitter) |e| {
                    try e.emit(io, .STATUS, r_name, "installed", .{ .name = r_name, .version = version, .abi = abi, .target = target, .interpreter_hash = interpreter_hash, .hash = hash });
                } else {
                    var widths: [6]usize = undefined;
                    table.fitWidths(table.terminalWidth(env), &.{ 16, 10, 8, 12, 12, 12 }, &.{ true, false, false, true, true, false }, &widths);
                    const interpreter_hash_display = if (interpreter_hash.len >= 12) interpreter_hash[0..12] else if (interpreter_hash.len > 0) interpreter_hash else "-";
                    const hash_display = if (hash.len >= 12) hash[0..12] else hash;
                    try table.printRow(stdout, &widths, &.{ r_name, version, abi, target, interpreter_hash_display, hash_display });
                }
            }
        }

        if (show_available) {
            const registries = moonstone.registry.resolver.resolve(allocator, io, env) catch &.{};
            defer moonstone.registry.core.deinitResolved(@constCast(registries), allocator);
            if (emitter == null) try stdout.print("\nAvailable interpreters from registries:\n", .{});
            for (registries) |reg| {
                if (!std.mem.eql(u8, reg.resolver, "moonstone")) continue;
                var client = moonstone.registry.core.RegistryClient.init(allocator, io, reg.url, reg.token, env);
                defer client.deinit();
                const interpreters = client.list_runtimes(paths.cache) catch |err| {
                    if (emitter == null) try stdout.print("  Error querying registry {s}: {s}\n", .{ reg.url, @errorName(err) });
                    continue;
                };
                defer {
                    for (interpreters) |r| {
                        allocator.free(r.name);
                        allocator.free(r.version);
                    }
                    allocator.free(interpreters);
                }
                for (interpreters) |r| {
                    count += 1;
                    if (emitter) |e| try e.emit(io, .STATUS, r.name, "available", .{ .name = r.name, .version = r.version, .registry = reg.url }) else try stdout.print("  {s}@{s}  ({s})\n", .{ r.name, r.version, reg.url });
                }
            }
        }
        if (emitter) |e| try e.terminate(io, "interpreter-list", "ok", .{ .count = count });
    }
};

fn bindNullable(stmt: ?*moonstone.store.driver.c.sqlite3_stmt, index: c_int, value: ?[]const u8, transient: moonstone.store.driver.c.sqlite3_destructor_type) void {
    const c = moonstone.store.driver.c;
    if (value) |v| _ = c.sqlite3_bind_text(stmt, index, v.ptr, @intCast(v.len), transient) else _ = c.sqlite3_bind_null(stmt, index);
}
