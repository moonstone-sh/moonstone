const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const SetupCommand = struct {
    pub const name = "setup";
    pub const description = "Configure Moonstone shell integration and global shims";

    json: bool = false,
    force: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon setup [flags]
            \\
            \\Configures Moonstone shell integration by:
            \\  1. Creating global shims (lua, moon exec, etc.) in the shim directory.
            \\  2. (Future) Attempting to update your shell profile (~/.zshrc, etc.).
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
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.shims);
        var shim_dir = try std.Io.Dir.cwd().openDir(io, paths.shims, .{});
        defer shim_dir.close(io);

        const moon_bin = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(moon_bin);

        // Create shims for common tools
        const tools = [_][]const u8{ "lua", "luac" };
        for (tools) |tool| {
            if (emitter) |e| try e.emit(io, .PROGRESS, tool, "creating-shim", .{});
            
            // Create a small shell script shim
            const shim_content = try std.fmt.allocPrint(allocator, 
                \\#!/bin/sh
                \\exec "{s}" exec -- "{s}" "$@"
                \\
            , .{ moon_bin, tool });
            defer allocator.free(shim_content);

            if (!self.force) {
                if (shim_dir.access(io, tool, .{})) |_| {
                    if (emitter) |e| try e.emit(io, .WARN, tool, "shim-exists", .{ .msg = "Shim already exists, use --force to overwrite." });
                    if (!self.json) try stdout.print("Warning: shim for '{s}' already exists. Skipping.\n", .{tool});
                    continue;
                } else |_| {}
            }

            const f = try shim_dir.createFile(io, tool, .{});
            try f.writeStreamingAll(io, shim_content);
            f.close(io);

            // Make executable
            const abs_shim = try std.fs.path.join(allocator, &.{ paths.shims, tool });
            defer allocator.free(abs_shim);
            
            const chmod_res = try std.process.run(allocator, io, .{
                .argv = &.{ "chmod", "+x", abs_shim },
            });
            if (chmod_res.term != .exited or chmod_res.term.exited != 0) {
                return error.ChmodFailed;
            }

            if (!self.json) try stdout.print("Created shim: {s}\n", .{tool});
        }

        if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .shim_dir = paths.shims });
        } else {
            try stdout.print("\nSetup complete. Please ensure {s} is in your PATH.\n", .{paths.shims});
            try stdout.print("Example: export PATH=\"{s}:$PATH\"\n", .{paths.shims});
        }
    }
};
