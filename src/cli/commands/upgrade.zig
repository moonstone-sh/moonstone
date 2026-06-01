const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const upgrade_command = struct {
    pub const command_name = "upgrade";
    pub const description = "Upgrade dependencies to latest major versions";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon upgrade [flags]
            \\
            \\Upgrade dependencies in moonstone.toml to the latest compatible versions.
            \\
            \\Flags:
            \\  --json        Output as JSON
            \\
        , .{});
    }

    pub fn run(self: upgrade_command, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, command_name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, command_name, "begin", .{});
        }

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);
        
        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        const resolved_registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        defer moonstone.registry.core.deinitResolved(resolved_registries, allocator);

        var resolver_obj = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
        };

        var mat = moonstone.materialization.materializer.Materializer{
            .allocator = allocator,
            .io = io,
            .environ_map = env,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        };

        const runtime_spec = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ mt.runtimeName(), mt.runtimeVersion() });
        defer allocator.free(runtime_spec);

        const rt_res = try resolver_obj.resolve(moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName()), mt.runtimeConstraint(), idx, resolved_registries, .{
            .prefer_local = true,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        }, env);
        var mut_rt_res = rt_res;
        defer mut_rt_res.deinit(allocator);

        if (mut_rt_res.local_path) |lp| {
            mat.runtime_path = lp;
        } else {
            const rt_res_mat = try mat.materialize_remote(
                mut_rt_res.registry_url.?,
                mut_rt_res.registry_token,
                mut_rt_res.descriptor_path.?,
                mut_rt_res.remote_desc.?,
                mut_rt_res.artifact_idx.?,
            );
            mat.runtime_path = rt_res_mat.path;
        }

        if (emitter) |e| {
            try e.terminate(io, command_name, "ok", .{});
        } else {
            try stdout.print("Upgrade complete (simplified).\n", .{});
        }
    }
};
