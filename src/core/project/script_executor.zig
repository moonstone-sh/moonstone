const std = @import("std");
const manifest_mod = @import("../domain/manifest.zig");

pub const Options = struct { environ_map: *std.process.Environ.Map };
pub const Result = union(enum) { success, exit_code: u8, signaled };

pub fn run(allocator: std.mem.Allocator, io: std.Io, manifest: *const manifest_mod.MoonstoneToml, name: []const u8, args: []const []const u8, options: Options) !Result {
    const script = manifest.findScript(name) orelse return error.ScriptNotFound;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    if (@import("builtin").os.tag == .windows) {
        try argv.appendSlice(allocator, &.{ "cmd", "/d", "/s", "/c", script.command });
    } else {
        try argv.appendSlice(allocator, &.{ "sh", "-c", script.command, script.name });
    }
    try argv.appendSlice(allocator, args);
    return spawnAndWait(allocator, io, argv.items, options);
}

fn spawnAndWait(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, options: Options) !Result {
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = options.environ_map, .stdout = .inherit, .stderr = .inherit });
    const result = try child.wait(io);
    _ = allocator;
    return switch (result) {
        .exited => |code| if (code == 0) .success else .{ .exit_code = code },
        else => .signaled,
    };
}
