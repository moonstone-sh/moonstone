const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const router = @import("../router.zig");

const ReleaseManifest = struct {
    version: []const u8,
    artifacts: []const Artifact,

    const Artifact = struct {
        name: []const u8,
        target: []const u8,
        sha256: []const u8,
    };
};

pub const SelfInstallCommand = struct {
    pub const name = "install";
    pub const description = "Install a Moonstone CLI release";

    version: ?[]const u8 = null,
    latest: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon install (--version <version> | --latest)
            \\
            \\Install a Moonstone CLI release into the managed user data directory.
            \\
            \\Flags:
            \\  --version <v>  Install an exact release version
            \\  --latest       Install the latest published release
            \\
        , .{});
    }

    pub fn run(self: SelfInstallCommand, ctx: *router.Context) !void {
        const channel = build_options.distribution_channel;
        const is_standalone = std.mem.eql(u8, channel, "standalone") or std.mem.eql(u8, channel, "default") or std.mem.eql(u8, channel, "binary");
        if (!is_standalone) {
            try printManagedInstallMessage(ctx.stdout, channel);
            return error.ManagedDistributionChannel;
        }

        if ((self.version == null) == !self.latest) return error.ExactlyOneVersionSelectorRequired;

        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
        defer paths.deinit(allocator);

        try std.Io.Dir.cwd().createDirPath(io, paths.tmp);
        const destination = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(destination);
        const destination_dir = std.fs.path.dirname(destination) orelse return error.InvalidExecutablePath;
        checkWritable(allocator, io, destination_dir) catch |err| {
            try stdout.print("Cannot install Moonstone to {s}: {s}. Fix the directory permissions and retry.\n", .{ destination, @errorName(err) });
            return err;
        };

        const base_url = ctx.env.get("MOONSTONE_RELEASES_URL") orelse "https://moonstone.sh/releases";
        const timeout = moonstone.platform.http.get_http_config(allocator, ctx.env, io).timeout_ms;
        const selected_version = if (self.latest) blk: {
            const latest_url = try std.fmt.allocPrint(allocator, "{s}/latest", .{base_url});
            defer allocator.free(latest_url);
            const body = try moonstone.platform.http.fetchGetBody(allocator, io, latest_url, null, timeout);
            defer allocator.free(body);
            break :blk try allocator.dupe(u8, std.mem.trim(u8, body, " \t\r\n"));
        } else try allocator.dupe(u8, self.version.?);
        defer allocator.free(selected_version);
        if (selected_version.len == 0 or std.mem.indexOfScalar(u8, selected_version, '/') != null) return error.InvalidVersion;

        const manifest_url = try std.fmt.allocPrint(allocator, "{s}/{s}/release-manifest.json", .{ base_url, selected_version });
        defer allocator.free(manifest_url);
        const manifest_body = try moonstone.platform.http.fetchGetBody(allocator, io, manifest_url, null, timeout);
        defer allocator.free(manifest_body);
        const parsed = try std.json.parseFromSlice(ReleaseManifest, allocator, manifest_body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const target = try hostTarget(allocator);
        defer allocator.free(target);
        const artifact = for (parsed.value.artifacts) |item| {
            if (std.mem.eql(u8, item.target, target)) break item;
        } else return error.NoReleaseForTarget;

        const archive_url = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base_url, selected_version, artifact.name });
        defer allocator.free(archive_url);
        const archive = try moonstone.platform.http.fetchGetBody(allocator, io, archive_url, null, timeout);
        defer allocator.free(archive);
        try verifySha256(artifact.sha256, archive);

        const work_dir = try std.fs.path.join(allocator, &.{ paths.tmp, "self-install" });
        defer allocator.free(work_dir);
        std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, work_dir);
        const archive_path = try std.fs.path.join(allocator, &.{ work_dir, "moon.tar.gz" });
        defer allocator.free(archive_path);
        const archive_file = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        defer archive_file.close(io);
        try archive_file.writeStreamingAll(io, archive);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "tar", "-xf", archive_path, "-C", work_dir },
            .expand_arg0 = .expand,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.ArchiveExtractionFailed;

        const extracted = try std.fs.path.join(allocator, &.{ work_dir, "moon" });
        defer allocator.free(extracted);
        std.Io.Dir.deleteFileAbsolute(io, destination) catch {};
        try std.Io.Dir.renameAbsolute(extracted, destination, io);

        try stdout.print("Installed Moonstone {s} to {s}\nRun `moon setup` to configure shims.\n", .{ selected_version, destination });
    }
};

fn printManagedInstallMessage(stdout: *std.Io.Writer, channel: []const u8) !void {
    if (std.mem.eql(u8, channel, "homebrew")) {
        try stdout.print(
            \\Moonstone was installed via Homebrew.
            \\Self-installation is disabled for package-managed bundles.
            \\To upgrade Moonstone, run:
            \\  brew upgrade moonstone
            \\
        , .{});
    } else if (std.mem.eql(u8, channel, "aur") or std.mem.eql(u8, channel, "arch")) {
        try stdout.print(
            \\Moonstone was installed via Arch User Repository (AUR).
            \\Self-installation is disabled for package-managed bundles.
            \\To upgrade Moonstone, run:
            \\  yay -S moonstone-bin
            \\(or: paru -S moonstone-bin)
            \\
        , .{});
    } else if (std.mem.eql(u8, channel, "nix")) {
        try stdout.print(
            \\Moonstone was installed via Nix.
            \\Self-installation is disabled for package-managed bundles.
            \\To upgrade Moonstone, run:
            \\  nix profile upgrade moonstone
            \\(or: nix-env -u moonstone)
            \\
        , .{});
    } else if (std.mem.eql(u8, channel, "apt") or std.mem.eql(u8, channel, "deb")) {
        try stdout.print(
            \\Moonstone was installed via APT package manager.
            \\Self-installation is disabled for package-managed bundles.
            \\To upgrade Moonstone, run:
            \\  sudo apt update && sudo apt install --only-upgrade moonstone
            \\
        , .{});
    } else if (std.mem.eql(u8, channel, "alpine") or std.mem.eql(u8, channel, "apk")) {
        try stdout.print(
            \\Moonstone was installed via APK package manager.
            \\Self-installation is disabled for package-managed bundles.
            \\To upgrade Moonstone, run:
            \\  sudo apk update && sudo apk upgrade moonstone
            \\
        , .{});
    } else {
        try stdout.print(
            \\Moonstone was installed via distribution channel '{s}'.
            \\Self-installation is disabled for package-managed bundles.
            \\Please upgrade Moonstone using your distribution's package manager.
            \\
        , .{channel});
    }
}

fn checkWritable(allocator: std.mem.Allocator, io: std.Io, bin_dir: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ bin_dir, ".moon-write-check" });
    defer allocator.free(path);
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return error.ManagedBinNotWritable;
    file.close(io);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn verifySha256(expected_prefixed: []const u8, bytes: []const u8) !void {
    const expected = if (std.mem.startsWith(u8, expected_prefixed, "sha256:")) expected_prefixed[7..] else expected_prefixed;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var encoded: [digest.len * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x}", .{digest}) catch unreachable;
    if (!std.ascii.eqlIgnoreCase(expected, &encoded)) return error.ReleaseChecksumMismatch;
}

fn hostTarget(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArch,
    };
    const os = switch (builtin.os.tag) {
        .linux => "linux-gnu",
        .macos => "macos",
        .windows => "windows-msvc",
        .freebsd => "freebsd",
        else => return error.UnsupportedOS,
    };
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch, os });
}
