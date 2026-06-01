const std = @import("std");

pub fn print(io: std.Io, msg: []const u8) !void {
    _ = try io.operate(.{ .file_write = .{
        .file = std.Io.File.stdout(),
        .buffer = msg,
    } });
}

pub fn printf(io: std.Io, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try print(io, s);
}
