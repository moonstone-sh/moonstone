const std = @import("std");
const ndjson = @import("commands/ndjson.zig");
const progress_runtime = @import("progress.zig");

pub const TaskKind = enum {
    realize,
    replay,
};

pub fn formatOrbitSyncId(buffer: []u8, orbit_name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "orbit-sync:{s}", .{orbit_name});
}

/// Formats the stable identity used by interactive progress and NDJSON task
/// events. A task is scoped to a concrete target and resolver because the same
/// package version may be realized independently for multiple profiles.
pub fn formatId(
    buffer: []u8,
    kind: TaskKind,
    target: []const u8,
    resolver: []const u8,
    package_name: []const u8,
    version: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}:{s}:{s}:{s}@{s}", .{
        @tagName(kind),
        target,
        resolver,
        package_name,
        version,
    });
}

/// Owns the command-selected destination for task lifecycle events. Exactly
/// one surface should normally be configured: NDJSON, the interactive queue,
/// or durable plain text.
pub const Reporter = struct {
    emitter: ?*ndjson.Emitter = null,
    wctx: ?*progress_runtime.WorkerContext = null,
    plain_writer: ?*std.Io.Writer = null,
    plain_mutex: ?*std.Io.Mutex = null,

    pub fn report(
        self: Reporter,
        io: std.Io,
        task_id: []const u8,
        revision: u64,
        state: []const u8,
        message: []const u8,
        data: anytype,
    ) void {
        if (self.emitter) |value| {
            value.emitTask(io, task_id, revision, state, data) catch {};
            return;
        }
        if (self.wctx) |value| {
            value.sendTaskState(task_id, revision, state, message);
            return;
        }
        if (self.plain_writer) |writer| {
            if (self.plain_mutex) |mutex| mutex.lockUncancelable(io);
            defer if (self.plain_mutex) |mutex| mutex.unlock(io);
            writer.print("  {s} {s}: {s}\n", .{ state, task_id, message }) catch {};
            writer.flush() catch {};
        }
    }
};

test "task identities scope identical packages to target and resolver" {
    var linux_buffer: [256]u8 = undefined;
    const linux = try formatId(
        &linux_buffer,
        .realize,
        "x86_64-linux-gnu",
        "rocks",
        "dkjson",
        "2.8",
    );
    try std.testing.expectEqualStrings(
        "realize:x86_64-linux-gnu:rocks:dkjson@2.8",
        linux,
    );

    var windows_buffer: [256]u8 = undefined;
    const windows = try formatId(
        &windows_buffer,
        .realize,
        "x86_64-windows-gnu",
        "rocks",
        "dkjson",
        "2.8",
    );
    try std.testing.expect(!std.mem.eql(u8, linux, windows));

    var registry_buffer: [256]u8 = undefined;
    const registry = try formatId(
        &registry_buffer,
        .realize,
        "x86_64-linux-gnu",
        "moonstone",
        "dkjson",
        "2.8",
    );
    try std.testing.expect(!std.mem.eql(u8, linux, registry));
}

test "orbit sync task identities are project scoped" {
    var buffer: [128]u8 = undefined;
    const task_id = try formatOrbitSyncId(&buffer, "api");
    try std.testing.expectEqualStrings("orbit-sync:api", task_id);
}

test "plain reporter emits durable task transitions" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const reporter = Reporter{ .plain_writer = &writer };

    reporter.report(std.testing.io, "orbit-sync:api", 1, "running", "api", .{});
    try std.testing.expectEqualStrings(
        "  running orbit-sync:api: api\n",
        writer.buffer[0..writer.end],
    );
}
