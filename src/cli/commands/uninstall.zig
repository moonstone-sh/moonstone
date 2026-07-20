const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const router = @import("../router.zig");

pub const UninstallCommand = struct {
    pub const name = "uninstall";
    pub const description = "Remove Moonstone CLI installation or user state";

    preserve_config: bool = false,
    preserve_store: bool = false,
    clean_user_data: bool = false,
    force: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon uninstall [flags]
            \\
            \\Remove Moonstone CLI installation or local user state.
            \\
            \\Flags:
            \\  --preserve-config  Keep config.toml and the config directory
            \\  --preserve-store   Keep store artifacts and index metadata
            \\  --clean-user-data  Remove user state (~/.local/share/moonstone) for package-managed bundles
            \\  --force            Allow deletion of externally redirected paths
            \\
        , .{});
    }

    pub fn run(self: UninstallCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const channel = build_options.distribution_channel;
        const is_standalone = std.mem.eql(u8, channel, "standalone") or std.mem.eql(u8, channel, "default") or std.mem.eql(u8, channel, "binary");

        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
        defer paths.deinit(allocator);

        if (!is_standalone) {
            const exe_path = std.process.executablePathAlloc(io, allocator) catch null;
            defer if (exe_path) |p| allocator.free(p);

            try stdout.print("Moonstone binary ownership breakdown:\n", .{});
            try stdout.print("  Distribution channel: {s}\n", .{channel});
            if (exe_path) |p| {
                try stdout.print("  Binary path:          {s}\n", .{p});
            }
            try printPackageManagerUninstallInstructions(stdout, channel);

            try stdout.print(
                \\
                \\Moonstone will NOT delete the binary managed by {s}.
                \\
            , .{channel});

            // Clean up user data
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

            if (failed) {
                try stdout.print("Moonstone user state partially cleaned up. Some paths could not be removed.\n", .{});
                return error.UninstallIncomplete;
            }
            try stdout.print("Moonstone user state cleaned up (~/.local/share/moonstone).\nUser project files remain user-owned and untouched.\n", .{});
            return;
        }

        // Standalone channel handling
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

fn printPackageManagerUninstallInstructions(stdout: *std.Io.Writer, channel: []const u8) !void {
    if (std.mem.eql(u8, channel, "homebrew")) {
        try stdout.print("  To uninstall binary:  brew uninstall moonstone\n", .{});
    } else if (std.mem.eql(u8, channel, "aur") or std.mem.eql(u8, channel, "arch")) {
        try stdout.print("  To uninstall binary:  sudo pacman -R moonstone-bin (or yay -R moonstone-bin)\n", .{});
    } else if (std.mem.eql(u8, channel, "nix")) {
        try stdout.print("  To uninstall binary:  nix profile remove moonstone (or nix-env -e moonstone)\n", .{});
    } else if (std.mem.eql(u8, channel, "apt") or std.mem.eql(u8, channel, "deb")) {
        try stdout.print("  To uninstall binary:  sudo apt remove moonstone\n", .{});
    } else if (std.mem.eql(u8, channel, "alpine") or std.mem.eql(u8, channel, "apk")) {
        try stdout.print("  To uninstall binary:  sudo apk del moonstone\n", .{});
    } else {
        try stdout.print("  To uninstall binary:  use your package manager for '{s}'\n", .{channel});
    }
}

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
