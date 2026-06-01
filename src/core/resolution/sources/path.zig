const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

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
    const abs_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch blk: {
        if (std.fs.path.isAbsolute(path)) break :blk try allocator.dupe(u8, path);
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, path });
    };
    defer allocator.free(abs_path);

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
