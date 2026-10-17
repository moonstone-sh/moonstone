const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const remove_command = struct {
    pub const name = "remove";
    pub const description = "Remove dependencies, unused runtimes, or registered links";

    positionals: []const []const u8 = &.{},
    lib: bool = false,
    bin: bool = false,
    runtime: bool = false,
    target: ?[]const u8 = null,
    dev: bool = false,
    tool: bool = false,
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
            \\  --global     Operate on global state
            \\  --tool       Remove a global or project tool dependency
            \\  --lib        Remove runtime library dependency
            \\  --bin        Deprecated alias for --tool
            \\  --runtime    Remove a custom installed runtime (requires --global)
            \\  --target <t> Select a runtime target to remove (requires --global)
            \\  --dev        Remove from dev-dependencies
            \\  --no-sync Do not run moon sync
            \\  --json       Emit newline-delimited JSON events
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
        var has_runtime = self.runtime;
        for (self.positionals) |spec| has_runtime = has_runtime or @import("runtime_spec.zig").isOfficial(spec);
        if (self.global and has_runtime) {
            if (self.positionals.len != 1 or self.tool or self.bin or self.lib or self.dev or self.no_sync or self.file != null) return error.UnsupportedRuntimeOption;
            return (@import("interpreter_remove.zig").InterpreterRemoveCommand{ .positionals = self.positionals, .target = self.target, .json = self.json }).run(ctx);
        }
        if (self.runtime or self.target != null) return error.UnsupportedRuntimeOption;
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
            var link_count: usize = 0;
            for (self.positionals) |spec| if (std.mem.startsWith(u8, spec, "link:")) {
                link_count += 1;
            };
            if (link_count > 0) {
                if (link_count != self.positionals.len or self.tool or self.bin or self.lib or self.dev or self.file != null or self.no_sync) return error.MixedGlobalRemoval;
                return self.runGlobal(ctx);
            }
            if (self.positionals.len == 0) return error.MissingArgument;
            if (self.lib or self.dev or self.file != null) return error.UnsupportedGlobalRemovalOption;
            var global_self = self;
            global_self.global = false;
            global_self.tool = true;
            global_self.bin = false;
            const global_project = try @import("global_tools.zig").enterProject(allocator, ctx.env, io);
            defer @import("global_tools.zig").leaveProject(allocator, io, global_project);
            if (!self.json) try stdout.print("Using global tools environment: {s}\n", .{global_project.path});
            return global_self.run(ctx);
        }

        if (self.positionals.len == 0) {
            ctx.error_detail = .{ .message = .{ .msg = "package names required." } };
            return error.MissingArgument;
        }

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{ .packages = self.positionals, .runtime = false });
        }

        const toml_path = self.file orelse "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        if (!self.tool and !self.bin) for (self.positionals) |spec| {
            const parsed = try moonstone.domain.package_spec.parsePackageSpec(allocator, spec);
            defer parsed.deinit(allocator);
            if (std.mem.eql(u8, moonstone.domain.package_spec.canonicalOfficialRuntime(parsed.name), moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName()))) {
                ctx.error_detail = .{ .message = .{ .msg = "This is the selected project runtime. Use `moon set RUNTIME@VERSION` to select its replacement; removal never chooses a fallback." } };
                return error.RuntimeStillSelected;
            }
        };

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
                    if ((self.bin or self.tool) and dep.role == .tool) {
                        remove = true;
                    } else if (self.lib and dep.role == .runtime) {
                        remove = true;
                    } else if (self.dev and dep.role == .dev) {
                        remove = true;
                    } else if (!self.bin and !self.tool and !self.lib and !self.dev) {
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

        if (removed_count > 0) {
            const serialized_manifest = try moonstone.project.manifest_editor.commit(allocator, io, &mt);
            defer allocator.free(serialized_manifest);

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

        // Validate the whole request before unregistering anything.
        for (self.positionals, 0..) |spec, index| {
            for (self.positionals[0..index]) |previous| if (std.mem.eql(u8, previous, spec)) return error.DuplicatePackage;
            const pkg_name = spec[5..];
            if (pkg_name.len == 0) return error.InvalidPackageSpec;
            var entry = (try lr.get(pkg_name)) orelse return error.LinkNotFound;
            entry.deinit(allocator);
        }
        for (self.positionals) |spec| {
            const pkg_name = spec[5..];
            var entry = (try lr.get(pkg_name)) orelse return error.LinkNotFound;
            defer entry.deinit(allocator);
            const prune = @import("store_prune.zig");
            const hash = if (entry.mode == .artifact) try prune.ownedArtifactHash(allocator, io, paths.store, entry.path) else null;
            defer if (hash) |h| allocator.free(h);
            try lr.unregister(pkg_name);
            if (hash) |h| try (prune.StorePruneCommand{}).runSelected(ctx, h, self.json);
            if (!self.json) try stdout.print("Unregistered '{s}'. Source files were preserved.\n", .{pkg_name});
        }
        if (self.json) {
            var emitter = ndjson.Emitter.init(allocator, stdout, "remove");
            try emitter.terminate(io, "links", "ok", .{ .unregistered = self.positionals });
        }
    }
};
