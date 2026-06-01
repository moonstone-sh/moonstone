const std = @import("std");
const moonstone = @import("moonstone");

pub const RegistryListCommand = struct {
    pub fn run(self: RegistryListCommand, allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map) !void {
        _ = self;
        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        try stdout.print("Project registries:\n", .{});
        var it = mt.registries.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const config = entry.value_ptr.*;
            if (config.url) |u| try stdout.print("  {s: <15} {s}\n", .{ name, u }) else try stdout.print("  {s: <15} {s}\n", .{ name, config.path orelse "unknown" });
        }
        _ = env;
    }
};

pub const RegistryAddCommand = struct {
    name: []const u8,
    uri: []const u8,
    default: bool = false,

    pub fn run(self: RegistryAddCommand, allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map) !void {
        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        var config = moonstone.domain.manifest.RegistryConfig{};
        if (std.mem.startsWith(u8, self.uri, "http")) {
            config.url = try allocator.dupe(u8, self.uri);
        } else if (std.mem.startsWith(u8, self.uri, "file:")) {
            config.path = try allocator.dupe(u8, self.uri[5..]);
        } else {
            config.path = try allocator.dupe(u8, self.uri);
        }

        try mt.registries.put(allocator, try allocator.dupe(u8, self.name), config);

        const toml_file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
        defer toml_file.close(io);

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try mt.serialize(allocator, &aw.writer);
        try aw.writer.flush();
        try toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

        try stdout.print("Added registry '{s}' to {s}.\n", .{ self.name, toml_path });
        _ = env;
    }
};

pub const RegistryRemoveCommand = struct {
    name: []const u8,

    pub fn run(self: RegistryRemoveCommand, allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map) !void {
        const toml_path = "moonstone.toml";
        const content = try std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        if (mt.registries.fetchSwapRemove(self.name)) |entry| {
            allocator.free(entry.key);
            entry.value.deinit(allocator);

            const toml_file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
            defer toml_file.close(io);

            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try mt.serialize(allocator, &aw.writer);
            try aw.writer.flush();
            try toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

            try stdout.print("Removed registry '{s}'.\n", .{self.name});
        } else {
            try stdout.print("Registry '{s}' not found.\n", .{self.name});
        }
        _ = env;
    }
};

test "registry_list command struct instantiates" {
    const cmd = RegistryListCommand{};
    _ = cmd;
}

test "registry_add command defaults" {
    const cmd = RegistryAddCommand{ .name = "test", .uri = "https://example.com" };
    try std.testing.expectEqualStrings("test", cmd.name);
    try std.testing.expectEqualStrings("https://example.com", cmd.uri);
}

test "registry_remove command defaults" {
    const cmd = RegistryRemoveCommand{ .name = "test" };
    try std.testing.expectEqualStrings("test", cmd.name);
}
