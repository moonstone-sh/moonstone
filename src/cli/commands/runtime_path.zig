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
    target: ?[]const u8 = null,

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
            \\  --target <t>  Filter by target platform
            \\  --json        Output detailed metadata as JSON
            \\
        , .{});
    }

    pub fn run(self: RuntimePathCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var artifact_meta: ?struct {
            name: []const u8,
            version: []const u8,
            target: []const u8,
            artifact_hash: []const u8,
            lua_abi: []const u8,
            path: []const u8,
        } = null;
        defer if (artifact_meta) |*meta| {
            allocator.free(meta.name);
            allocator.free(meta.version);
            allocator.free(meta.target);
            allocator.free(meta.artifact_hash);
            allocator.free(meta.lua_abi);
            allocator.free(meta.path);
        };

        if (self.current) {
            const project_root = std.process.currentPathAlloc(io, allocator) catch |err| {
                try stdout.print("Error: could not get current directory: {s}\n", .{@errorName(err)});
                return err;
            };
            defer allocator.free(project_root);

            const env_toml_path = try std.fs.path.join(allocator, &.{ project_root, ".moonstone", "env", "env.toml" });
            defer allocator.free(env_toml_path);

            const content = std.Io.Dir.cwd().readFileAlloc(io, env_toml_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) {
                    try stdout.print("Error: project environment not found. Run `moon sync` first.\n", .{});
                    return error.EnvironmentNotFound;
                }
                return err;
            };
            defer allocator.free(content);

            var parser = @import("toml").Parser(@import("toml").Table).init(allocator);
            defer parser.deinit();
            var res = try parser.parseString(content);
            defer res.deinit();

            const rt_table = res.value.get("runtime").?.table;
            const rt_name = rt_table.get("name").?.string;
            const rt_ver = rt_table.get("version").?.string;

            // Resolve real artifact metadata from bin/lua link
            const bin_lua_path = try std.fs.path.join(allocator, &.{ project_root, ".moonstone", "env", "bin", "lua" });
            defer allocator.free(bin_lua_path);
            
            var link_buf: [std.posix.PATH_MAX]u8 = undefined;
            const link_len = std.Io.Dir.readLinkAbsolute(io, bin_lua_path, &link_buf) catch |err| blk: {
                if (err == error.NotLink) {
                    // Not a link, maybe standalone?
                    break :blk @as(usize, 0);
                }
                return err;
            };
            const target = link_buf[0..link_len];

            // Extract hash from path
            const hash_suffix = if (std.mem.indexOf(u8, target, "/store/v0/b3/")) |pos| blk: {
                const sub = target[pos + 13..];
                if (std.mem.indexOfScalar(u8, sub, '/')) |slash_pos| {
                    break :blk sub[0..slash_pos];
                }
                break :blk "";
            } else "";

            const art_hash = if (hash_suffix.len > 0) blk: {
                const dash_pos = std.mem.indexOfScalar(u8, hash_suffix, '-') orelse hash_suffix.len;
                break :blk try std.fmt.allocPrint(allocator, "b3:{s}", .{hash_suffix[0..dash_pos]});
            } else try allocator.dupe(u8, "unknown");
            defer allocator.free(art_hash);

            const art_path = if (std.mem.indexOf(u8, target, "/files/")) |pos| target[0..pos] else target;

            artifact_meta = .{
                .name = try allocator.dupe(u8, rt_name),
                .version = try allocator.dupe(u8, rt_ver),
                .target = try allocator.dupe(u8, "native"), // current project is always native
                .artifact_hash = try allocator.dupe(u8, art_hash),
                .lua_abi = try allocator.dupe(u8, rt_table.get("abi").?.string),
                .path = try allocator.dupe(u8, art_path),
            };

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
                .target = self.target,
            }, env);
            var mut_resolved = resolved;
            defer mut_resolved.deinit(allocator);

            if (mut_resolved.local_path) |lp| {
                // Get full meta from store driver by hash
                if (try idx.get_candidate_by_hash(mut_resolved.artifact_hash)) |cand| {
                    var mut_cand = cand;
                    defer mut_cand.deinit(allocator);
                    artifact_meta = .{
                        .name = try allocator.dupe(u8, mut_cand.name),
                        .version = try allocator.dupe(u8, mut_cand.version),
                        .target = try allocator.dupe(u8, self.target orelse "native"),
                        .artifact_hash = try allocator.dupe(u8, mut_cand.artifact_hash),
                        .lua_abi = try allocator.dupe(u8, mut_cand.lua_abi orelse "unknown"),
                        .path = try allocator.dupe(u8, lp),
                    };
                }
            } else {
                try stdout.print("Error: runtime {s} not found in local store for target {s}.\n", .{ spec, self.target orelse "native" });
                return error.RuntimeNotFound;
            }
        } else {
            return error.MissingArgument;
        }

        if (artifact_meta) |meta| {
            if (self.json) {
                const bin_rel = try std.fs.path.join(allocator, &.{ "bin", meta.name });
                defer allocator.free(bin_rel);
                const abs_bin = try std.fs.path.join(allocator, &.{ meta.path, "files", bin_rel });
                defer allocator.free(abs_bin);

                try stdout.print(
                    \\{{
                    \\  "name": "{s}",
                    \\  "version": "{s}",
                    \\  "target": "{s}",
                    \\  "lua_abi": "{s}",
                    \\  "artifact_hash": "{s}",
                    \\  "path": "{s}",
                    \\  "bin": "{s}"
                    \\}}
                    \\
                , .{ meta.name, meta.version, meta.target, meta.lua_abi, meta.artifact_hash, meta.path, abs_bin });
            } else {
                var final_path: []const u8 = try allocator.dupe(u8, meta.path);
                defer allocator.free(final_path);

                if (self.bin) {
                    const sub = try std.fs.path.join(allocator, &.{ meta.path, "files", "bin" });
                    allocator.free(final_path);
                    final_path = sub;
                } else if (self.include) {
                    const sub = try std.fs.path.join(allocator, &.{ meta.path, "files", "include" });
                    allocator.free(final_path);
                    final_path = sub;
                } else if (self.lib) {
                    const sub = try std.fs.path.join(allocator, &.{ meta.path, "files", "lib" });
                    allocator.free(final_path);
                    final_path = sub;
                }

                try stdout.print("{s}\n", .{final_path});
            }
        }
    }
};
