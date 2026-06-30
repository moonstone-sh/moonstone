const std = @import("std");
const Resolver = @import("src/core/resolution/solver.zig").Resolver;
pub fn main() void {
    std.debug.print("Size of Resolver: {}\n", .{@sizeOf(Resolver)});
}
