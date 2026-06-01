const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const StoreDriverRebuildCommand = struct {
    pub const name = "rebuild";
    pub const description = "Rebuild the local metadata index from store artifacts";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon index rebuild [flags]
            \\
            \\Scan the local content store and rebuild the SQLite index.
            \\
            \\Flags:
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: StoreDriverRebuildCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

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

        // 1. Wipe existing providing tables
        try idx.clear_all_data();

        // 2. Walk the store and find manifest.toml files
        if (!self.json) try stdout.print("Scanning store for artifacts...\n", .{});
        
        const store_path = paths.store;
        const b3_path = try std.fs.path.join(allocator, &.{ store_path, "b3" });
        defer allocator.free(b3_path);

        var b3_dir = std.Io.Dir.cwd().openDir(io, b3_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                if (!self.json) try stdout.print("Store is empty.\n", .{});
                return;
            }
            return err;
        };
        defer b3_dir.close(io);

        var count: usize = 0;
        var it0 = b3_dir.iterate();
        while (try it0.next(io)) |e0| {
            if (e0.kind != .directory) continue;
            const p0 = try std.fs.path.join(allocator, &.{ b3_path, e0.name });
            defer allocator.free(p0);
            var d0 = std.Io.Dir.cwd().openDir(io, p0, .{ .iterate = true }) catch continue;
            defer d0.close(io);

            var it1 = d0.iterate();
            while (try it1.next(io)) |e1| {
                if (e1.kind != .directory) continue;
                const p1 = try std.fs.path.join(allocator, &.{ p0, e1.name });
                defer allocator.free(p1);
                var d1 = std.Io.Dir.cwd().openDir(io, p1, .{ .iterate = true }) catch continue;
                defer d1.close(io);

                var it2 = d1.iterate();
                while (try it2.next(io)) |e2| {
                    if (e2.kind != .directory) continue;
                    const art_path = try std.fs.path.join(allocator, &.{ p1, e2.name });
                    defer allocator.free(art_path);

                    const manifest_path = try std.fs.path.join(allocator, &.{ art_path, "manifest.toml" });
                    defer allocator.free(manifest_path);

                    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
                    defer allocator.free(content);

                    var manifest = moonstone.domain.manifest.StoreManifest.parse(allocator, content) catch continue;
                    defer manifest.deinit(allocator);

                    try idx.register_artifact(
                        allocator,
                        manifest,
                        art_path,
                        manifest_path,
                    );
                    count += 1;
                }
            }
        }

        if (!self.json) {
            try stdout.print("Rebuild complete. {d} artifacts indexed.\n", .{count});
        }
    }
};
