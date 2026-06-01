const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const fs = @import("../../platform/fs.zig");
const driver_mod = @import("../../store/driver.zig");
const links_mod = @import("../../store/links.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

/// Resolve a package from the global link registry.
/// Looks up links/<name> in the StoreIndex.
pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    _version_range: []const u8,
    index: driver_mod.StoreDriver,
    _options: options_mod.ResolveOptions,
    env: ?*std.process.Environ.Map,
) !candidate_mod.Candidate {
    _ = _version_range;
    _ = _options;
    _ = io;
    _ = env;

    var ls = links_mod.LinkStore.init(@constCast(&index));
    const entry = (try ls.get(pkg_name)) orelse return error.PackageNotFound;
    defer {
        var mut_entry = entry;
        mut_entry.deinit(allocator);
    }

    return candidate_mod.Candidate{
        .name = try allocator.dupe(u8, entry.name),
        .version = try allocator.dupe(u8, entry.version),
        .kind = entry.kind,
        .artifact_hash = try allocator.dupe(u8, "link"),
        .local_path = try allocator.dupe(u8, entry.path),
        .origin = .{ .link = try allocator.dupe(u8, entry.path) },
    };
}
