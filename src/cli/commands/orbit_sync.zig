const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");
const progress_runtime = @import("../progress.zig");
const task_protocol = @import("../task_protocol.zig");
const sync_command = @import("sync.zig").sync_command;

pub const OrbitSyncCommand = struct {
    pub const name = "sync";
    pub const description = "Sync configured orbits";

    json: bool = false,
    locked: bool = false,
    update: bool = false,
    offline: bool = false,
    quiet: bool = false,
    progress_arg: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit sync [<orbit-name-or-path>] [flags]
            \\
            \\Synchronize one or all configured orbits.
            \\
            \\Flags:
            \\  --locked  Require moonstone.lock to be up-to-date
            \\  --update  Refresh the orbit lockfile within declared constraints
            \\  --offline Resolve from the local store and configured file registries only
            \\  --progress <mode>  Human output: auto, fancy, or plain
            \\  --quiet  Suppress human output; use exit status only
            \\  --json    Output results as JSON
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        _ = args;
        const project_root = moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".") catch return &.{};
        defer project_root.deinit(ctx.allocator);
        const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch return &.{};
        defer ctx.allocator.free(content);
        var mt = moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content) catch return &.{};
        defer mt.deinit(ctx.allocator);

        const orbits = moonstone.project.orbits.resolveOrbits(ctx.allocator, ctx.io, project_root.path, &mt) catch return &.{};
        defer {
            for (orbits) |*o| o.deinit(ctx.allocator);
            ctx.allocator.free(orbits);
        }

        var list = std.ArrayList([]const u8).empty;
        for (orbits) |orbit| {
            try list.append(ctx.allocator, try ctx.allocator.dupe(u8, orbit.name));
        }
        return list.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: OrbitSyncCommand, ctx: *router.Context) !void {
        if (self.quiet and (self.json or self.progress_arg != null)) return error.InvalidOutputMode;
        if (self.json and self.progress_arg != null) return error.InvalidOutputMode;
        if (self.progress_arg) |mode| {
            if (!std.mem.eql(u8, mode, "auto") and !std.mem.eql(u8, mode, "fancy") and !std.mem.eql(u8, mode, "plain")) {
                return error.InvalidOutputMode;
            }
        }
        if (self.json) {
            return self.runImpl(ctx, .{ .direct = ctx.stdout });
        }
        if (self.quiet) return self.runImpl(ctx, .silent);
        if (self.progress_arg != null and std.mem.eql(u8, self.progress_arg.?, "plain")) {
            return self.runImpl(ctx, .{ .direct = ctx.stderr });
        }
        const force_fancy = self.progress_arg != null and std.mem.eql(u8, self.progress_arg.?, "fancy");
        if (!force_fancy and (ctx.env.get("CI") != null or ctx.env.get("MOONSTONE_NO_PROGRESS") != null)) {
            return self.runImpl(ctx, .{ .direct = ctx.stderr });
        }

        var data = SyncWorkData{ .cmd = self, .ctx = ctx };
        progress_runtime.runWithProgress(ctx.io, ctx.stderr, ctx.allocator, ctx.env, orbitSyncWorker, &data) catch |err| {
            if (data.error_detail) |detail| {
                ctx.error_detail = detail;
            }
            return err;
        };
    }

    pub fn runImpl(self: OrbitSyncCommand, ctx: *router.Context, backend: progress_runtime.ProgressBackend) !void {
        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        var emitter_obj = if (self.json) ndjson.Emitter.init(ctx.allocator, ctx.stdout, "orbit-sync") else null;
        const emitter = if (emitter_obj) |*e| e else null;
        const wctx = switch (backend) {
            .queue => |value| value,
            .direct, .silent => null,
        };
        // Direct is the effective plain backend for JSON-free output, including
        // CI/MOONSTONE_NO_PROGRESS selection. Keep orbit task transitions
        // durable without allowing terminal control sequences through.
        const effective_plain = !self.json and switch (backend) {
            .direct => true,
            .queue, .silent => false,
        };
        const plain_task_writer: ?*std.Io.Writer = if (effective_plain) switch (backend) {
            .direct => |writer| writer,
            .queue, .silent => null,
        } else null;
        const task_reporter = task_protocol.Reporter{
            .emitter = emitter,
            .wctx = wctx,
            .plain_writer = plain_task_writer,
        };

        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, toml_path, ctx.allocator, std.Io.Limit.limited(1024 * 1024));
        defer ctx.allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
        defer mt.deinit(ctx.allocator);

        if (emitter) |e| try e.emit(ctx.io, .START, "orbit-sync", "begin", .{});

        const orbits = try moonstone.project.orbits.resolveOrbits(ctx.allocator, ctx.io, project_root.path, &mt);
        defer {
            for (orbits) |*o| o.deinit(ctx.allocator);
            ctx.allocator.free(orbits);
        }

        var target_orbits = std.ArrayList(moonstone.project.orbits.OrbitRef).empty;
        defer target_orbits.deinit(ctx.allocator);

        if (self.positionals.len > 0) {
            const target = self.positionals[0];
            const target_abs = try std.fs.path.resolve(ctx.allocator, &.{ project_root.path, target });
            defer ctx.allocator.free(target_abs);

            for (orbits) |orbit| {
                if (std.mem.eql(u8, orbit.name, target) or
                    std.mem.eql(u8, orbit.package_name, target) or
                    std.mem.eql(u8, orbit.path, target_abs))
                {
                    try target_orbits.append(ctx.allocator, orbit);
                }
            }
            if (target_orbits.items.len == 0) {
                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                ctx.error_detail = .{ .orbit_not_found = .{ .orbit = try ctx.allocator.dupe(u8, target) } };
                return error.OrbitNotFound;
            }
        } else {
            try target_orbits.appendSlice(ctx.allocator, orbits);
        }

        if (!self.json and !self.quiet) backend.phase("Discovered {d} orbits.", .{orbits.len});

        // project_root.path is already the absolute path of the root
        const root_cwd = project_root.path;

        for (target_orbits.items) |orbit| {
            if (!self.json and !self.quiet) backend.phase("Syncing orbit {s}...", .{orbit.name});

            var task_buffer: [384]u8 = undefined;
            const task_id = try task_protocol.formatOrbitSyncId(&task_buffer, orbit.name);
            task_reporter.report(ctx.io, task_id, 1, "running", orbit.name, .{
                .orbit = orbit.name,
                .path = orbit.path,
            });

            try std.process.setCurrentPath(ctx.io, orbit.path);

            var child_sync = sync_command{
                .locked = self.locked,
                .update = self.update,
                .offline = self.offline,
            };
            child_sync.runImpl(ctx, .silent) catch |err| {
                std.process.setCurrentPath(ctx.io, root_cwd) catch {};
                captureChildSyncFailure(ctx, orbit, err);
                task_reporter.report(ctx.io, task_id, 2, "failed", @errorName(err), .{
                    .orbit = orbit.name,
                    .error_name = @errorName(err),
                });
                return err;
            };
            try std.process.setCurrentPath(ctx.io, root_cwd);
            task_reporter.report(ctx.io, task_id, 2, "completed", orbit.name, .{
                .orbit = orbit.name,
                .path = orbit.path,
            });
        }

        if (!self.json and !self.quiet) backend.phaseDone("All orbits synchronized.", .{});
        if (emitter) |e| try e.terminate(ctx.io, "orbit-sync", "ok", .{});
    }
};

const SyncWorkData = struct {
    cmd: OrbitSyncCommand,
    ctx: *router.Context,
    error_detail: ?command_mod.CliErrorDetail = null,
};

fn captureChildSyncFailure(ctx: *router.Context, orbit: moonstone.project.orbits.OrbitRef, err: anyerror) void {
    if (ctx.error_detail != null) return;

    const nested_detail = moonstone.diagnostics.error_context.take(ctx.allocator);
    defer if (nested_detail) |detail| ctx.allocator.free(detail);

    const message = formatChildSyncFailure(ctx.allocator, orbit.name, orbit.path, err, nested_detail) catch return;
    ctx.error_detail = .{ .message = .{ .msg = message } };
}

fn formatChildSyncFailure(
    allocator: std.mem.Allocator,
    orbit_name: []const u8,
    orbit_path: []const u8,
    err: anyerror,
    nested_detail: ?[]const u8,
) ![]u8 {
    if (nested_detail) |detail| {
        return std.fmt.allocPrint(
            allocator,
            "Orbit '{s}' at '{s}' failed to synchronize: {s}",
            .{ orbit_name, orbit_path, detail },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Orbit '{s}' at '{s}' failed to synchronize ({s}).",
        .{ orbit_name, orbit_path, @errorName(err) },
    );
}

fn orbitSyncWorker(wctx: *progress_runtime.WorkerContext) anyerror!void {
    const work_data: *SyncWorkData = @ptrCast(@alignCast(wctx.cmd_data orelse return error.WorkerMissingData));
    work_data.cmd.runImpl(work_data.ctx, .{ .queue = wctx }) catch |err| {
        if (work_data.ctx.error_detail) |detail| {
            work_data.error_detail = detail;
            work_data.ctx.error_detail = null;
        }
        return err;
    };
}

test "orbit sync failures retain orbit and nested diagnostic context" {
    const with_detail = try formatChildSyncFailure(
        std.testing.allocator,
        "child",
        "/workspace/child",
        error.PackageNotFound,
        "Local path dependency is unavailable.",
    );
    defer std.testing.allocator.free(with_detail);
    try std.testing.expectEqualStrings(
        "Orbit 'child' at '/workspace/child' failed to synchronize: Local path dependency is unavailable.",
        with_detail,
    );

    const fallback = try formatChildSyncFailure(
        std.testing.allocator,
        "child",
        "/workspace/child",
        error.UnknownHostName,
        null,
    );
    defer std.testing.allocator.free(fallback);
    try std.testing.expectEqualStrings(
        "Orbit 'child' at '/workspace/child' failed to synchronize (UnknownHostName).",
        fallback,
    );
}
