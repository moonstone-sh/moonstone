const std = @import("std");
const store = @import("../store.zig");

pub const ArtifactFetchStatus = enum {
    found,
    not_found,
    unauthorized,
    unavailable,
    hash_mismatch,
    malformed,
};

pub const ArtifactRequest = struct {
    artifact_hash: []const u8,
    artifact_schema: []const u8 = "moonstone:artifact-tree:v1",
    target: []const u8,
};

pub const ArtifactFetchResult = struct {
    status: ArtifactFetchStatus,
    local_staging_path: ?[]const u8 = null,

    pub fn deinit(self: *ArtifactFetchResult, allocator: std.mem.Allocator) void {
        if (self.local_staging_path) |p| allocator.free(p);
    }
};

pub const RemoteArtifactProvider = struct {
    name: []const u8 = "default",
    base_url: []const u8 = "",
    auth_token: ?[]const u8 = null,

    pub fn init(name: []const u8, base_url: []const u8) RemoteArtifactProvider {
        return .{
            .name = name,
            .base_url = base_url,
        };
    }

    pub fn fetchArtifact(
        self: RemoteArtifactProvider,
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *std.process.Environ.Map,
        req: ArtifactRequest,
        staging_dir: []const u8,
    ) !ArtifactFetchResult {
        _ = env;
        if (self.base_url.len == 0) {
            return ArtifactFetchResult{ .status = .not_found };
        }

        // Secure extraction validation check on staging directory if pre-existing
        var dir = std.Io.Dir.cwd().openDir(io, staging_dir, .{ .iterate = true }) catch {
            return ArtifactFetchResult{ .status = .not_found };
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "/") or std.mem.indexOf(u8, entry.name, "..") != null) {
                return ArtifactFetchResult{ .status = .malformed };
            }
        }

        const hash_mod = @import("../identity/hash.zig");
        const raw_hash = hash_mod.artifact_hash(allocator, io, dir) catch {
            return ArtifactFetchResult{ .status = .malformed };
        };
        defer allocator.free(raw_hash);

        const computed_hash = try std.fmt.allocPrint(allocator, "b3:{s}", .{raw_hash});
        defer allocator.free(computed_hash);

        if (!std.mem.eql(u8, computed_hash, req.artifact_hash)) {
            return ArtifactFetchResult{ .status = .hash_mismatch };
        }

        return ArtifactFetchResult{
            .status = .found,
            .local_staging_path = try allocator.dupe(u8, staging_dir),
        };
    }
};
