const std = @import("std");

pub const DirectoryArgs = struct {
    args: []const []const u8,
    directory: ?[]const u8 = null,

    pub fn deinit(self: DirectoryArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.args);
    }
};

/// Extracts Moonstone's global project-resolution directory option before the
/// command router sees its arguments. Parsing stops at the first command token
/// or `--`, so child-process arguments remain opaque.
pub fn extractDirectory(allocator: std.mem.Allocator, raw_args: []const []const u8) !DirectoryArgs {
    var args = std.ArrayList([]const u8).empty;
    errdefer args.deinit(allocator);
    if (raw_args.len == 0) return .{ .args = try args.toOwnedSlice(allocator) };
    try args.append(allocator, raw_args[0]);

    var directory: ?[]const u8 = null;
    var parsing_global_flags = true;
    var index: usize = 1;
    while (index < raw_args.len) : (index += 1) {
        const arg = raw_args[index];
        if (parsing_global_flags and std.mem.eql(u8, arg, "--")) {
            try args.append(allocator, arg);
            parsing_global_flags = false;
            continue;
        }
        if (parsing_global_flags and std.mem.startsWith(u8, arg, "--config-file=")) {
            try args.append(allocator, arg);
            continue;
        }
        if (parsing_global_flags and std.mem.eql(u8, arg, "--config-file")) {
            try args.append(allocator, arg);
            index += 1;
            if (index >= raw_args.len) return error.MissingArgument;
            try args.append(allocator, raw_args[index]);
            continue;
        }
        if (parsing_global_flags and (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--directory"))) {
            index += 1;
            if (index >= raw_args.len or raw_args[index].len == 0) return error.MissingArgument;
            if (directory != null) return error.DuplicateDirectoryOption;
            directory = raw_args[index];
            continue;
        }
        if (parsing_global_flags and std.mem.startsWith(u8, arg, "--directory=")) {
            const value = arg["--directory=".len..];
            if (value.len == 0) return error.MissingArgument;
            if (directory != null) return error.DuplicateDirectoryOption;
            directory = value;
            continue;
        }

        try args.append(allocator, arg);
        if (parsing_global_flags and !std.mem.startsWith(u8, arg, "-")) parsing_global_flags = false;
    }

    return .{ .args = try args.toOwnedSlice(allocator), .directory = directory };
}

test "directory extraction keeps child arguments opaque after a command" {
    const raw = [_][]const u8{ "moon", "-C", "project", "exec", "tool", "-C", "child" };
    var parsed = try extractDirectory(std.testing.allocator, &raw);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("project", parsed.directory.?);
    try std.testing.expectEqualStrings("moon", parsed.args[0]);
    try std.testing.expectEqualStrings("exec", parsed.args[1]);
    try std.testing.expectEqualStrings("tool", parsed.args[2]);
    try std.testing.expectEqualStrings("-C", parsed.args[3]);
    try std.testing.expectEqualStrings("child", parsed.args[4]);
}

test "directory extraction supports the long equals form" {
    const raw = [_][]const u8{ "moon", "--directory=project", "manifest", "export", "--json" };
    var parsed = try extractDirectory(std.testing.allocator, &raw);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("project", parsed.directory.?);
    try std.testing.expectEqual(@as(usize, 4), parsed.args.len);
    try std.testing.expectEqualStrings("manifest", parsed.args[1]);
}

test "directory extraction rejects duplicate global directories" {
    const raw = [_][]const u8{ "moon", "-C", "one", "--directory", "two", "manifest" };
    try std.testing.expectError(error.DuplicateDirectoryOption, extractDirectory(std.testing.allocator, &raw));
}

test "directory extraction accepts config selection before the directory" {
    const raw = [_][]const u8{ "moon", "--config-file", "settings.toml", "-C", "project", "manifest", "export" };
    var parsed = try extractDirectory(std.testing.allocator, &raw);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("project", parsed.directory.?);
    try std.testing.expectEqual(@as(usize, 5), parsed.args.len);
    try std.testing.expectEqualStrings("--config-file", parsed.args[1]);
    try std.testing.expectEqualStrings("settings.toml", parsed.args[2]);
    try std.testing.expectEqualStrings("manifest", parsed.args[3]);
}
