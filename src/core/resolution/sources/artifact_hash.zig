const std = @import("std");
const driver_mod = @import("../../store/driver.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    artifact_hash: []const u8,
    index: driver_mod.StoreDriver,
    _options: options_mod.ResolveOptions,
) !candidate_mod.Candidate {
    _ = pkg_name;
    _ = _options;

    const cand = try index.get_candidate_by_hash(artifact_hash) orelse return error.ArtifactNotFound;
    var mut_cand = cand;
    defer mut_cand.deinit(allocator);

    // Verify path exists
    std.Io.Dir.cwd().access(io, mut_cand.path, .{}) catch {
        return error.ArtifactNotFound;
    };

    return candidate_mod.Candidate{
        .name = try allocator.dupe(u8, mut_cand.name),
        .version = try allocator.dupe(u8, mut_cand.version),
        .kind = mut_cand.kind,
        .artifact_hash = try allocator.dupe(u8, artifact_hash),
        .lua_abi = if (mut_cand.lua_abi) |a| try allocator.dupe(u8, a) else null,
        .local_path = try allocator.dupe(u8, mut_cand.path),
        .origin = .{ .artifact_hash = try allocator.dupe(u8, artifact_hash) },
        .location = .local_store,
    };
}
