const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub const export_contract = "moonstone:manifest:v1";

pub fn writeExport(manifest: *const manifest_mod.MoonstoneToml, raw_manifest: []const u8, writer: anytype) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(raw_manifest, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    try writer.writeAll("{\"contract\":");
    try writeJson(writer, export_contract);
    try writer.print(",\"storage_revision\":\"b3:{s}\",\"manifest\":{{", .{hex});
    try writeManifest(manifest, writer);
    try writer.writeAll("}}\n");
}

fn writeManifest(manifest: *const manifest_mod.MoonstoneToml, writer: anytype) !void {
    try writer.print("\"manifest_version\":{d},\"project\":{{", .{manifest.manifest_version});
    try writeJsonField(writer, "name", manifest.package.name, true);
    try writeJsonField(writer, "version", manifest.package.version, false);
    try writeJsonField(writer, "kind", manifest.package.kind.as_string(), false);
    try writeOptionalJsonField(writer, "description", manifest.package.description, false);
    try writeOptionalJsonField(writer, "readme", manifest.package.readme, false);
    try writer.writeAll("},\"runtime\":{");
    try writeJsonField(writer, "name", manifest.runtime.name, true);
    try writeJsonField(writer, "version", manifest.runtime.version, false);
    try writeJsonField(writer, "abi", manifest.runtime.abi, false);
    try writer.writeAll("},\"origin\":");
    if (manifest.origin) |origin| {
        try writer.writeAll("{");
        try writeJsonField(writer, "kind", origin.kind, true);
        try writeJsonField(writer, "url", origin.url, false);
        try writeOptionalJsonField(writer, "revision", origin.revision, false);
        try writeOptionalJsonField(writer, "hash", origin.hash, false);
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"tidy\":{{\"scripts\":\"{s}\",\"on_script_mutation\":{s}}}", .{
        manifest.tidy.scripts.asString(),
        if (manifest.tidy.on_script_mutation) "true" else "false",
    });
    try writer.writeAll(",\"dependencies\":[");
    for (manifest.dependencies.items, 0..) |dependency, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonField(writer, "name", dependency.name, true);
        try writeJsonField(writer, "constraint", dependency.constraint, false);
        try writeOptionalJsonField(writer, "registry", dependency.registry, false);
        try writeJsonField(writer, "role", @tagName(dependency.role), false);
        try writer.print(",\"optional\":{s}}}", .{if (dependency.optional) "true" else "false"});
    }
    try writer.writeAll("],\"scripts\":[");
    for (manifest.scripts.items, 0..) |script, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonField(writer, "name", script.name, true);
        try writeJsonField(writer, "command", script.command, false);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"registries\":[");
    try writeRegistries(manifest, writer);
    try writer.writeAll("],\"orbits\":[");
    for (manifest.orbits.items, 0..) |orbit, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{");
        try writeJsonField(writer, "name", orbit.name, true);
        try writeJsonField(writer, "path", orbit.path, false);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeRegistries(manifest: *const manifest_mod.MoonstoneToml, writer: anytype) !void {
    var names: [64][]const u8 = undefined;
    if (manifest.registries.count() > names.len) return error.TooManyRegistries;
    var count: usize = 0;
    var iterator = manifest.registries.iterator();
    while (iterator.next()) |entry| {
        names[count] = entry.key_ptr.*;
        count += 1;
    }
    std.mem.sort([]const u8, names[0..count], {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    for (names[0..count], 0..) |name, index| {
        if (index > 0) try writer.writeAll(",");
        const registry = manifest.registries.get(name).?;
        try writer.writeAll("{");
        try writeJsonField(writer, "name", name, true);
        try writeJsonField(writer, "resolver", registry.resolver, false);
        try writeOptionalJsonField(writer, "url", registry.url, false);
        try writeOptionalJsonField(writer, "path", registry.path, false);
        try writer.print(",\"priority\":{d}}}", .{registry.priority});
    }
}

fn writeJsonField(writer: anytype, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeAll(",");
    try writeJson(writer, name);
    try writer.writeAll(":");
    try writeJson(writer, value);
}

fn writeOptionalJsonField(writer: anytype, name: []const u8, value: ?[]const u8, first: bool) !void {
    if (!first) try writer.writeAll(",");
    try writeJson(writer, name);
    try writer.writeAll(":");
    if (value) |actual| {
        try writeJson(writer, actual);
    } else {
        try writer.writeAll("null");
    }
}

fn writeJson(writer: anytype, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "manifest export uses a stable semantic envelope" {
    const allocator = std.testing.allocator;
    const source =
        \\manifest_version = 2
        \\[package]
        \\name = "contract-test"
        \\version = "0.1.0"
        \\kind = "script"
        \\readme = "REGISTRY_README.md"
        \\
        \\[origin]
        \\kind = "git"
        \\url = "https://example.test/contract-test"
        \\
        \\[interpreter]
        \\name = "lua"
        \\version = "5.4"
        \\abi = "5.4"
        \\
        \\[scripts]
        \\build.posix.sh = "zig build"
    ;
    var manifest = try manifest_mod.MoonstoneToml.parse(allocator, source);
    defer manifest.deinit(allocator);

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeExport(&manifest, source, &output.writer);
    try output.writer.flush();

    const json = output.writer.buffer[0..output.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"contract\":\"moonstone:manifest:v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"platform\":\"posix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"readme\":\"REGISTRY_README.md\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"origin\":{\"kind\":\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"storage_revision\":\"b3:") != null);
}

pub fn storageRevision(allocator: std.mem.Allocator, raw_manifest: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(raw_manifest, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "b3:{s}", .{hex});
}
