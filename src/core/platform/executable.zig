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
    return resolveInDirectoryForTarget(allocator, io, directory, name, comptime hostTargetLiteral());
}

/// Resolves an executable using the naming rules of `target`, not the host
/// running Moonstone. This permits inspection of an already-realized foreign
/// artifact without pretending that it can be executed by the host.
pub fn resolveInDirectoryForTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    target: []const u8,
) !?[]u8 {
    if (targetIsWindows(target)) return resolveWindows(allocator, io, directory, name);
    return resolveUnix(allocator, io, directory, name);
}

/// Whether a provision's physical filename is a valid projection of its
/// logical executable name for `target`.
pub fn targetExecutableNameMatches(target: []const u8, name: []const u8, physical_name: []const u8) bool {
    if (!targetIsWindows(target)) return std.mem.eql(u8, name, physical_name);
    if (std.ascii.eqlIgnoreCase(name, physical_name)) return true;
    const extension = windowsExecutableExtension(physical_name) orelse return false;
    return std.ascii.eqlIgnoreCase(name, physical_name[0 .. physical_name.len - extension.len]);
}

fn targetIsWindows(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "-windows-") != null;
}

fn hostTargetLiteral() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "host-windows",
        else => "host-unix",
    };
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

test "target executable naming follows the requested target, not the host" {
    try std.testing.expect(targetExecutableNameMatches("x86_64-windows-gnu", "tool", "tool.cmd"));
    try std.testing.expect(targetExecutableNameMatches("aarch64-windows-msvc", "tool", "tool.EXE"));
    try std.testing.expect(!targetExecutableNameMatches("x86_64-linux-gnu", "tool", "tool.exe"));
    try std.testing.expect(!targetExecutableNameMatches("x86_64-macos", "tool", "other"));
}
