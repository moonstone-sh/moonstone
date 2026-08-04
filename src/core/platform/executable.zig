const std = @import("std");
const builtin = @import("builtin");

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

    const executable_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{name});
    defer allocator.free(executable_name);
    return resolveUnix(allocator, io, directory, executable_name);
}
