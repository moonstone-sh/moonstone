const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    env: *std.process.Environ.Map,
    working_directory: ?[]const u8 = null,
    root: ?*const @import("router.zig").CommandNode = null,
    error_detail: ?@import("commands/command.zig").CliErrorDetail = null,
    all_args: []const []const u8 = &.{},
};
