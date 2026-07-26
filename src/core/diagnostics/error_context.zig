const std = @import("std");

var message: ?[]u8 = null;

fn replace(text: []const u8) void {
    const owned = std.heap.page_allocator.dupe(u8, text) catch return;
    if (message) |previous| std.heap.page_allocator.free(previous);
    message = owned;
}

pub fn setOwned(allocator: std.mem.Allocator, text: []const u8) void {
    _ = allocator;
    replace(text);
}

pub fn setFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const formatted = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(formatted);
    replace(formatted);
}

pub fn take(allocator: std.mem.Allocator) ?[]u8 {
    const current = message;
    message = null;
    if (current) |text| {
        defer std.heap.page_allocator.free(text);
        return allocator.dupe(u8, text) catch null;
    }
    return null;
}
