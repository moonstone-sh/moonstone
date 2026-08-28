const std = @import("std");
const builtin = @import("builtin");

pub const ToolStatus = struct {
    available: bool,
    path: ?[]const u8 = null,
    version: ?[]const u8 = null,

    pub fn deinit(self: *ToolStatus, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        if (self.version) |v| allocator.free(v);
        self.* = .{ .available = false };
    }
};

pub const ToolRunResult = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: *ToolRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Resolve the full path of an executable on the system PATH, with OS-aware extension handling.
pub fn findExecutable(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?[]const u8 {
    // If the path already has directory separators, verify directly
    if (std.mem.indexOfScalar(u8, name, '/') != null or (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, name, '\\') != null)) {
        if (std.Io.Dir.cwd().access(io, name, .{})) |_| {
            return try allocator.dupe(u8, name);
        } else |_| {
            if (builtin.os.tag == .windows) {
                if (try checkWindowsExtensions(allocator, io, name)) |match| {
                    return match;
                }
            }
            return null;
        }
    }

    const env_c = std.c.getenv("PATH") orelse return null;
    const env_path = std.mem.span(env_c);
    if (env_path.len == 0) return null;

    const path_delimiter = if (builtin.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, env_path, path_delimiter);

    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(candidate);

        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| {
            return try allocator.dupe(u8, candidate);
        } else |_| {}

        if (builtin.os.tag == .windows) {
            if (try checkWindowsExtensions(allocator, io, candidate)) |match| {
                return match;
            }
        }
    }

    return null;
}

fn checkWindowsExtensions(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8) !?[]const u8 {
    const pathext_c = std.c.getenv("PATHEXT");
    const default_exts = [_][]const u8{ ".exe", ".cmd", ".bat", ".com" };

    if (pathext_c) |pe_raw| {
        const pe = std.mem.span(pe_raw);
        var ext_it = std.mem.splitScalar(u8, pe, ';');
        while (ext_it.next()) |ext| {
            if (ext.len == 0) continue;
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, ext });
            defer allocator.free(full_path);
            if (std.Io.Dir.cwd().access(io, full_path, .{})) |_| {
                return try allocator.dupe(u8, full_path);
            } else |_| {}
        }
    } else {
        for (default_exts) |ext| {
            const full_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, ext });
            defer allocator.free(full_path);
            if (std.Io.Dir.cwd().access(io, full_path, .{})) |_| {
                return try allocator.dupe(u8, full_path);
            } else |_| {}
        }
    }

    return null;
}

pub fn checkTool(allocator: std.mem.Allocator, io: std.Io, name: []const u8, version_arg: []const u8) !ToolStatus {
    const exe_path = try findExecutable(allocator, io, name);
    if (exe_path == null) {
        return ToolStatus{ .available = false };
    }

    var status = ToolStatus{
        .available = true,
        .path = exe_path,
        .version = null,
    };

    const res = std.process.run(allocator, io, .{
        .argv = &.{ exe_path.?, version_arg },
    }) catch {
        return status;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term == .exited and res.term.exited == 0) {
        const out = if (res.stdout.len > 0) res.stdout else res.stderr;
        var lines = std.mem.splitScalar(u8, out, '\n');
        if (lines.next()) |first_line| {
            const trimmed = std.mem.trim(u8, first_line, " \r\t");
            if (trimmed.len > 0) {
                status.version = try allocator.dupe(u8, trimmed);
            }
        }
    }

    return status;
}

pub fn runTool(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !ToolRunResult {
    const res = try std.process.run(allocator, io, .{
        .argv = argv,
    });

    return ToolRunResult{
        .term = res.term,
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

// ============================================================================
// Semantic Operations for System Archive Utilities
// ============================================================================

pub const tar = struct {
    pub fn extract(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, strip_components: u32) !ToolRunResult {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, "tar");
        try argv.append(allocator, "-xf");
        try argv.append(allocator, archive_path);
        try argv.append(allocator, "-C");
        try argv.append(allocator, dest_path);

        var strip_arg: ?[]const u8 = null;
        if (strip_components > 0) {
            strip_arg = try std.fmt.allocPrint(allocator, "--strip-components={d}", .{strip_components});
            try argv.append(allocator, strip_arg.?);
        }
        defer if (strip_arg) |sa| allocator.free(sa);

        return runTool(allocator, io, argv.items);
    }

    pub fn extractGz(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, strip_components: u32) !ToolRunResult {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, "tar");
        try argv.append(allocator, "-xzf");
        try argv.append(allocator, archive_path);
        try argv.append(allocator, "-C");
        try argv.append(allocator, dest_path);

        var strip_arg: ?[]const u8 = null;
        if (strip_components > 0) {
            strip_arg = try std.fmt.allocPrint(allocator, "--strip-components={d}", .{strip_components});
            try argv.append(allocator, strip_arg.?);
        }
        defer if (strip_arg) |sa| allocator.free(sa);

        return runTool(allocator, io, argv.items);
    }

    pub fn extractZstd(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, strip_components: u32) !ToolRunResult {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);

        try argv.append(allocator, "tar");
        try argv.append(allocator, "-xf");
        try argv.append(allocator, archive_path);
        try argv.append(allocator, "-C");
        try argv.append(allocator, dest_path);

        var strip_arg: ?[]const u8 = null;
        if (strip_components > 0) {
            strip_arg = try std.fmt.allocPrint(allocator, "--strip-components={d}", .{strip_components});
            try argv.append(allocator, strip_arg.?);
        }
        defer if (strip_arg) |sa| allocator.free(sa);

        return runTool(allocator, io, argv.items);
    }

    pub fn createGz(allocator: std.mem.Allocator, io: std.Io, src_dir_path: []const u8, out_tar_gz_path: []const u8) !ToolRunResult {
        return runTool(allocator, io, &.{
            "tar", "-czf", out_tar_gz_path, "-C", src_dir_path, ".",
        });
    }
};

pub const zstd = struct {
    pub fn decompress(allocator: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !ToolRunResult {
        return runTool(allocator, io, &.{
            "zstd", "-d", "-f", "-o", out_path, in_path,
        });
    }

    pub fn compress(allocator: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !ToolRunResult {
        return runTool(allocator, io, &.{
            "zstd", "-q", "-f", in_path, "-o", out_path,
        });
    }
};

pub const unzip = struct {
    pub fn extract(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8) !ToolRunResult {
        return runTool(allocator, io, &.{
            "unzip", "-q", archive_path, "-d", dest_path,
        });
    }
};
