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
    // Zig's Windows spawn searches the parent PATH, rather than the supplied
    // environment. Resolve before preparing batch argv so project binaries and
    // Windows executable suffixes use the same rules as `moon exec`.
    const executable = try resolveCommand(allocator, io, argv[0], options.environ_map);
    defer allocator.free(executable);
    const resolved_argv = try allocator.dupe([]const u8, argv);
    defer allocator.free(resolved_argv);
    resolved_argv[0] = executable;
    var prepared = try @import("../platform/process.zig").prepareArgv(allocator, resolved_argv);
    defer prepared.deinit(allocator);
    var child = try std.process.spawn(io, .{ .argv = prepared.argv, .environ_map = options.environ_map, .stdout = .inherit, .stderr = .inherit });
    const result = try child.wait(io);
    return switch (result) {
        .exited => |code| if (code == 0) .success else .{ .exit_code = code },
        else => .signaled,
    };
}

fn resolveCommand(allocator: std.mem.Allocator, io: std.Io, name: []const u8, environ: *const std.process.Environ.Map) ![]u8 {
    if (std.fs.path.isAbsolute(name) or std.mem.indexOfAny(u8, name, "/\\") != null)
        return allocator.dupe(u8, name);
    const path = environ.get("PATH") orelse return error.FileNotFound;
    const separator: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    var directories = std.mem.splitScalar(u8, path, separator);
    while (directories.next()) |directory| {
        if (try @import("../platform/executable.zig").resolveInDirectory(allocator, io, if (directory.len == 0) "." else directory, name)) |candidate|
            return candidate;
    }
    return error.FileNotFound;
}

test "scripts resolve commands through the supplied project PATH" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = if (@import("builtin").os.tag == .windows) "project-probe.exe" else "project-probe";
    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "fixture" });
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("PATH", directory);
    const resolved = try resolveCommand(allocator, io, "project-probe", &environ);
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &.{ directory, filename });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
    try std.testing.expectError(error.FileNotFound, resolveCommand(allocator, io, "missing-project-probe", &environ));
}
