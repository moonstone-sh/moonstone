const std = @import("std");
const builtin = @import("builtin");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const ndjson = @import("ndjson.zig");

pub const SelfUninstallCommand = struct {
    pub const name = "uninstall";
    pub const description = "Uninstall the executable and shims; preserve data unless requested";
    yes: bool = false,
    json: bool = false,
    dry_run: bool = false,
    purge_data: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.writeAll("Usage: moon self uninstall [--yes] [--dry-run] [--purge-data] [--json]\n\nRemove this executable and Moonstone shims. Store, cache, configuration, and\nproject tracking are preserved by default. --purge-data removes the listed\nmanaged data paths too. --dry-run previews exact paths without modifying them.\nUse your package manager for an externally managed installation.\n");
    }

    pub fn run(self: SelfUninstallCommand, ctx: *router.Context) !void {
        try @import("self_install.zig").ensureSelfManaged(ctx, self.json);
        var paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
        defer paths.deinit(ctx.allocator);
        const executable = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
        defer ctx.allocator.free(executable);
        const config = try moonstone.platform.fs.resolve_config_file(ctx.allocator, ctx.env);
        defer ctx.allocator.free(config);
        const data_paths = [_][]const u8{ paths.store, paths.index, paths.cache, paths.downloads, paths.projects, paths.tmp };
        try safeDirectory(ctx, paths.shims);
        if (self.purge_data) for (data_paths) |path| try safeDirectory(ctx, path);
        const plan = .{ .executable = executable, .shims = paths.shims, .purge_data = self.purge_data, .data_paths = data_paths, .config_file = config, .data_preserved = !self.purge_data };
        if (self.dry_run) {
            if (self.json) {
                var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "self-uninstall");
                try emitter.terminate(ctx.io, name, "planned", plan);
            } else try showPlan(ctx.stdout, executable, paths.shims, &data_paths, config, self.purge_data);
            return;
        }
        if (!self.yes) {
            if (self.json) return error.ConfirmationRequired;
            try showPlan(ctx.stdout, executable, paths.shims, &data_paths, config, self.purge_data);
            try ctx.stdout.writeAll("Proceed? [y/N] ");
            try ctx.stdout.flush();
            var buffer: [64]u8 = undefined;
            const length = try std.Io.File.stdin().readStreaming(ctx.io, &.{&buffer});
            const reply = std.mem.trim(u8, buffer[0..length], " \t\r\n");
            if (!std.ascii.eqlIgnoreCase(reply, "y") and !std.ascii.eqlIgnoreCase(reply, "yes")) return error.UninstallationCancelled;
        }
        if (self.purge_data) {
            for (data_paths) |path| try removeDirectory(ctx.io, path);
            std.Io.Dir.cwd().deleteFile(ctx.io, config) catch |err| if (err != error.FileNotFound) return err;
        }
        try removeDirectory(ctx.io, paths.shims);
        // Windows holds the image open until this process exits. A short-lived
        // helper waits for this PID, deletes the image, then deletes its script.
        if (builtin.os.tag == .windows) try scheduleWindowsRemoval(ctx, executable) else try std.Io.Dir.cwd().deleteFile(ctx.io, executable);
        if (self.json) {
            var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, "self-uninstall");
            try emitter.terminate(ctx.io, name, if (builtin.os.tag == .windows) "scheduled" else "ok", plan);
        } else try ctx.stdout.print("Moonstone {s}. {s}\n", .{
            if (builtin.os.tag == .windows) "will finish executable removal after exit" else "uninstalled",
            if (self.purge_data) "Listed managed data was removed." else "Store, cache, configuration, and project tracking were preserved.",
        });
    }
};

fn showPlan(stdout: *std.Io.Writer, executable: []const u8, shims: []const u8, data: []const []const u8, config: []const u8, purge: bool) !void {
    try stdout.print("Remove executable: {s}\nRemove shims: {s}\n", .{ executable, shims });
    if (purge) {
        for (data) |path| try stdout.print("Remove managed data: {s}\n", .{path});
        try stdout.print("Remove configuration file: {s}\n", .{config});
    } else try stdout.writeAll("Preserve store, cache, configuration, and project tracking.\n");
}
fn removeDirectory(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(io, path) catch |err| if (err != error.FileNotFound) return err;
}
fn safeDirectory(ctx: *router.Context, path: []const u8) !void {
    const absolute = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, path, ctx.allocator) catch |err| switch (err) {
        error.FileNotFound => try std.fs.path.resolve(ctx.allocator, &.{path}),
        else => return err,
    };
    defer ctx.allocator.free(absolute);
    const parent = std.fs.path.dirname(absolute) orelse return error.UnsafeUninstallPath;
    if (std.fs.path.dirname(parent) == null or std.mem.eql(u8, absolute, parent)) return error.UnsafeUninstallPath;
    if (ctx.env.get("HOME") orelse ctx.env.get("USERPROFILE")) |home| if (std.mem.eql(u8, home, absolute)) return error.UnsafeUninstallPath;
    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.allocator);
    defer ctx.allocator.free(cwd);
    const relative = try std.fs.path.relative(ctx.allocator, cwd, null, absolute, cwd);
    defer ctx.allocator.free(relative);
    if (!std.fs.path.isAbsolute(relative) and !std.mem.eql(u8, relative, "..") and !std.mem.startsWith(u8, relative, "../") and !std.mem.startsWith(u8, relative, "..\\")) return error.UnsafeUninstallPath;
}
fn scheduleWindowsRemoval(ctx: *router.Context, executable: []const u8) !void {
    const directory = ctx.env.get("TEMP") orelse ctx.env.get("TMP") orelse return error.TemporaryDirectoryUnavailable;
    const pid = std.os.windows.GetCurrentProcessId();
    const script = try std.fmt.allocPrint(ctx.allocator, "{s}\\moonstone-uninstall-{d}.ps1", .{ directory, pid });
    defer ctx.allocator.free(script);
    const pid_text = try std.fmt.allocPrint(ctx.allocator, "{d}", .{pid});
    defer ctx.allocator.free(pid_text);
    const file = try std.Io.Dir.cwd().createFile(ctx.io, script, .{});
    try file.writeStreamingAll(ctx.io, "param([int]$parentId, [string]$executable)\n" ++
        "try { Wait-Process -Id $parentId -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $executable -Force -ErrorAction Stop } finally { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue }\n");
    file.close(ctx.io);
    _ = try std.process.spawn(ctx.io, .{ .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, pid_text, executable }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
}
