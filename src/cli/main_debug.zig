const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");

pub const Command = @import("commands/command.zig").Command;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Use traditional args for now to avoid Init issues if possible
    const all_args = try std.process.argsAlloc(allocator);
    // defer std.process.argsFree(allocator, all_args); // Arena handles it

    // We need Io and Environ.Map for our commands
    // In 0.16.0 we might need to get them differently if Init is broken for us
    // Let's try to get a basic Io
    // Since I cannot easily find how to init std.Io manually without more research,
    // let's stick with std.process.Init and try to figure out why it segfaults.
}
