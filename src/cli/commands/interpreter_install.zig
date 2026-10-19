const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const InterpreterInstallCommand = struct {
    pub const name = "install";
    pub const description = "Install a Lua interpreter";

    positionals: []const []const u8 = &.{},
    target: ?[]const u8 = null,
    json: bool = false,
    offline: bool = false,
    dry_run: bool = false,
    prefer_local: bool = false,
    registry: ?[]const u8 = null,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon add --global [flags] <spec>
            \\
            \\Installs a Lua interpreter from a registry.
            \\
            \\Arguments:
            \\  <spec>        Interpreter spec (e.g. lua@5.4, luajit@2.1)
            \\
            \\Flags:
            \\  --target <t>  Target triple
            \\  --registry <r> Force use of specific registry URL
            \\
        , .{});
    }

    pub fn run(self: InterpreterInstallCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        if (self.positionals.len != 1) return error.MissingArgument;
        const spec = self.positionals[0];

        var emitter_obj = if (self.json) @import("ndjson.zig").Emitter.init(allocator, stdout, "add") else null;
        const emitter = if (emitter_obj) |*value| value else null;
        if (self.dry_run) {
            if (emitter) |e| try e.terminate(io, spec, "planned", .{ .runtime = true, .global = true, .target = self.target }) else try stdout.print("Would install global runtime {s}; selection is unchanged.\n", .{spec});
            return;
        }
        if (emitter) |e| try e.emit(io, .START, spec, "begin", .{ .runtime = true, .global = true }) else try stdout.print("Adding runtime: {s}...\n", .{spec});

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

        const registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        defer moonstone.registry.core.deinitResolved(registries, allocator);

        var resolver = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
        var pkg_name = spec;
        var pkg_ver: []const u8 = "*";
        if (std.mem.lastIndexOfScalar(u8, spec, '@')) |pos| {
            pkg_name = spec[0..pos];
            pkg_ver = spec[pos + 1 ..];
        }
        pkg_name = moonstone.domain.package_spec.canonicalOfficialRuntime(pkg_name);

        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
            .is_tty = !self.json and @import("../progress.zig").supportsInteractive(io, env, false),
            .env = env,
            .use_stderr = false,
        };

        var final_res = if (self.registry) |reg_url| blk: {
            if (self.offline) return error.OfflineMode;
            const res = try resolver.resolve_remote(pkg_name, pkg_ver, reg_url, null, .{
                .target = self.target,
                .on_event = @import("command.zig").onResolveEvent,
                .on_event_context = &resolve_cb_ctx,
            }, env);
            break :blk moonstone.resolution.candidate.Candidate{
                .name = try allocator.dupe(u8, res.desc.package.name),
                .version = try allocator.dupe(u8, res.desc.package.version),
                .kind = res.desc.package.kind,
                .artifact_hash = try allocator.dupe(u8, res.desc.artifact[res.artifact_idx].hash),
                .origin = .{
                    .moonstone_registry = .{
                        .url = try allocator.dupe(u8, reg_url),
                        .token = null,
                        .descriptor_path = try allocator.dupe(u8, res.descriptor_path),
                        .artifact_idx = res.artifact_idx,
                    },
                },
                .remote_desc = res.desc,
            };
        } else try resolver.resolve(pkg_name, pkg_ver, idx, registries, .{
            .offline = self.offline,
            .prefer_local = self.prefer_local,
            .target = self.target,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        }, env);
        defer final_res.deinit(allocator);

        if (final_res.kind != .runtime) return error.ExpectedRuntimePackage;
        if (!self.json) try stdout.print("Resolved to {s}@{s}\n", .{ final_res.name, final_res.version });

        var mat = moonstone.materialization.materializer.Materializer{
            .allocator = allocator,
            .io = io,
            .environ_map = env,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        };

        const mat_res = switch (final_res.location) {
            .local_store, .local_path => moonstone.materialization.materializer.MaterializeResult{
                .path = try allocator.dupe(u8, final_res.local_path.?),
                .artifact_hash = try allocator.dupe(u8, final_res.artifact_hash),
            },
            .remote => switch (final_res.origin) {
                .moonstone_registry => |r| try mat.materialize_remote(
                    r.url,
                    r.token,
                    r.descriptor_path,
                    final_res.remote_desc.?,
                    r.artifact_idx,
                ),
                else => return error.UnsupportedOriginForInterpreter,
            },
        };
        defer mat_res.deinit(allocator);
        if (try idx.get_provision_runtime(mat_res.artifact_hash)) |provision| {
            var mutable = provision;
            mutable.deinit(allocator);
        } else {
            ctx.error_detail = .{ .message = .{ .msg = "The runtime package does not declare a runtime provision. Correct its descriptor before selecting it." } };
            return error.RuntimeProvisionMissing;
        }

        if (emitter) |e| try e.terminate(io, final_res.name, "ok", .{ .version = final_res.version, .path = mat_res.path, .runtime = true, .global = true }) else try stdout.print("Runtime installed to {s}. Select it with `moon set`.\n", .{mat_res.path});
    }
};
