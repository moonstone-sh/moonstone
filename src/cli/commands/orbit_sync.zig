const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");
const progress_runtime = @import("../progress.zig");
const sync_command = @import("sync.zig").sync_command;

pub const OrbitSyncCommand = struct {
    pub const name = "sync";
    pub const description = "Sync configured orbits";

    json: bool = false,
    locked: bool = false,
    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon orbit sync [<orbit-name-or-path>] [flags]
            \\
            \\Synchronize one or all configured orbits.
            \\
            \\Flags:
            \\  --locked  Require moonstone.lock to be up-to-date
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
        if (self.json) {
            return self.runImpl(ctx, .{ .direct = ctx.stdout });
        }
        if (ctx.env.get("CI") != null or ctx.env.get("MOONSTONE_NO_PROGRESS") != null) {
            return self.runImpl(ctx, .{ .direct = ctx.stderr });
        }

        var data = SyncWorkData{ .cmd = self, .ctx = ctx };
        progress_runtime.runWithProgress(ctx.io, ctx.stderr, std.posix.STDERR_FILENO, ctx.allocator, ctx.env, orbitSyncWorker, &data) catch |err| {
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

        backend.phase("Discovered {d} orbits.", .{orbits.len});

        // project_root.path is already the absolute path of the root
        const root_cwd = project_root.path;

        for (target_orbits.items) |orbit| {
            backend.phase("Syncing orbit {s}...", .{orbit.name});

            try std.process.setCurrentPath(ctx.io, orbit.path);

            var child_sync = sync_command{
                .json = self.json,
                .locked = self.locked,
            };
            child_sync.runImpl(ctx, backend) catch |err| {
                std.process.setCurrentPath(ctx.io, root_cwd) catch {};

                // Keep the error detail
                return err;
            };
            try std.process.setCurrentPath(ctx.io, root_cwd);
        }

        backend.phaseDone("All orbits synchronized.", .{});
        if (emitter) |e| try e.terminate(ctx.io, "orbit-sync", "ok", .{});
    }
};

const SyncWorkData = struct {
    cmd: OrbitSyncCommand,
    ctx: *router.Context,
    error_detail: ?command_mod.CliErrorDetail = null,
};

fn orbitSyncWorker(wctx: *progress_runtime.WorkerContext) anyerror!void {
    const work_data: *SyncWorkData = @ptrCast(@alignCast(wctx.cmd_data orelse return error.WorkerMissingData));
    work_data.cmd.runImpl(work_data.ctx, .{ .queue = wctx }) catch |err| {
        work_data.error_detail = work_data.ctx.error_detail;
        return err;
    };
}
