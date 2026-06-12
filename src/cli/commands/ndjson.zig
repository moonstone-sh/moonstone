const std = @import("std");
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
    mutex: std.Io.Mutex = .{ .state = .{ .raw = .unlocked } },

    pub fn init(allocator: std.mem.Allocator, stdout: *std.Io.Writer, command: []const u8) Emitter {
        return .{
            .allocator = allocator,
            .stdout = stdout,
            .command = command,
            .pid = std.c.getpid(),
        };
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
        const ts = try std.fmt.bufPrint(&ts_buf, "{d}.{d:0>3}Z", .{seconds, ms});

        // 2. Serialize to NDJSON
        try std.json.Stringify.value(.{
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
        const ts = try std.fmt.bufPrint(&ts_buf, "{d}.{d:0>3}Z", .{seconds, ms});

        try std.json.Stringify.value(.{
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
