const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const remove_command = struct {
    pub const name = "remove";
    pub const description = "Remove dependencies or unregister links";

    positionals: []const []const u8 = &.{},
    lib: bool = false,
    bin: bool = false,
    runtime: bool = false,
    dev: bool = false,
    global: bool = false,
    no_sync: bool = false,
    file: ?[]const u8 = null,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon remove <package>... [flags]
            \\
            \\Remove dependencies from moonstone.toml or unregister global links.
            \\
            \\Arguments:
            \\  <package>    Name of the package(s) to remove
            \\
            \\Flags:
            \\  --global     Unregister from the global link registry instead of current project
            \\  --lib        Remove runtime library dependency
            \\  --bin        Remove tool dependency
            \\  --runtime    Remove project runtime (sets to default)
            \\  --dev        Remove from dev-dependencies
            \\  --no-sync Do not run moon sync
            \\  --json       Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        _ = args;
        var list = std.ArrayList([]const u8).empty;

        // 1. Suggest from moonstone.toml
        const toml_path = "moonstone.toml";
        if (std.Io.Dir.cwd().readFileAlloc(ctx.io, toml_path, ctx.allocator, std.Io.Limit.limited(1024 * 1024))) |content| {
            defer ctx.allocator.free(content);
            if (moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content)) |mt| {
                defer {
                    var m = mt;
                    m.deinit(ctx.allocator);
                }
                for (mt.dependencies.items) |dep| {
                    try list.append(ctx.allocator, try ctx.allocator.dupe(u8, dep.name));
                }
            } else |_| {}
        } else |_| {}

        // 2. Suggest from global links if --global might be intended
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

        if (moonstone.store.driver.StoreDriver.init(ctx.allocator, index_db_path_z)) |idx| {
            defer {
                var i = idx;
                i.deinit();
            }
            const lr = moonstone.store.links.LinkStore.init(@constCast(&idx));
            if (lr.list()) |entries| {
                defer {
                    for (entries) |*e| e.deinit(ctx.allocator);
                    ctx.allocator.free(entries);
                }
                for (entries) |entry| {
                    try list.append(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "link:{s}", .{entry.name}));
                }
            } else |_| {}
        } else |_| {}

        return list.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: remove_command, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        if (!self.global) {
            const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
            defer project_root.deinit(allocator);
        }

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (self.global) {
            try self.runGlobal(ctx);
            return;
        }

        if (self.positionals.len == 0 and !self.runtime) {
            ctx.error_detail = .{ .message = .{ .msg = "package names or --runtime required." } };
            return error.MissingArgument;
        }

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{ .packages = self.positionals, .runtime = self.runtime });
        }

        const toml_path = self.file orelse "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        var removed_count: usize = 0;
        var removed_list = std.ArrayList([]const u8).empty;
        defer {
            for (removed_list.items) |s| allocator.free(s);
            removed_list.deinit(allocator);
        }

        for (self.positionals) |pkg_spec| {
            const parsed = try moonstone.domain.package_spec.parsePackageSpec(allocator, pkg_spec);
            defer parsed.deinit(allocator);
            const pkg_name = parsed.name;

            var i: usize = 0;
            while (i < mt.dependencies.items.len) {
                var dep = mt.dependencies.items[i];
                if (std.mem.eql(u8, dep.name, pkg_name)) {
                    var remove = false;
                    if (self.bin and dep.role == .tool) {
                        remove = true;
                    } else if (self.lib and dep.role == .runtime) {
                        remove = true;
                    } else if (self.dev and dep.role == .dev) {
                        remove = true;
                    } else if (!self.bin and !self.lib and !self.dev) {
                        remove = true;
                    }

                    if (remove) {
                        try removed_list.append(allocator, try allocator.dupe(u8, pkg_name));
                        dep.deinit(allocator);
                        _ = mt.dependencies.orderedRemove(i);
                        removed_count += 1;
                        continue;
                    }
                }
                i += 1;
            }
        }

        if (self.runtime) {
            allocator.free(mt.runtime.name);
            allocator.free(mt.runtime.version);
            allocator.free(mt.runtime.abi);
            mt.runtime.name = try allocator.dupe(u8, "lua");
            mt.runtime.version = try allocator.dupe(u8, "5.4");
            mt.runtime.abi = try allocator.dupe(u8, "5.4");
            try removed_list.append(allocator, try allocator.dupe(u8, "runtime:lua"));
            removed_count += 1;
        }

        if (removed_count > 0) {
            const toml_file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
            defer toml_file.close(io);

            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try mt.serialize(allocator, &aw.writer);
            try aw.writer.flush();
            try toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

            if (emitter) |e| {
                try e.terminate(io, name, "ok", .{ .removed = removed_list.items, .env_regenerated = !self.no_sync });
            } else {
                try stdout.print("Removed {d} dependencies from {s}.\n", .{ removed_count, toml_path });
            }

            if (!self.no_sync) {
                const install = @import("sync.zig").sync_command{ .json = self.json };
                try install.run(ctx);
            }
        } else {
            if (emitter) |e| {
                try e.terminate(io, name, "no-op", .{});
            } else {
                try stdout.print("No matching dependencies found to remove.\n", .{});
            }
        }
    }

    fn runGlobal(self: remove_command, ctx: *router.Context) !void {
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

        var lr = moonstone.store.links.LinkStore.init(&idx);

        if (self.positionals.len == 0) {
            // Unregister current project
            const toml_content = try std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024));
            defer allocator.free(toml_content);
            var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, toml_content);
            defer mt.deinit(allocator);

            try lr.unregister(mt.package.name);
            if (!self.json) try stdout.print("Unregistered '{s}' from global link registry.\n", .{mt.package.name});
        } else {
            for (self.positionals) |pkg_spec| {
                var pkg_name = pkg_spec;
                if (std.mem.startsWith(u8, pkg_spec, "link:")) {
                    pkg_name = pkg_spec[5..];
                }
                try lr.unregister(pkg_name);
                if (!self.json) try stdout.print("Unregistered '{s}' from global link registry.\n", .{pkg_name});
            }
        }
    }
};
