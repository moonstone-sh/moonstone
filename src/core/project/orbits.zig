const std = @import("std");
const manifest = @import("../domain/manifest.zig");

pub const OrbitDecl = struct {
    name: ?[]const u8,
    path: []const u8,
};

pub const OrbitRef = struct {
    name: []const u8,
    path: []const u8,
    package_name: []const u8,
    interpreter_name: []const u8,
    interpreter_version: []const u8,
    interpreter_abi: ?[]const u8,

    pub fn deinit(self: *OrbitRef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.package_name);
        allocator.free(self.interpreter_name);
        allocator.free(self.interpreter_version);
        if (self.interpreter_abi) |abi| allocator.free(abi);
    }
};

pub fn resolveOrbits(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8, root_manifest: *const manifest.MoonstoneToml) ![]OrbitRef {
    var resolved = std.ArrayList(OrbitRef).empty;
    errdefer {
        for (resolved.items) |*r| r.deinit(allocator);
        resolved.deinit(allocator);
    }

    for (root_manifest.orbits.items) |member_path| {
        // Resolve orbit path relative to root
        const orbit_abs_path = try std.fs.path.join(allocator, &.{ root_path, member_path });
        defer allocator.free(orbit_abs_path);

        const manifest_path = try std.fs.path.join(allocator, &.{ orbit_abs_path, "moonstone.toml" });
        defer allocator.free(manifest_path);

        const manifest_content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                // Return a specific error or use standard missing
                return error.OrbitManifestNotFound;
            }
            return err;
        };
        defer allocator.free(manifest_content);

        var orbit_mt = try manifest.MoonstoneToml.parse(allocator, manifest_content);
        defer orbit_mt.deinit(allocator);

        if (orbit_mt.runtime.name.len == 0) {
            return error.OrbitMissingInterpreter;
        }

        const name = try allocator.dupe(u8, orbit_mt.package.name); // Default to package name
        const pkg_name = try allocator.dupe(u8, orbit_mt.package.name);
        const int_name = try allocator.dupe(u8, orbit_mt.runtime.name);
        const int_version = try allocator.dupe(u8, orbit_mt.runtime.version);
        const int_abi = if (orbit_mt.runtime.abi.len > 0) try allocator.dupe(u8, orbit_mt.runtime.abi) else null;
        const o_path = try allocator.dupe(u8, orbit_abs_path);

        try resolved.append(allocator, .{
            .name = name,
            .path = o_path,
            .package_name = pkg_name,
            .interpreter_name = int_name,
            .interpreter_version = int_version,
            .interpreter_abi = int_abi,
        });
    }

    return try resolved.toOwnedSlice(allocator);
}
