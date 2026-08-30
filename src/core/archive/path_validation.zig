const std = @import("std");

pub const PathValidationError = error{
    InvalidPath,
    PathTraversalDetected,
    AbsolutePathsNotAllowed,
    SymlinkTargetEscapesDestination,
    NullByteInPath,
} || std.mem.Allocator.Error;

/// Validate and sanitize an archive entry path to ensure it cannot escape the destination directory.
/// Returns a freshly allocated relative path that is safe to join with the destination directory.
pub fn sanitizeArchivePath(allocator: std.mem.Allocator, raw_path: []const u8) PathValidationError![]const u8 {
    if (raw_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, raw_path, 0) != null) return error.NullByteInPath;

    // Reject absolute paths and UNC / drive prefix
    if (raw_path[0] == '/' or raw_path[0] == '\\') return error.AbsolutePathsNotAllowed;
    if (raw_path.len >= 2 and raw_path[1] == ':') return error.AbsolutePathsNotAllowed;
    if (raw_path.len >= 2 and (raw_path[0] == '\\' and raw_path[1] == '\\')) return error.AbsolutePathsNotAllowed;
    if (raw_path.len >= 2 and (raw_path[0] == '/' and raw_path[1] == '/')) return error.AbsolutePathsNotAllowed;

    var sanitized = try allocator.alloc(u8, raw_path.len);
    defer allocator.free(sanitized);

    // Normalize backslashes to forward slashes
    for (raw_path, 0..) |c, i| {
        sanitized[i] = if (c == '\\') '/' else c;
    }

    var components = std.ArrayList([]const u8).empty;
    defer components.deinit(allocator);

    var it = std.mem.splitScalar(u8, sanitized, '/');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".")) continue;

        if (std.mem.eql(u8, trimmed, "..")) {
            if (components.items.len == 0) {
                return error.PathTraversalDetected;
            }
            _ = components.pop();
        } else {
            try components.append(allocator, trimmed);
        }
    }

    if (components.items.len == 0) return error.InvalidPath;

    return try std.mem.join(allocator, "/", components.items);
}

/// Validate that a symlink target doesn't escape the extraction root.
pub fn validateSymlinkTarget(link_target: []const u8, entry_relative_path: []const u8) PathValidationError!void {
    if (link_target.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, link_target, 0) != null) return error.NullByteInPath;

    // Absolute targets are disallowed
    if (link_target[0] == '/' or link_target[0] == '\\') return error.SymlinkTargetEscapesDestination;
    if (link_target.len >= 2 and link_target[1] == ':') return error.SymlinkTargetEscapesDestination;

    // Calculate directory depth of the entry
    var dir_depth: isize = 0;
    var entry_it = std.mem.splitScalar(u8, entry_relative_path, '/');
    var entry_parts: usize = 0;
    while (entry_it.next()) |p| {
        if (p.len > 0) entry_parts += 1;
    }
    if (entry_parts > 1) {
        dir_depth = @as(isize, @intCast(entry_parts - 1));
    }

    // Trace link target relative to entry dir
    var target_depth = dir_depth;
    var target_it = std.mem.splitAny(u8, link_target, "/\\");
    while (target_it.next()) |comp| {
        const c = std.mem.trim(u8, comp, " \t\r\\");
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            target_depth -= 1;
            if (target_depth < 0) return error.SymlinkTargetEscapesDestination;
        } else {
            target_depth += 1;
        }
    }

    if (target_depth < 0) return error.SymlinkTargetEscapesDestination;
}

/// Strip setuid/setgid and sticky bits for safety.
pub fn sanitizeMode(mode: u32) u32 {
    return mode & 0o777;
}
