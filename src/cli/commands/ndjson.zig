const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const MessageKind = enum {
    START,
    PROGRESS,
    STATUS,
    ERROR,
    WARN,
    RESULT,
    PROMPT,
    INFO,
    DUMP,

    pub fn asString(self: MessageKind) []const u8 {
        return @tagName(self);
    }
};

pub const Envelope = struct {
    contract: []const u8,
    run_id: []const u8,
    kind: MessageKind,
    timestamp: []const u8,
    seq: usize,
    about: []const u8,
    value: []const u8,
    data: std.json.Value = .null,
    terminator: bool = false,
    meta: Meta,

    pub const Meta = struct {
        command: []const u8,
        version: []const u8 = build_options.version,
        pid: i32,
    };
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    command: []const u8,
    seq: usize = 1,
    pid: i32,
    run_id: [64]u8 = undefined,
    run_id_len: usize = 0,
    mutex: std.Io.Mutex = .{ .state = .{ .raw = .unlocked } },

    pub fn init(allocator: std.mem.Allocator, stdout: *std.Io.Writer, command: []const u8) Emitter {
        var emitter = Emitter{
            .allocator = allocator,
            .stdout = stdout,
            .command = command,
            .pid = if (comptime builtin.os.tag == .windows)
                @intCast(std.os.windows.GetCurrentProcessId())
            else
                std.c.getpid(),
        };
        if (std.fmt.bufPrint(emitter.run_id[0..], "pid-{d}", .{emitter.pid})) |run_id| {
            emitter.run_id_len = run_id.len;
        } else |_| {
            const fallback = "pid-unknown";
            @memcpy(emitter.run_id[0..fallback.len], fallback);
            emitter.run_id_len = fallback.len;
        }
        return emitter;
    }

    fn runId(self: *const Emitter) []const u8 {
        return self.run_id[0..self.run_id_len];
    }

    pub fn emit(self: *Emitter, io: std.Io, kind: MessageKind, about: []const u8, value: []const u8, data: anytype) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        // 1. Format timestamp (seconds.ms)
        var ts_buf: [64]u8 = undefined;
        const ts_raw = std.Io.Timestamp.now(io, .real);
        const seconds = @divFloor(ts_raw.nanoseconds, std.time.ns_per_s);
        const ms: u64 = @intCast(@divFloor(@mod(ts_raw.nanoseconds, std.time.ns_per_s), std.time.ns_per_ms));
        const ts = try std.fmt.bufPrint(&ts_buf, "{d}.{d:0>3}Z", .{ seconds, ms });

        // 2. Serialize to NDJSON
        try std.json.Stringify.value(.{
            .contract = "moonstone:cli-events:v1",
            .run_id = self.runId(),
            .kind = kind.asString(),
            .timestamp = ts,
            .seq = self.seq,
            .about = about,
            .value = value,
            .data = data,
            .terminator = false,
            .meta = .{
                .command = self.command,
                .pid = self.pid,
                .version = build_options.version,
            },
        }, .{}, &aw.writer);

        try self.stdout.writeAll(aw.writer.buffer[0..aw.writer.end]);
        try self.stdout.writeAll("\n");
        try self.stdout.flush();
        self.seq += 1;
    }

    /// Emits one idempotent task-state replacement. `revision` is monotonic
    /// within the caller's stable task id; `seq` remains globally serialized
    /// by this emitter.
    pub fn emitTask(
        self: *Emitter,
        io: std.Io,
        task_id: []const u8,
        revision: u64,
        state: []const u8,
        data: anytype,
    ) !void {
        try self.emit(io, .STATUS, task_id, state, .{
            .task_id = task_id,
            .revision = revision,
            .state = state,
            .data = data,
        });
    }

    pub fn terminate(self: *Emitter, io: std.Io, about: []const u8, value: []const u8, data: anytype) !void {
        try self.finish(io, MessageKind.RESULT, about, value, data);
    }

    pub fn fail(self: *Emitter, io: std.Io, about: []const u8, value: []const u8, data: anytype) !void {
        try self.finish(io, MessageKind.ERROR, about, value, data);
    }

    fn finish(self: *Emitter, io: std.Io, kind: MessageKind, about: []const u8, value: []const u8, data: anytype) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var aw = std.Io.Writer.Allocating.init(self.allocator);
        defer aw.deinit();

        var ts_buf: [64]u8 = undefined;
        const ts_raw = std.Io.Timestamp.now(io, .real);
        const seconds = @divFloor(ts_raw.nanoseconds, std.time.ns_per_s);
        const ms: u64 = @intCast(@divFloor(@mod(ts_raw.nanoseconds, std.time.ns_per_s), std.time.ns_per_ms));
        const ts = try std.fmt.bufPrint(&ts_buf, "{d}.{d:0>3}Z", .{ seconds, ms });

        try std.json.Stringify.value(.{
            .contract = "moonstone:cli-events:v1",
            .run_id = self.runId(),
            .kind = kind.asString(),
            .timestamp = ts,
            .seq = self.seq,
            .about = about,
            .value = value,
            .data = data,
            .terminator = true,
            .meta = .{
                .command = self.command,
                .pid = self.pid,
                .version = build_options.version,
            },
        }, .{}, &aw.writer);

        try self.stdout.writeAll(aw.writer.buffer[0..aw.writer.end]);
        try self.stdout.writeAll("\n");
        try self.stdout.flush();
        self.seq += 1;
    }
};
