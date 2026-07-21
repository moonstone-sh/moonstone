const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const router = @import("../router.zig");
const store_purge = @import("store_purge.zig");
const cache_clean = @import("cache_clean.zig");
const config_reset = @import("config_reset.zig");
const ndjson = @import("ndjson.zig");

pub const SelfUninstallCommand = struct {
    pub const name = "uninstall";
    pub const description = "Remove Moonstone-owned data and user state";

    yes: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon self uninstall [-y | --yes] [flags]
            \\
            \\Remove Moonstone-owned user state, shims, caches, store, and configuration.
            \\
            \\Flags:
            \\  -y, --yes    Confirm uninstallation without interactive prompt
            \\  --json       Output result as JSON
            \\
        , .{});
    }

    pub fn run(self: SelfUninstallCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        if (build_options.installation_ownership == .externally_managed) {
            if (!self.json) {
                try stdout.print(
                    "\nThis Moonstone installation is managed by {s}. Use {s} to uninstall Moonstone.\n\n",
                    .{ build_options.distribution_label, build_options.distribution_label },
                );
            }
            return error.ManagedDistributionChannel;
        }

        if (!self.yes) {
            if (self.json) return error.ConfirmationRequired;

            try stdout.print("Warning: This will purge all local Moonstone store artifacts, caches, shims, and configuration.\nProceed? [y/N] ", .{});
            try stdout.flush();

            var buf: [64]u8 = undefined;
            const stdin_file = std.Io.File.stdin();
            const n = stdin_file.readStreaming(io, &.{&buf}) catch 0;
            const line = buf[0..n];

            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (!std.ascii.eqlIgnoreCase(trimmed, "y") and !std.ascii.eqlIgnoreCase(trimmed, "yes")) {
                try stdout.print("Uninstallation cancelled.\n", .{});
                return error.UninstallationCancelled;
            }
        }

        // 1. Reuse store purge, cache clean, and config reset
        try store_purge.purgeStore(allocator, io, stdout, ctx.env, self.json);
        try cache_clean.cleanCache(allocator, io, stdout, ctx.env, self.json);
        try config_reset.resetConfig(allocator, io, stdout, ctx.env, self.json);

        // 2. Remove remaining shims and project tracking
        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
        defer paths.deinit(allocator);

        std.Io.Dir.cwd().deleteTree(io, paths.shims) catch {};
        std.Io.Dir.cwd().deleteTree(io, paths.projects) catch {};
        std.Io.Dir.cwd().deleteTree(io, paths.data) catch {};

        const exe_path = std.process.executablePathAlloc(io, allocator) catch null;
        defer if (exe_path) |p| allocator.free(p);

        if (self.json) {
            var emitter = ndjson.Emitter.init(allocator, stdout, name);
            try emitter.terminate(io, name, "ok", .{
                .executable_path = exe_path,
                .shims = paths.shims,
                .data = paths.data,
            });
        } else {
            try stdout.print("\nMoonstone user data, store, shims, and configuration have been removed.\n", .{});
            if (exe_path) |p| {
                try stdout.print("To complete uninstallation, remove the Moonstone binary executable manually:\n  rm {s}\n", .{p});
            }
        }
    }
};
