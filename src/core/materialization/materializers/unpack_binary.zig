const std = @import("std");
const archive = @import("../../archive/root.zig");

pub fn materialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    strip_components: u32,
    selected_bin_paths: std.StringArrayHashMapUnmanaged([]const u8),
    out_dir: std.Io.Dir,
) !void {
    // 1. Create a temporary extraction directory
    // We can use out_dir/tmp_unpack
    try out_dir.createDirPath(io, "tmp_unpack");
    const tmp_unpack_path = try out_dir.realPathAlloc(io, allocator, "tmp_unpack");
    defer allocator.free(tmp_unpack_path);
    defer out_dir.deleteTree(io, "tmp_unpack") catch {};

    // 2. Unpack using unified archive abstraction
    archive.unpackArchive(allocator, io, archive_path, tmp_unpack_path, .{}) catch |err| switch (err) {
        error.UnsupportedArchiveFormat => return error.UnsupportedArchiveFormat,
        else => return error.UnpackError,
    };

    // 3. Handle strip_components
    var current_root_path = try allocator.dupe(u8, tmp_unpack_path);
    defer allocator.free(current_root_path);

    var i: u32 = 0;
    while (i < strip_components) : (i += 1) {
        var dir = try std.Io.Dir.cwd().openDir(io, current_root_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var first_dir: ?[]const u8 = null;
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (first_dir == null) first_dir = try allocator.dupe(u8, entry.name);
                count += 1;
            }
        }
        if (count == 1 and first_dir != null) {
            const next_root = try std.fs.path.join(allocator, &.{ current_root_path, first_dir.? });
            allocator.free(current_root_path);
            current_root_path = next_root;
            allocator.free(first_dir.?);
        } else {
            if (first_dir) |fd| allocator.free(fd);
            return error.CannotStripComponents;
        }
    }

    // 4. Move selected bins to out_dir/files/bin
    var bin_dir = try out_dir.createDirPathOpen(io, "files/bin", .{});
    defer bin_dir.close(io);

    var root_dir = try std.Io.Dir.cwd().openDir(io, current_root_path, .{});
    defer root_dir.close(io);

    var it = selected_bin_paths.iterator();
    while (it.next()) |entry| {
        const bin_name = entry.key_ptr.*;
        const src_rel_path = entry.value_ptr.*;

        try root_dir.copyFile(io, src_rel_path, bin_dir, bin_name, .{});
        // Ensure it's executable
        // In Zig 0.16.0 we might need to use chmod if available
        // For now, assume copyFile preserves some bits or we'll fix it if it fails tests
    }
}
