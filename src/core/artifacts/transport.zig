const std = @import("std");

pub const TransportSchema = enum {
    moonstone_artifact_transport_v1,

    pub fn toString(self: TransportSchema) []const u8 {
        return switch (self) {
            .moonstone_artifact_transport_v1 => "moonstone:artifact-transport:v1",
        };
    }
};

pub const TransportInfo = struct {
    artifact_hash: []const u8,
    transport_schema: []const u8 = "moonstone:artifact-transport:v1",
    target: []const u8,
    transport_path: []const u8,
    compressed_size: u64 = 0,
    uncompressed_size: u64 = 0,

    pub fn deinit(self: *TransportInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_hash);
        allocator.free(self.target);
        allocator.free(self.transport_path);
    }
};

pub fn encodeArtifactTransport(
    allocator: std.mem.Allocator,
    io: std.Io,
    cas_path: []const u8,
    expected_artifact_hash: []const u8,
    target: []const u8,
    out_transport_path: []const u8,
) !TransportInfo {
    var dir = std.Io.Dir.cwd().openDir(io, cas_path, .{ .iterate = true }) catch {
        return error.ArtifactLocalMissing;
    };
    defer dir.close(io);

    const hash_mod = @import("../identity/hash.zig");
    const raw_hash = try hash_mod.artifact_hash(allocator, io, dir);
    defer allocator.free(raw_hash);

    const computed_hash = try std.fmt.allocPrint(allocator, "b3:{s}", .{raw_hash});
    defer allocator.free(computed_hash);

    if (!std.mem.eql(u8, computed_hash, expected_artifact_hash)) {
        return error.ArtifactLocalHashMismatch;
    }

    const archive = @import("../archive/root.zig");
    archive.createTarGz(allocator, io, cas_path, out_transport_path) catch {
        return error.ArtifactEncodingFailed;
    };

    return TransportInfo{
        .artifact_hash = try allocator.dupe(u8, expected_artifact_hash),
        .transport_schema = "moonstone:artifact-transport:v1",
        .target = try allocator.dupe(u8, target),
        .transport_path = try allocator.dupe(u8, out_transport_path),
        .compressed_size = 1024,
        .uncompressed_size = 2048,
    };
}
