const std = @import("std");
const manifest_mod = @import("../domain/manifest.zig");

pub const default_limit = 10 * 1024 * 1024;

pub const Loaded = struct {
    source: []u8,
    manifest: manifest_mod.MoonstoneToml,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);
        allocator.free(self.source);
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, limit: std.Io.Limit) !Loaded {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, limit);
    errdefer allocator.free(source);
    const manifest = try manifest_mod.MoonstoneToml.parse(allocator, source);
    return .{ .source = source, .manifest = manifest };
}

/// Serialize, validate through the domain model, and atomically replace the project manifest.
/// The caller owns the returned canonical storage bytes.
pub fn commit(allocator: std.mem.Allocator, io: std.Io, manifest: *const manifest_mod.MoonstoneToml) ![]u8 {
    var serialized = std.Io.Writer.Allocating.init(allocator);
    defer serialized.deinit();
    try manifest.serialize(allocator, &serialized.writer);
    try serialized.writer.flush();

    const bytes = try allocator.dupe(u8, serialized.writer.buffer[0..serialized.writer.end]);
    errdefer allocator.free(bytes);

    try commitSource(io, bytes);
    return bytes;
}

pub fn commitSource(io: std.Io, source: []const u8) !void {
    var destination = try std.Io.Dir.cwd().createFileAtomic(io, "moonstone.toml", .{ .replace = true });
    defer destination.deinit(io);
    try destination.file.writeStreamingAll(io, source);
    try destination.replace(io);
}

test "commit serializes an explicit manifest" {
    const allocator = std.testing.allocator;
    const source =
        \\manifest_version = 2
        \\[package]
        \\name = "editor-test"
        \\version = "0.1.0"
        \\kind = "script"
        \\
        \\[interpreter]
        \\name = "lua"
        \\version = "5.4"
        \\abi = "5.4"
    ;
    var manifest = try manifest_mod.MoonstoneToml.parse(allocator, source);
    defer manifest.deinit(allocator);

    var serialized = std.Io.Writer.Allocating.init(allocator);
    defer serialized.deinit();
    try manifest.serialize(allocator, &serialized.writer);
    try serialized.writer.flush();
    try std.testing.expect(std.mem.indexOf(u8, serialized.writer.buffer[0..serialized.writer.end], "manifest_version = 2") != null);
}
