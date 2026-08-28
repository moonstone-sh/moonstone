const std = @import("std");
const builtin = @import("builtin");

/// Centralized compile-time check for POSIX archive permission support.
pub const supports_posix_permissions: bool = (builtin.os.tag != .windows and builtin.os.tag != .wasi);

pub const EntryKind = enum {
    file,
    directory,
    symlink,
};

pub const ArchivedMode = struct {
    /// Sanitized 9-bit POSIX permission mode (0o000..0o777)
    mode: u16,
    /// Whether this mode was explicitly declared in the archive metadata
    explicit: bool,
};

pub const DEFAULT_FILE_MODE: u16 = 0o644;
pub const DEFAULT_DIR_MODE: u16 = 0o755;

/// Sanitize an archived mode according to Moonstone's archive permission policy:
/// 1. Privilege / special bits (SUID 04000, SGID 02000, sticky 01000) are strictly stripped.
/// 2. If an explicit mode is provided (even 0o000), retain `mode & 0o777`.
/// 3. If mode is null / absent, fallback to safe defaults (0o644 for files, 0o755 for dirs).
pub fn sanitizeArchivedMode(kind: EntryKind, raw_mode: ?u32) ArchivedMode {
    if (raw_mode) |m| {
        return .{
            .mode = @truncate(m & 0o777),
            .explicit = true,
        };
    }
    return .{
        .mode = switch (kind) {
            .file => DEFAULT_FILE_MODE,
            .directory => DEFAULT_DIR_MODE,
            .symlink => DEFAULT_FILE_MODE,
        },
        .explicit = false,
    };
}

/// Apply sanitized POSIX permissions to an open file handle.
/// If POSIX permissions are supported on the target OS, mutations that fail
/// return `error.ArchivePermissionRestoreFailed`.
pub fn applyFilePermissions(
    io: std.Io,
    file: std.Io.File,
    sanitized_mode: u16,
) !void {
    if (comptime supports_posix_permissions) {
        const mode: std.posix.mode_t = @intCast(sanitized_mode & 0o777);
        file.setPermissions(io, std.Io.File.Permissions.fromMode(mode)) catch {
            return error.ArchivePermissionRestoreFailed;
        };
    }
}

/// Apply sanitized POSIX permissions to a directory path relative to `dir`.
/// If POSIX permissions are supported on the target OS, mutations that fail
/// return `error.ArchivePermissionRestoreFailed`.
pub fn applyDirPermissions(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    sanitized_mode: u16,
) !void {
    if (comptime supports_posix_permissions) {
        const mode: std.posix.mode_t = @intCast(sanitized_mode & 0o777);
        dir.setFilePermissions(io, sub_path, std.Io.File.Permissions.fromMode(mode), .{}) catch {
            return error.ArchivePermissionRestoreFailed;
        };
    }
}

pub const PendingDirPermission = struct {
    path: []const u8,
    mode: u16,
};

/// Comparator to sort pending directories deepest-first (longest path length first).
pub fn comparePendingDirsDeepestFirst(_: void, a: PendingDirPermission, b: PendingDirPermission) bool {
    if (a.path.len != b.path.len) {
        return a.path.len > b.path.len; // Longest path first
    }
    return std.mem.order(u8, a.path, b.path) == .gt;
}
