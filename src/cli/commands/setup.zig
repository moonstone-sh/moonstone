const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const SetupCommand = struct {
    pub const name = "setup";
    pub const description = "Create lua and luac shims that delegate to moon exec";

    json: bool = false,
    force: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon setup [flags]
            \\
            \\Create shell shims for lua and luac (CMD on Windows, POSIX elsewhere). Each shim delegates to moon exec.
            \\The shim directory must be added to PATH explicitly.
            \\This command does not edit your shell profile or activate a project.
            \\
            \\Flags:
            \\  --force    Overwrite existing files
            \\  --json     Output results as JSON
            \\
        , .{});
    }

    pub fn run(self: SetupCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{});
        }

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        try std.Io.Dir.cwd().createDirPath(io, paths.shims);
        var shim_dir = try std.Io.Dir.cwd().openDir(io, paths.shims, .{});
        defer shim_dir.close(io);

        const moon_bin = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(moon_bin);

        // Create shims for common tools
        const tools = [_][]const u8{ "lua", "luac" };
        for (tools) |tool| {
            if (emitter) |e| try e.emit(io, .PROGRESS, tool, "creating-shim", .{});

            const windows = @import("builtin").os.tag == .windows;
            const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ tool, if (windows) ".cmd" else "" });
            defer allocator.free(filename);
            const escaped_bin = try escapeExecutable(allocator, moon_bin, windows);
            defer allocator.free(escaped_bin);
            const shim_content = if (windows)
                try std.fmt.allocPrint(allocator, "@echo off\r\nsetlocal DisableDelayedExpansion\r\n\"{s}\" exec -- {s} %*\r\nexit /b %errorlevel%\r\n", .{ escaped_bin, tool })
            else
                try std.fmt.allocPrint(allocator, "#!/bin/sh\nexec '{s}' exec -- '{s}' \"$@\"\n", .{ escaped_bin, tool });
            defer allocator.free(shim_content);

            if (!self.force) {
                if (shim_dir.access(io, filename, .{})) |_| {
                    if (emitter) |e| try e.emit(io, .WARN, tool, "shim-exists", .{ .msg = "Shim already exists, use --force to overwrite." });
                    if (!self.json) try stdout.print("Warning: shim for '{s}' already exists. Skipping.\n", .{tool});
                    continue;
                } else |_| {}
            }

            const f = try shim_dir.createFile(io, filename, .{});
            try f.writeStreamingAll(io, shim_content);
            f.close(io);

            // Make executable
            const abs_shim = try std.fs.path.join(allocator, &.{ paths.shims, filename });
            defer allocator.free(abs_shim);

            if (!windows) {
                const chmod_res = try std.process.run(allocator, io, .{
                    .argv = &.{ "chmod", "+x", abs_shim },
                });
                if (chmod_res.term != .exited or chmod_res.term.exited != 0) {
                    return error.ChmodFailed;
                }
                allocator.free(chmod_res.stdout);
                allocator.free(chmod_res.stderr);
            }

            if (!self.json) try stdout.print("Created shim: {s}\n", .{tool});
        }

        if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .shim_dir = paths.shims });
        } else {
            try stdout.print("\nSetup complete. Please ensure {s} is in your PATH.\n", .{paths.shims});
            if (@import("builtin").os.tag != .windows) try stdout.print("Example: export PATH=\"{s}:$PATH\"\n", .{paths.shims});
        }
    }
};

fn escapeExecutable(allocator: std.mem.Allocator, path: []const u8, windows: bool) ![]u8 {
    if (std.mem.indexOfAny(u8, path, "\r\n") != null) return error.UnrepresentableShimPath;
    var result = std.Io.Writer.Allocating.init(allocator);
    defer result.deinit();
    for (path) |c| {
        if (!windows and c == 39) {
            try result.writer.writeAll("'\\''");
        } else {
            try result.writer.writeByte(c);
            if (windows and c == '%') try result.writer.writeByte('%');
        }
    }
    return allocator.dupe(u8, result.writer.buffered());
}

test "shim executable paths preserve shell metacharacters" {
    const posix = try escapeExecutable(std.testing.allocator, "/tmp/Lua's $tools/moon", false);
    defer std.testing.allocator.free(posix);
    try std.testing.expectEqualStrings("/tmp/Lua'\\''s $tools/moon", posix);
    const windows = try escapeExecutable(std.testing.allocator, "C:\\100% tools\\moon.exe", true);
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqualStrings("C:\\100%% tools\\moon.exe", windows);
}
