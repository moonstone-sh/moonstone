const std = @import("std");

pub const ModuleDefinition = struct {
    sources: ?[]const []const u8 = null,
    defines: ?[]const []const u8 = null,
    incdirs: ?[]const []const u8 = null,
    libdirs: ?[]const []const u8 = null,
    libraries: ?[]const []const u8 = null,
    // Note: Some modules are just a string path
};

pub const Rockspec = struct {
    package: []const u8,
    version: []const u8,
    source: struct {
        url: []const u8,
    },
    build: struct {
        type: []const u8,
        modules: ?std.json.Value = null,
        install: ?struct {
            bin: ?std.json.Value = null,
        } = null,
    },
    dependencies: ?[]const []const u8 = null,
    external_dependencies: ?std.json.Value = null,

    pub fn deinit(self: Rockspec, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub fn parse_rockspec(allocator: std.mem.Allocator, io: std.Io, content: []const u8, lua_exe: ?[]const u8) !std.json.Parsed(Rockspec) {
    const root = @import("../root.zig");

    const lua_bin = lua_exe orelse "lua";

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ "/tmp", "moonstone-rs-parse-tmp" });
    defer allocator.free(tmp_dir_path);

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir_path) catch {};

    const bridge_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "bridge.lua" });
    defer allocator.free(bridge_path);
    const bridge_file = try std.Io.Dir.cwd().createFile(io, bridge_path, .{});
    try bridge_file.writeStreamingAll(io, root.assets.bridge_lua);
    bridge_file.close(io);

    const rs_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "rockspec.lua" });
    defer allocator.free(rs_path);
    const rs_file = try std.Io.Dir.cwd().createFile(io, rs_path, .{});
    try rs_file.writeStreamingAll(io, content);
    rs_file.close(io);

    const res = try std.process.run(allocator, io, .{
        .argv = &.{ lua_bin, bridge_path, rs_path },
    });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    if (res.term != .exited or res.term.exited != 0) {
        return error.RockspecParseError;
    }

    return try std.json.parseFromSlice(Rockspec, allocator, res.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const Dependency = struct {
    name: []const u8,
    constraint: ?[]const u8 = null,

    pub fn deinit(self: Dependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.constraint) |c| allocator.free(c);
    }
};

pub fn parse_dependency_string(allocator: std.mem.Allocator, dep_str: []const u8) !Dependency {
    const trimmed = std.mem.trim(u8, dep_str, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidDependencyString;

    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const name = it.next() orelse return error.InvalidDependencyString;

    const rest = std.mem.trim(u8, trimmed[name.len..], " \t\r\n");
    if (rest.len > 0) {
        return Dependency{
            .name = try allocator.dupe(u8, name),
            .constraint = try allocator.dupe(u8, rest),
        };
    } else {
        return Dependency{
            .name = try allocator.dupe(u8, name),
            .constraint = null,
        };
    }
}
