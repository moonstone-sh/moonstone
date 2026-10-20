const std = @import("std");
const manifest_mod = @import("../domain/manifest.zig");

pub const Options = struct { environ_map: *std.process.Environ.Map };
pub const Result = union(enum) { success, exit_code: u8, signaled };

pub fn run(allocator: std.mem.Allocator, io: std.Io, manifest: *const manifest_mod.MoonstoneToml, name: []const u8, args: []const []const u8, options: Options) !Result {
    const script = manifest.findScript(name) orelse return error.ScriptNotFound;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    if (!script.shell) {
        const command = try @import("../domain/script.zig").commandArgv(allocator, script.command);
        defer @import("../domain/script.zig").freeArgv(allocator, command);
        try argv.appendSlice(allocator, command);
        try argv.appendSlice(allocator, args);
        return spawnAndWait(allocator, io, argv.items, options);
    }
    if (comptime @import("builtin").os.tag == .windows) {
        // A real batch file gives explicit shell scripts their own %* and
        // positional arguments, without appending data to the shell expression.
        var random: [8]u8 = undefined;
        try std.Io.randomSecure(io, &random);
        const basename = try std.fmt.allocPrint(allocator, "moon-script-{x}.cmd", .{std.mem.readInt(u64, &random, .little)});
        defer allocator.free(basename);
        const filename = try std.fs.path.join(allocator, &.{ options.environ_map.get("TEMP") orelse options.environ_map.get("TMP") orelse ".", basename });
        defer allocator.free(filename);
        {
            const file = try std.Io.Dir.cwd().createFile(io, filename, .{ .exclusive = true });
            defer file.close(io);
            try file.writeStreamingAll(io, "@echo off\r\nsetlocal DisableDelayedExpansion\r\n");
            try file.writeStreamingAll(io, script.command);
            try file.writeStreamingAll(io, "\r\n");
        }
        defer std.Io.Dir.cwd().deleteFile(io, filename) catch {};
        try argv.append(allocator, filename);
        try argv.appendSlice(allocator, args);
        return spawnAndWait(allocator, io, argv.items, options);
    } else {
        try argv.appendSlice(allocator, &.{ "sh", "-c", script.command, script.name });
    }
    try argv.appendSlice(allocator, args);
    return spawnAndWait(allocator, io, argv.items, options);
}

fn spawnAndWait(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, options: Options) !Result {
    var prepared = try @import("../platform/process.zig").prepareArgv(allocator, argv);
    defer prepared.deinit(allocator);
    var child = try std.process.spawn(io, .{ .argv = prepared.argv, .environ_map = options.environ_map, .stdout = .inherit, .stderr = .inherit });
    const result = try child.wait(io);
    return switch (result) {
        .exited => |code| if (code == 0) .success else .{ .exit_code = code },
        else => .signaled,
    };
}
