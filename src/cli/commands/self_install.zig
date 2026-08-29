const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const router = @import("../router.zig");
const ndjson = @import("ndjson.zig");

pub const ReleaseSelection = union(enum) {
    latest,
    exact: []const u8,

    pub fn appendInstallerArgs(self: ReleaseSelection, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
        switch (self) {
            .latest => try list.append(allocator, "--latest"),
            .exact => |version| {
                try list.append(allocator, "--version");
                try list.append(allocator, version);
            },
        }
    }
};

pub const SelfInstallCommand = struct {
    pub const name = "install";
    pub const description = "Install or update a Moonstone CLI release";

    version: ?[]const u8 = null,
    latest: bool = false,
    apply: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon self install (--version <version> | --latest) [--apply] [flags]
            \\
            \\Install or update a Moonstone CLI release.
            \\
            \\Flags:
            \\  --apply        Download and run the installer immediately
            \\  -v, --version  Install an exact Moonstone release
            \\  --latest       Install the latest published Moonstone release
            \\  --json         Output result as JSON
            \\
        , .{});
    }

    pub fn releaseSelection(self: SelfInstallCommand) !ReleaseSelection {
        if (self.version != null and self.latest) {
            return error.ConflictingReleaseSelection;
        }
        if (self.version) |version| {
            try validateReleaseVersion(version);
            return .{ .exact = version };
        }
        if (self.latest) {
            return .latest;
        }
        return error.MissingReleaseSelection;
    }

    pub fn run(self: SelfInstallCommand, ctx: *router.Context) !void {
        const selection = try self.releaseSelection();

        try ensureSelfManaged(ctx, self.json);

        if (!self.apply) {
            return printInstallerCommand(ctx, build_options.default_installer_url, selection, self.json);
        }

        return applyInstaller(ctx, build_options.default_installer_url, selection, self.json);
    }
};

pub fn validateReleaseVersion(version: []const u8) !void {
    if (version.len == 0 or version.len > 64) return error.InvalidReleaseVersion;
    for (version) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '+' => {},
            else => return error.InvalidReleaseVersion,
        }
    }
}

pub fn ensureSelfManaged(ctx: *router.Context, is_json: bool) !void {
    if (build_options.installation_ownership == .externally_managed) {
        if (!is_json) {
            try ctx.stdout.print(
                "\nThis Moonstone installation is managed by {s}. Use {s} to update or reinstall Moonstone.\n\n",
                .{ build_options.distribution_label, build_options.distribution_label },
            );
        }
        return error.ManagedDistributionChannel;
    }
}

fn printInstallerCommand(ctx: *router.Context, installer_url: []const u8, selection: ReleaseSelection, is_json: bool) !void {
    if (is_json) {
        const command_str = switch (selection) {
            .latest => try std.fmt.allocPrint(ctx.allocator, "curl -fsSL {s} | sh -s -- --latest", .{installer_url}),
            .exact => |v| try std.fmt.allocPrint(ctx.allocator, "curl -fsSL {s} | sh -s -- --version {s}", .{ installer_url, v }),
        };
        defer ctx.allocator.free(command_str);

        var emitter = ndjson.Emitter.init(ctx.allocator, ctx.stdout, SelfInstallCommand.name);
        try emitter.terminate(ctx.io, SelfInstallCommand.name, "ok", .{
            .installer_url = installer_url,
            .bootstrap_command = command_str,
            .apply = false,
        });
    } else {
        try ctx.stdout.print("\nRun this command in your terminal:\n\n", .{});
        switch (selection) {
            .latest => try ctx.stdout.print("  curl -fsSL {s} | sh -s -- --latest\n\n", .{installer_url}),
            .exact => |v| try ctx.stdout.print("  curl -fsSL {s} | sh -s -- --version {s}\n\n", .{ installer_url, v }),
        }
        try ctx.stdout.print("Or run again with --apply.\n", .{});
    }
}

fn applyInstaller(ctx: *router.Context, installer_url: []const u8, selection: ReleaseSelection, is_json: bool) !void {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => try applyPosixInstaller(ctx, installer_url, selection, is_json),
        else => {
            if (!is_json) {
                try ctx.stdout.print("Automatic --apply installer execution is not supported on this platform.\n", .{});
            }
            return error.UnsupportedSelfInstallPlatform;
        },
    }
}

fn applyPosixInstaller(ctx: *router.Context, installer_url: []const u8, selection: ReleaseSelection, is_json: bool) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, ctx.stdout, SelfInstallCommand.name);
        try emitter.emit(io, .INFO, SelfInstallCommand.name, "downloading installer script", .{ .url = installer_url });
    } else {
        try ctx.stdout.print("Downloading installer script from {s}...\n", .{installer_url});
        try ctx.stdout.flush();
    }

    const timeout_ms = 10000;
    const installer_body = moonstone.platform.http.fetchGetBody(allocator, io, installer_url, null, timeout_ms) catch |err| {
        if (!is_json) {
            try ctx.stdout.print("Failed to download installer script from {s}: {s}\n", .{ installer_url, @errorName(err) });
        }
        return err;
    };
    defer allocator.free(installer_body);

    if (installer_body.len > 2 * 1024 * 1024) {
        if (!is_json) {
            try ctx.stdout.print("Installer script exceeds maximum allowed size.\n", .{});
        }
        return error.InstallerScriptOversized;
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "/bin/sh");
    try argv.append(allocator, "-s");
    try argv.append(allocator, "--");
    try selection.appendInstallerArgs(&argv, allocator);

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, ctx.stdout, SelfInstallCommand.name);
        try emitter.emit(io, .INFO, SelfInstallCommand.name, "executing installer script", .{ .installer_url = installer_url });
    } else {
        try ctx.stdout.print("Executing Moonstone installer...\n", .{});
        try ctx.stdout.flush();
    }

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        // The installer is an implementation detail of --apply. Never let
        // its human stdout contaminate the JSON event stream.
        .stdout = if (is_json) .ignore else .inherit,
        .stderr = .inherit,
    }) catch |err| {
        if (!is_json) {
            try ctx.stdout.print("Failed to spawn /bin/sh installer process: {s}\n", .{@errorName(err)});
        }
        return error.InstallerProcessFailed;
    };

    if (child.stdin) |*file| {
        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        writer.interface.writeAll(installer_body) catch |err| {
            file.close(io);
            _ = child.wait(io) catch {};
            return err;
        };
        writer.interface.flush() catch {};
        file.close(io);
        child.stdin = null;
    }

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                if (!is_json) {
                    try ctx.stdout.print("Moonstone installer exited with status {d}.\n", .{code});
                }
                return error.InstallerFailed;
            }
        },
        .signal => |sig| {
            if (!is_json) {
                try ctx.stdout.print("Moonstone installer terminated by signal {d}.\n", .{@intFromEnum(sig)});
            }
            return error.InstallerTerminatedBySignal;
        },
        else => return error.InstallerProcessFailed,
    }

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, ctx.stdout, SelfInstallCommand.name);
        try emitter.terminate(io, SelfInstallCommand.name, "ok", .{
            .installer_url = installer_url,
            .apply = true,
        });
    }
}

test "releaseSelection validation" {
    const cmd1 = SelfInstallCommand{ .latest = true };
    const sel1 = try cmd1.releaseSelection();
    try std.testing.expect(sel1 == .latest);

    const cmd2 = SelfInstallCommand{ .version = "0.3.24" };
    const sel2 = try cmd2.releaseSelection();
    switch (sel2) {
        .exact => |v| try std.testing.expectEqualStrings("0.3.24", v),
        .latest => return error.TestUnexpectedResult,
    }

    const cmd3 = SelfInstallCommand{};
    try std.testing.expectError(error.MissingReleaseSelection, cmd3.releaseSelection());

    const cmd4 = SelfInstallCommand{ .latest = true, .version = "0.3.24" };
    try std.testing.expectError(error.ConflictingReleaseSelection, cmd4.releaseSelection());
}

test "validateReleaseVersion rules" {
    try validateReleaseVersion("0.3.24");
    try validateReleaseVersion("1.0.0-rc.1+build123");

    try std.testing.expectError(error.InvalidReleaseVersion, validateReleaseVersion(""));
    try std.testing.expectError(error.InvalidReleaseVersion, validateReleaseVersion("0.3.24; rm -rf /"));
    try std.testing.expectError(error.InvalidReleaseVersion, validateReleaseVersion("0.3.24\n"));
    try std.testing.expectError(error.InvalidReleaseVersion, validateReleaseVersion("0.3.24|sh"));
    try std.testing.expectError(error.InvalidReleaseVersion, validateReleaseVersion("version 0.3.24"));
}
