const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const error_context = @import("../../diagnostics/error_context.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

/// Convert the absolute path used while resolving/materializing a local
/// dependency into the locator persisted in moonstone.lock. A relative
/// locator is stable when a checkout (including sibling path dependencies) is
/// moved as a unit. Windows paths on another volume cannot be made relative;
/// std.fs.path.relative intentionally preserves those as absolute paths.
pub fn lockSource(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    resolved_path: []const u8,
) ![]const u8 {
    const relative = try std.fs.path.relative(allocator, project_root, null, project_root, resolved_path);
    if (relative.len != 0) return relative;

    allocator.free(relative);
    return allocator.dupe(u8, ".");
}

/// Resolve a path source from moonstone.lock against the current project
/// root. Absolute sources from older lockfiles remain supported, while new
/// relative sources follow a relocated checkout.
pub fn resolveLockSource(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    source: []const u8,
) ![]const u8 {
    return std.fs.path.resolve(allocator, &.{ project_root, source });
}

pub fn lockSourceNeedsMigration(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    source: []const u8,
) !bool {
    if (!std.fs.path.isAbsolute(source)) return false;
    const portable = try lockSource(allocator, project_root, source);
    defer allocator.free(portable);
    return !std.fs.path.isAbsolute(portable);
}

/// Resolve a package from a local filesystem path.
/// Reads moonstone.toml at the target path to discover name/version/kind.
/// Falls back to directory basename if no moonstone.toml is present.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    _version_range: []const u8,
    _options: options_mod.ResolveOptions,
) !candidate_mod.Candidate {
    _ = _version_range;
    _ = _options;

    const path = pkg_name;
    const abs_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ try std.process.currentPathAlloc(io, allocator), path });
    defer allocator.free(abs_path);

    var source_dir = std.Io.Dir.cwd().openDir(io, abs_path, .{}) catch {
        error_context.setFmt(allocator, "Local path dependency at '{s}' is unavailable. Restore the directory or update the dependency path, then run 'moon sync --update'.", .{abs_path});
        return error.LocalSourceUnavailable;
    };
    source_dir.close(io);

    const mt_path = try std.fs.path.join(allocator, &.{ abs_path, "moonstone.toml" });
    defer allocator.free(mt_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, mt_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            return candidate_mod.Candidate{
                .name = try allocator.dupe(u8, std.fs.path.basename(path)),
                .version = try allocator.dupe(u8, "0.0.0"),
                .kind = .lib,
                .artifact_hash = try allocator.dupe(u8, "path"),
                .local_path = try allocator.dupe(u8, abs_path),
                .origin = .{ .path = try allocator.dupe(u8, abs_path) },
            };
        }
        return err;
    };
    defer allocator.free(content);

    var mt = try manifest.MoonstoneToml.parse(allocator, content);
    defer mt.deinit(allocator);

    return candidate_mod.Candidate{
        .name = try allocator.dupe(u8, mt.package.name),
        .version = try allocator.dupe(u8, mt.package.version),
        .kind = mt.package.kind,
        .artifact_hash = try allocator.dupe(u8, "path"),
        .local_path = try allocator.dupe(u8, abs_path),
        .origin = .{ .path = try allocator.dupe(u8, abs_path) },
    };
}

test "path lock source is relative to the project and resolves after relocation" {
    const allocator = std.testing.allocator;
    const project_root = if (@import("builtin").os.tag == .windows)
        "C:\\work\\checkout\\app"
    else
        "/work/checkout/app";
    const dependency = if (@import("builtin").os.tag == .windows)
        "C:\\work\\checkout\\packages\\shared"
    else
        "/work/checkout/packages/shared";
    const relocated_root = if (@import("builtin").os.tag == .windows)
        "C:\\other\\clone\\app"
    else
        "/other/clone/app";
    const relocated_dependency = if (@import("builtin").os.tag == .windows)
        "C:\\other\\clone\\packages\\shared"
    else
        "/other/clone/packages/shared";

    const source = try lockSource(allocator, project_root, dependency);
    defer allocator.free(source);
    try std.testing.expect(!std.fs.path.isAbsolute(source));

    const resolved = try resolveLockSource(allocator, relocated_root, source);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(relocated_dependency, resolved);
}

test "path lock source preserves legacy absolute replay" {
    const allocator = std.testing.allocator;
    const project_root = if (@import("builtin").os.tag == .windows) "C:\\clone\\app" else "/clone/app";
    const absolute_source = if (@import("builtin").os.tag == .windows) "C:\\legacy\\shared" else "/legacy/shared";

    const resolved = try resolveLockSource(allocator, project_root, absolute_source);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(absolute_source, resolved);
}
