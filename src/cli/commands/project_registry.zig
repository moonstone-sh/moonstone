const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

// Plain path receipts work without Windows symlink privileges. They point to
// projects; their lockfiles remain the authority for artifact reachability.
pub fn register(ctx: *router.Context, root: []const u8) !void {
    var paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
    defer paths.deinit(ctx.allocator);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const filename = try std.fmt.allocPrint(ctx.allocator, "{s}.path", .{hex});
    defer ctx.allocator.free(filename);
    const path = try std.fs.path.join(ctx.allocator, &.{ paths.projects, filename });
    defer ctx.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(ctx.io, paths.projects);
    const file = try std.Io.Dir.cwd().createFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, root);
}

pub fn readRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const root = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(64 * 1024));
    errdefer allocator.free(root);
    if (!std.fs.path.isAbsolute(root)) return error.InvalidProjectReference;
    return root;
}
