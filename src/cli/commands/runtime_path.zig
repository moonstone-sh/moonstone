const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const RuntimePathCommand = struct {
    pub const name = "path";
    pub const description = "Derive path to a runtime";

    positionals: []const []const u8 = &.{},
    current: bool = false,
    bin: bool = false,
    include: bool = false,
    lib: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon runtime path [spec] [flags]
            \\
            \\Print paths associated with a Lua runtime.
            \\
            \\Arguments:
            \\  [spec]        Runtime version spec (e.g. 5.4, 5.1.5)
            \\
            \\Flags:
            \\  --current     Use the current project's runtime
            \\  --bin         Path to the 'bin' directory (e.g. where lua executable lives)
            \\  --include     Path to the 'include' directory
            \\  --lib         Path to the 'lib' directory
            \\  --json        Output as JSON
            \\
        , .{});
    }

    pub fn run(self: RuntimePathCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var path: ?[]const u8 = null;
        defer if (path) |p| allocator.free(p);

        if (self.current) {
            const project_root = std.process.currentPathAlloc(io, allocator) catch |err| {
                try stdout.print("Error: could not get current directory: {s}\n", .{@errorName(err)});
                return err;
            };
            defer allocator.free(project_root);

            const env_path = try std.fs.path.join(allocator, &.{ project_root, ".moonstone", "env" });
            defer allocator.free(env_path);

            if (std.Io.Dir.cwd().access(io, env_path, .{})) |_| {
                path = try allocator.dupe(u8, env_path);
            } else |_| {
                try stdout.print("Error: current project environment not found at {s}. Run `moon sync` first.\n", .{env_path});
                return error.EnvironmentNotFound;
            }
        } else if (self.positionals.len > 0) {
            const spec = self.positionals[0];
            const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
            defer { var p = paths; p.deinit(allocator); }

            const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
            defer allocator.free(index_db_path);
            const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
            defer allocator.free(index_db_path_z);

            var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
            defer idx.deinit();

            const registries = try moonstone.registry.resolver.resolve(allocator, io, env);
            defer moonstone.registry.core.deinitResolved(registries, allocator);

            var resolver = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
            const resolved = try resolver.resolve(moonstone.domain.package_spec.canonicalOfficialRuntime("lua"), spec, idx, registries, .{
                .offline = true,
                .prefer_local = true,
            }, env);
            var mut_resolved = resolved;
            defer mut_resolved.deinit(allocator);

            if (mut_resolved.local_path) |lp| {
                path = try allocator.dupe(u8, lp);
            } else {
                try stdout.print("Error: runtime {s} not found in local store. Run `moon runtime install {s}` first.\n", .{ spec, spec });
                return error.RuntimeNotFound;
            }
        } else {
            return error.MissingArgument;
        }

        if (path) |base_path| {
            var final_path: []const u8 = try allocator.dupe(u8, base_path);
            defer allocator.free(final_path);

            const is_project_env = std.mem.endsWith(u8, base_path, ".moonstone/env");

            if (self.bin) {
                const sub = if (is_project_env)
                    try std.fs.path.join(allocator, &.{ base_path, "bin" })
                else
                    try std.fs.path.join(allocator, &.{ base_path, "files", "bin" });
                allocator.free(final_path);
                final_path = sub;
            } else if (self.include) {
                const sub = if (is_project_env)
                    try std.fs.path.join(allocator, &.{ base_path, "include" })
                else
                    try std.fs.path.join(allocator, &.{ base_path, "files", "include" });
                allocator.free(final_path);
                final_path = sub;
            } else if (self.lib) {
                const sub = if (is_project_env)
                    try std.fs.path.join(allocator, &.{ base_path, "lib" })
                else
                    try std.fs.path.join(allocator, &.{ base_path, "files", "lib" });
                allocator.free(final_path);
                final_path = sub;
            }


            if (self.json) {
                try stdout.print("{{\"path\": \"{s}\"}}\n", .{final_path});
            } else {
                try stdout.print("{s}\n", .{final_path});
            }
        }
    }
};
