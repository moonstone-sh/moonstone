const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const UninstallCommand = struct {
    pub const name = "uninstall";
    pub const description = "Remove the managed Moonstone CLI installation";

    preserve_config: bool = false,
    preserve_store: bool = false,
    force: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon uninstall [flags]
            \\
            \\Remove the managed Moonstone CLI installation and user state.
            \\
            \\Flags:
            \\  --preserve-config  Keep config.toml and the config directory
            \\  --preserve-store   Keep store artifacts and index metadata
            \\  --force            Allow deletion of externally redirected paths
            \\
        , .{});
    }

    pub fn run(self: UninstallCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
        defer paths.deinit(allocator);

        if (!self.force) {
            if (!self.preserve_store and (!isWithin(paths.data, paths.store) or !isWithin(paths.data, paths.index))) {
                try stdout.print("Refusing to remove externally redirected store or index paths. Re-run with `--force` after reviewing your configuration.\n", .{});
                return error.ExternalPathRequiresForce;
            }
            if (!isWithin(paths.data, paths.shims)) {
                try stdout.print("Refusing to remove externally redirected shims path: {s}. Re-run with `--force` after reviewing your configuration.\n", .{paths.shims});
                return error.ExternalPathRequiresForce;
            }
        }

        var failed = false;
        failed = !removeTree(io, paths.shims) or failed;
        failed = !removeTree(io, paths.tmp) or failed;
        failed = !removeTree(io, paths.cache) or failed;
        failed = !removeTree(io, paths.projects) or failed;
        if (!self.preserve_store) {
            failed = !removeTree(io, paths.store) or failed;
            failed = !removeTree(io, paths.index) or failed;
        }
        if (!self.preserve_config) failed = !removeTree(io, paths.config) or failed;

        const binary = try std.fs.path.join(allocator, &.{ paths.bin, "moon" });
        defer allocator.free(binary);
        std.Io.Dir.cwd().deleteFile(io, binary) catch |err| {
            if (err != error.FileNotFound) {
                try writeWarning(io, binary, err);
                failed = true;
            }
        };
        failed = !removeTree(io, paths.bin) or failed;

        if (failed) {
            try stdout.print("Moonstone partially uninstalled. Some paths could not be removed.\n", .{});
            return error.UninstallIncomplete;
        }
        try stdout.print("Moonstone uninstalled.\n", .{});
    }
};

fn isWithin(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or (std.mem.startsWith(u8, child, parent) and child.len > parent.len and std.fs.path.isSep(child[parent.len]));
}

fn removeTree(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
        if (err == error.FileNotFound) return true;
        writeWarning(io, path, err) catch {};
        return false;
    };
    return true;
}

fn writeWarning(io: std.Io, path: []const u8, err: anyerror) !void {
    const stderr = std.Io.File.stderr();
    var buf: [512]u8 = undefined;
    var writer = stderr.writer(io, &buf);
    try writer.interface.print("warning: could not remove {s}: {s}\n", .{ path, @errorName(err) });
    try writer.interface.flush();
}
