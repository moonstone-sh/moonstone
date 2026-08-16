const std = @import("std");
const lockfile = @import("lockfile.zig");

pub const export_contract = "moonstone:lock:v1";

pub fn writeExport(allocator: std.mem.Allocator, lock: *const lockfile.LockFile, raw: []const u8, writer: anytype) !void {
    const revision = try storageRevision(allocator, raw);
    defer allocator.free(revision);
    try writer.writeAll("{\"contract\":");
    try json(writer, export_contract);
    try writer.writeAll(",\"storage_revision\":");
    try json(writer, revision);
    try writer.print(",\"lockfile_version\":{d},\"realizations\":[", .{lock.version});
    for (lock.packages.items, 0..) |entry, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"realization_hash\":");
        try json(writer, entry.realization_hash);
        try writer.writeAll(",\"name\":");
        try json(writer, entry.name);
        try writer.writeAll(",\"version\":");
        try json(writer, entry.version);
        try writer.writeAll(",\"kind\":");
        try json(writer, @tagName(entry.kind));
        try writer.writeAll(",\"resolver\":");
        try json(writer, entry.resolver);
        try writer.writeAll(",\"registry\":");
        try json(writer, entry.registry);
        try writer.writeAll(",\"artifact_hash\":");
        try json(writer, entry.artifact_hash);
        try writer.writeAll(",\"source_hash\":");
        try json(writer, entry.source_hash);
        try writer.writeAll(",\"recipe_hash\":");
        try json(writer, entry.recipe_hash);
        try writer.writeAll(",\"runtime\":");
        try json(writer, entry.runtime);
        try writer.writeAll(",\"lua_abi\":");
        try json(writer, entry.lua_abi);
        try writer.writeAll(",\"target\":");
        try json(writer, entry.target);
        try writer.writeAll(",\"replay_mode\":");
        try json(writer, @tagName(entry.replay_mode));
        try writer.print(",\"reproducible\":{s}}}", .{if (entry.reproducible) "true" else "false"});
    }
    try writer.writeAll("],\"profiles\":[");
    for (lock.profiles.items, 0..) |profile, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try json(writer, profile.id);
        try writer.writeAll(",\"target\":");
        try json(writer, profile.target);
        try writer.writeAll(",\"runtime\":");
        try json(writer, profile.runtime);
        try writer.writeAll(",\"lua_abi\":");
        if (profile.lua_abi) |abi| try json(writer, abi) else try writer.writeAll("null");
        try writer.print(",\"package_count\":{d},\"edge_count\":{d}}}", .{ profile.packages.len, profile.edges.len });
    }
    try writer.writeAll("]}\n");
}

pub fn storageRevision(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(raw, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "b3:{s}", .{&hex});
}

fn json(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}
