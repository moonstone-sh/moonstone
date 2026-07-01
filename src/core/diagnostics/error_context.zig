const std = @import("std");

var message: ?[]u8 = null;

pub fn setOwned(allocator: std.mem.Allocator, text: []const u8) void {
    const owned = allocator.dupe(u8, text) catch return;
    message = owned;
}

pub fn setFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const owned = std.fmt.allocPrint(allocator, fmt, args) catch return;
    message = owned;
}

pub fn take(allocator: std.mem.Allocator) ?[]u8 {
    const current = message;
    message = null;
    if (current) |text| return allocator.dupe(u8, text) catch null;
    return null;
}
