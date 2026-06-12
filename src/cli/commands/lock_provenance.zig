const std = @import("std");
const moonstone = @import("moonstone");

pub const StoreProvenance = struct {
    source_hash: []const u8,
    recipe_hash: []const u8,
    source: []const u8,
    source_kind: []const u8,
    source_payload: []const u8,
    rockspec: []const u8,
    rockspec_hash: []const u8,
    rockspec_payload: []const u8,

    pub fn deinit(self: *StoreProvenance, allocator: std.mem.Allocator) void {
        allocator.free(self.source_hash);
        allocator.free(self.recipe_hash);
        allocator.free(self.source);
        allocator.free(self.source_kind);
        allocator.free(self.source_payload);
        allocator.free(self.rockspec);
        allocator.free(self.rockspec_hash);
        allocator.free(self.rockspec_payload);
    }
};

pub fn read(allocator: std.mem.Allocator, io: std.Io, artifact_path: []const u8) !StoreProvenance {
    const manifest_path = try std.fs.path.join(allocator, &.{ artifact_path, "manifest.toml" });
    defer allocator.free(manifest_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);

    var sm = try moonstone.domain.manifest.StoreManifest.parse(allocator, content);
    defer sm.deinit(allocator);

    return .{
        .source_hash = try allocator.dupe(u8, sm.artifact.source_hash),
        .recipe_hash = try allocator.dupe(u8, sm.artifact.recipe_hash),
        .source = try allocator.dupe(u8, sm.origin.source),
        .source_kind = try allocator.dupe(u8, sm.origin.source_kind),
        .source_payload = try allocator.dupe(u8, sm.origin.source_payload),
        .rockspec = try allocator.dupe(u8, sm.origin.rockspec),
        .rockspec_hash = try allocator.dupe(u8, sm.origin.rockspec_hash),
        .rockspec_payload = try allocator.dupe(u8, sm.origin.rockspec_payload),
    };
}
