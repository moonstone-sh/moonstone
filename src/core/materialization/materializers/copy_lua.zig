const std = @import("std");

pub fn materialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    exports_lua: std.StringArrayHashMapUnmanaged([]const u8),
    out_dir: std.Io.Dir,
) !void {
    var files_dir = try out_dir.createDirPathOpen(io, "files/lua", .{});
    defer files_dir.close(io);

    var it = exports_lua.iterator();
    while (it.next()) |entry| {
        const lua_module = entry.key_ptr.*;
        const src_rel_path = entry.value_ptr.*;

        // lua_module can be "inspect" or "foo.bar"
        // src_rel_path is the path in source_dir, e.g. "src/foo/bar.lua"
        
        // Convert "foo.bar" to "foo/bar.lua" if it doesn't have an extension
        // Actually, the user says:
        // [exports.lua]
        // inspect = "inspect.lua"
        // "foo.bar" = "src/foo/bar.lua"
        // Output:
        // files/lua/inspect.lua
        // files/lua/foo/bar.lua

        var target_rel_path: []u8 = undefined;
        if (std.mem.indexOfScalar(u8, lua_module, '.')) |_| {
            // Replace '.' with '/'
            target_rel_path = try allocator.dupe(u8, lua_module);
            defer allocator.free(target_rel_path);
            for (target_rel_path) |*c| {
                if (c.* == '.') c.* = '/';
            }
        } else {
            target_rel_path = try allocator.dupe(u8, lua_module);
            defer allocator.free(target_rel_path);
        }

        // Add .lua extension if missing in target
        const final_target_path = if (!std.mem.endsWith(u8, target_rel_path, ".lua"))
            try std.mem.concat(allocator, u8, &.{ target_rel_path, ".lua" })
        else
            try allocator.dupe(u8, target_rel_path);
        defer allocator.free(final_target_path);

        // Ensure parent directory exists in files/lua
        if (std.fs.path.dirname(final_target_path)) |dir_name| {
            try files_dir.createDirPath(io, dir_name);
        }

        // Copy the file
        try source_dir.copyFile(io, src_rel_path, files_dir, final_target_path, .{});
    }
}
