const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    env: *std.process.Environ.Map,
    root: ?*const @import("router.zig").CommandNode = null,
    error_detail: ?@import("commands/command.zig").CliErrorDetail = null,
};
