const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const RuntimeListCommand = struct {
    pub const name = "list";
    pub const description = "List installed or available runtimes";

    installed: bool = false,
    available: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon runtime list [flags]
            \\
            \\List Lua runtimes.
            \\
            \\Flags:
            \\  --installed    List runtimes currently in the store (default if no flags)
            \\  --available    List runtimes available for installation in registries
            \\  --json         Output as JSON
            \\
        , .{});
    }

    pub fn run(self: RuntimeListCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const show_installed = self.installed or (!self.installed and !self.available);
        const show_available = self.available;

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        if (show_installed) {
            try std.Io.Dir.cwd().createDirPath(io, paths.index);
            const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
            defer allocator.free(index_db_path);
            const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
            defer allocator.free(index_db_path_z);

            var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
            defer idx.deinit();

            if (!self.json) try stdout.print("Installed runtimes:\n", .{});
            const sql = "SELECT name, version, lua_abi, artifact_hash FROM artifacts WHERE kind = 'runtime' ORDER BY name, version;";
            var stmt: ?*moonstone.store.driver.c.sqlite3_stmt = null;
            const c = moonstone.store.driver.c;
            if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) == c.SQLITE_OK) {
                defer _ = c.sqlite3_finalize(stmt);
                while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    const r_name = std.mem.span(c.sqlite3_column_text(stmt, 0));
                    const version = std.mem.span(c.sqlite3_column_text(stmt, 1));
                    const abi = std.mem.span(c.sqlite3_column_text(stmt, 2));
                    const hash = std.mem.span(c.sqlite3_column_text(stmt, 3));
                    if (!self.json) {
                        try stdout.print("  {s}@{s: <10} (abi: {s})  [{s}]\n", .{ r_name, version, abi, hash[0..12] });
                    }
                }
            }
        }

        if (show_available) {
            const registries = moonstone.registry.resolver.resolve(allocator, io, env) catch &. {};
            defer moonstone.registry.core.deinitResolved(@constCast(registries), allocator);

            const cache_dir = blk: {
                const home_c = env.get("MOONSTONE_HOME") orelse env.get("HOME");
                if (home_c) |h| {
                    break :blk try std.fs.path.join(allocator, &.{ h, ".cache", "moonstone" });
                }
                break :blk null;
            };
            defer if (cache_dir) |cd| allocator.free(cd);

            if (!self.json) try stdout.print("\nAvailable runtimes from registries:\n", .{});
            
            for (registries) |reg| {
                var client = moonstone.registry.core.RegistryClient.init(allocator, io, reg.url, reg.token, env);
                defer client.deinit();

                if (cache_dir) |cd| {
                    const runtimes = client.list_runtimes(cd) catch |err| {
                        if (!self.json) try stdout.print("  Error querying registry {s}: {s}\n", .{ reg.url, @errorName(err) });
                        continue;
                    };
                    defer {
                        for (runtimes) |r| {
                            allocator.free(r.name);
                            allocator.free(r.version);
                        }
                        allocator.free(runtimes);
                    }

                    for (runtimes) |r| {
                        if (!self.json) {
                            try stdout.print("  {s}@{s: <10} (from {s})\n", .{ r.name, r.version, reg.url });
                        }
                    }
                }
            }
        }
    }
};
