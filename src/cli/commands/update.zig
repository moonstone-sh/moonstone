const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const update_command = struct {
    pub const command_name = "update";
    pub const description = "Update dependencies to latest versions allowed by moonstone.toml";

    positionals: []const []const u8 = &.{},
    locked: bool = false,
    outdated: bool = false,
    interactive: bool = false,
    dry_run: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon update [package]... [flags]
            \\
            \\Update dependencies in moonstone.lock according to version constraints
            \\in moonstone.toml.
            \\
            \\Arguments:
            \\  [package]     Specific package(s) to update (optional)
            \\
            \\Flags:
            \\  --outdated    List dependencies that have newer versions available
            \\  --interactive Pick updates manually via prompts
            \\  --dry-run     Show what would be updated without modifying files
            \\  --locked      Fail if the lockfile would be changed
            \\  --json        Output as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn run(self: update_command, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, command_name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, command_name, "begin", .{ .packages = self.positionals, .outdated_only = self.outdated, .interactive = self.interactive });
        }

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        const lock_path = "moonstone.lock";
        var lf = blk: {
            const lock_content = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) {
                    break :blk moonstone.domain.lockfile.LockFile.init(allocator);
                }
                return err;
            };
            defer allocator.free(lock_content);
            break :blk try moonstone.domain.lockfile.LockFile.parse(allocator, lock_content);
        };
        defer lf.deinit();

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);
        
        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        const registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        defer moonstone.registry.core.deinitResolved(registries, allocator);

        const concrete_abi = mt.runtimeAbi();

        var provider_impl = try allocator.create(moonstone.solver.registry_provider.RegistryProvider);
        provider_impl.init(
            allocator, io, idx, registries, .{
                .offline = false,
                .runtime = concrete_abi,
            }, env, null, &.{}, // update --outdated doesn't use explicit targets for all yet
        );
        defer {
            provider_impl.deinit();
            allocator.destroy(provider_impl);
        }

        var resolver_obj = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
        };

        const lua_rt_spec = mt.runtimeConstraint();
        const rt_res = try resolver_obj.resolve(moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName()), lua_rt_spec, idx, registries, .{
            .prefer_local = true,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        }, env);
        defer { var r = rt_res; r.deinit(allocator); }

        if (self.outdated or self.interactive or self.positionals.len > 0) {
            if (emitter == null) {
                try stdout.print("{s: <20} {s: <15} {s: <15} {s}\n", .{ "Package", "Current", "Latest", "Status" });
                try stdout.print("--------------------------------------------------------------------------------\n", .{});
            }

            var outdated_count: usize = 0;
            var updates_to_apply = std.ArrayList([]const u8).empty;
            defer {
                for (updates_to_apply.items) |u| allocator.free(u);
                updates_to_apply.deinit(allocator);
            }

            inline for (.{ "libs", "bins", "dev_libs", "dev_bins" }) |group_name| {
                const group = @field(mt.dependencies, group_name);
                var it = group.iterator();
                while (it.next()) |entry| {
                    const pkg_name = entry.key_ptr.*;
                    const ver_range = entry.value_ptr.*;

                    // If positionals provided, skip if not in the list
                    if (self.positionals.len > 0) {
                        var found = false;
                        for (self.positionals) |pos| {
                            const parsed = moonstone.domain.package_spec.parsePackageSpec(allocator, pos) catch continue;
                            defer parsed.deinit(allocator);
                            if (std.mem.eql(u8, parsed.name, pkg_name)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) continue;
                    }

                    const locked = lf.find(pkg_name);
                    const current_ver = if (locked) |l| l.version else "(unlocked)";

                    const latest_res = resolver_obj.resolve(pkg_name, ver_range, idx, registries, .{
                        .offline = false,
                        .runtime = concrete_abi,
                        .on_event = @import("command.zig").onResolveEvent,
                        .on_event_context = &resolve_cb_ctx,
                    }, env) catch continue;
                    defer { var r = latest_res; r.deinit(allocator); }

                    const is_outdated = if (locked) |l| blk: {
                        const cur = moonstone.domain.semver.Version.parse(l.version) catch break :blk true;
                        const lat = moonstone.domain.semver.Version.parse(latest_res.version) catch break :blk true;
                        break :blk lat.compare(cur) > 0;
                    } else true;

                    if (is_outdated) {
                        outdated_count += 1;
                        if (emitter) |e| {
                            try e.emit(io, .STATUS, pkg_name, "outdated", .{
                                .current = current_ver,
                                .latest = latest_res.version,
                            });
                        } else {
                            try stdout.print("{s: <20} {s: <15} {s: <15} OUTDATED\n", .{ pkg_name, current_ver, latest_res.version });
                        }

                        if ((self.interactive or self.positionals.len > 0) and emitter == null) {
                            var should_update = !self.interactive;
                            if (self.interactive) {
                                try stdout.print("  Update '{s}'? [y/N] ", .{pkg_name});
                                try stdout.flush();
                                
                                const stdin = std.Io.getStdIn();
                                var buf: [16]u8 = undefined;
                                const n = try stdin.read(io, &buf);
                                const input = std.mem.trim(u8, buf[0..n], " \t\r\n");
                                if (std.mem.eql(u8, input, "y") or std.mem.eql(u8, input, "Y")) {
                                    should_update = true;
                                }
                            }
                            
                            if (should_update) {
                                try updates_to_apply.append(allocator, try allocator.dupe(u8, pkg_name));
                            }
                        }
                    } else if (emitter == null and !self.interactive and self.positionals.len == 0) {
                        try stdout.print("{s: <20} {s: <15} {s: <15} up-to-date\n", .{ pkg_name, current_ver, latest_res.version });
                    }
                }
            }

            if ((self.interactive or self.positionals.len > 0) and updates_to_apply.items.len > 0) {
                if (emitter == null) try stdout.print("\nApplying {d} updates...\n", .{updates_to_apply.items.len});
                for (updates_to_apply.items) |pkg_name| {
                    if (lf.remove(pkg_name)) {}
                }
                
                if (!self.dry_run) {
                    const install = @import("sync.zig").sync_command{ .json = self.json };
                    try install.run(ctx);
                } else {
                    if (emitter == null) try stdout.print("Dry-run: would have updated {d} packages.\n", .{updates_to_apply.items.len});
                }
            }

            if (emitter) |e| {
                try e.terminate(io, command_name, "ok", .{ .outdated_count = outdated_count });
            } else if (outdated_count == 0) {
                try stdout.print("\nAll dependencies are up-to-date.\n", .{});
            }
            return;
        }

        // Real update: solve again and run sync
        if (!self.dry_run) {
            if (!self.json) try stdout.print("Updating moonstone.lock and synchronizing...\n", .{});
            // We just need to run sync without --locked to update the lockfile
            const install = @import("sync.zig").sync_command{ .json = self.json };
            try install.run(ctx);
        } else {
            try stdout.print("Dry-run: would update moonstone.lock and run sync.\n", .{});
        }

        if (emitter) |e| {
            try e.terminate(io, command_name, "ok", .{});
        }
    }
};
