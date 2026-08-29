const std = @import("std");
const builtin = @import("builtin");

const windows_executable_extensions = .{ ".exe", ".cmd", ".bat" };

/// Returns a Windows executable extension when `path` names a directly
/// executable file. Keep the projection and lookup rules in one vocabulary:
/// a store provision named `tool` at `bin/tool.cmd` must materialize as
/// `tool.cmd`, which `moon exec tool` can subsequently resolve.
pub fn windowsExecutableExtension(path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(path);
    inline for (windows_executable_extensions) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return extension;
    }
    return null;
}

/// Resolves an executable from one directory using the compile target's native
/// executable naming contract. Windows accepts an explicit name first, then an
/// `.exe` form; Unix targets only accept the supplied name.
pub fn resolveInDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) !?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        return resolveWindows(allocator, io, directory, name);
    }
    return resolveUnix(allocator, io, directory, name);
}

fn resolveUnix(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ directory, name });
    if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {
        allocator.free(candidate);
        return null;
    }
}

fn resolveWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) !?[]u8 {
    if (try resolveUnix(allocator, io, directory, name)) |candidate| return candidate;
    if (std.fs.path.extension(name).len > 0) return null;

    inline for (windows_executable_extensions) |extension| {
        const executable_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, extension });
        defer allocator.free(executable_name);
        if (try resolveUnix(allocator, io, directory, executable_name)) |candidate| return candidate;
    }

    return null;
}

test "Windows resolution recognizes executable, command, and batch suffixes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (.{ "lua.exe", "tool.cmd", "batch.bat" }) |name| {
        const executable = try tmp.dir.createFile(io, name, .{});
        executable.close(io);
    }
    const directory = try tmp.dir.realPathAlloc(io, std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);

    inline for (.{
        .{ "lua", "lua.exe" },
        .{ "tool", "tool.cmd" },
        .{ "batch", "batch.bat" },
    }) |case| {
        const resolved = try resolveWindows(std.testing.allocator, io, directory, case[0]);
        defer if (resolved) |path| std.testing.allocator.free(path);
        try std.testing.expect(resolved != null);
        try std.testing.expect(std.mem.endsWith(u8, resolved.?, case[1]));
    }

    try std.testing.expect(windowsExecutableExtension("tool.CMD") != null);
    try std.testing.expect(windowsExecutableExtension("tool.ps1") == null);
}
