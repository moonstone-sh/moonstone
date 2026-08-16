const std = @import("std");
const builtin = @import("builtin");

fn luarocks_platform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macosx",
        .windows => "win32",
        .linux => "linux",
        else => "unix",
    };
}

/// Maps Moonstone's persisted target vocabulary to LuaRocks' platform
/// selectors. A missing or legacy `native` target deliberately means the
/// executable host; concrete target profiles must instead select their own
/// platform branch before dependency resolution and materialization.
pub fn platform_for_target(target: ?[]const u8) ![]const u8 {
    const value = target orelse return luarocks_platform();
    if (std.mem.eql(u8, value, "native")) return luarocks_platform();
    if (std.mem.indexOf(u8, value, "-windows-") != null) return "win32";
    if (std.mem.endsWith(u8, value, "-macos")) return "macosx";
    if (std.mem.indexOf(u8, value, "-linux-") != null) return "linux";
    if (std.mem.endsWith(u8, value, "-freebsd")) return "freebsd";
    return error.UnsupportedLuaRocksTargetPlatform;
}

pub const ModuleDefinition = struct {
    sources: ?[]const []const u8 = null,
    defines: ?[]const []const u8 = null,
    incdirs: ?[]const []const u8 = null,
    libdirs: ?[]const []const u8 = null,
    libraries: ?[]const []const u8 = null,
    // Note: Some modules are just a string path
};

pub const Source = struct {
    url: ?[]const u8 = null,
    md5: ?[]const u8 = null,
    file: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    module: ?[]const u8 = null,
    dir: ?[]const u8 = null,
};

pub const Build = struct {
    type: ?[]const u8 = null,
    build_command: ?[]const u8 = null,
    install_command: ?[]const u8 = null,
    /// LuaRocks build backends use this string map to pass backend-specific
    /// configuration. Moonstone retains it as typed data and translates only
    /// the documented CMake placeholders during materialization planning.
    variables: ?std.json.Value = null,
    makefile: ?[]const u8 = null,
    build_target: ?[]const u8 = null,
    install_target: ?[]const u8 = null,
    build_variables: ?std.json.Value = null,
    install_variables: ?std.json.Value = null,
    modules: ?std.json.Value = null,
    install: ?struct {
        bin: ?std.json.Value = null,
        lua: ?std.json.Value = null,
        lib: ?std.json.Value = null,
        conf: ?std.json.Value = null,
    } = null,
};

pub const RockspecIntent = struct {
    schema: []const u8,
    platform: []const u8,
    rockspec_format: []const u8,
    source: Source,
    dependencies: []const []const u8 = &.{},
    supported_platforms: []const []const u8 = &.{},
    build_dependencies: []const []const u8 = &.{},
    test_dependencies: []const []const u8 = &.{},
    external_dependencies: ?std.json.Value = null,
    build: Build,
    /// Complete platform-selected build declaration for capability checks.
    build_declaration: std.json.Value,
    hooks: ?std.json.Value = null,
    @"test": ?std.json.Value = null,
};

pub const Rockspec = struct {
    /// Complete evaluated rockspec declaration, retained for inspection.
    document: std.json.Value,
    /// Versioned validation result for the rockspec declaration grammar.
    validation: std.json.Value,
    /// The platform-selected projection consumed by resolver operations.
    intent: RockspecIntent,
    package: []const u8,
    version: []const u8,

    pub fn deinit(self: Rockspec, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

var parse_workspace_counter: std.atomic.Value(u64) = .init(0);

fn create_parse_workspace(
    allocator: std.mem.Allocator,
    io: std.Io,
    temp_root: []const u8,
) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(io, temp_root);

    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const sequence = parse_workspace_counter.fetchAdd(1, .monotonic);
        const workspace_name = try std.fmt.allocPrint(
            allocator,
            "rockspec-{d}-{d}",
            .{ std.Thread.getCurrentId(), sequence },
        );
        defer allocator.free(workspace_name);

        const workspace_path = try std.fs.path.join(allocator, &.{ temp_root, workspace_name });
        errdefer allocator.free(workspace_path);

        std.Io.Dir.cwd().createDir(io, workspace_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(workspace_path);
                continue;
            },
            else => return err,
        };
        return workspace_path;
    }

    return error.RockspecParseWorkspaceUnavailable;
}

pub fn parse_rockspec(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    lua_exe: ?[]const u8,
    temp_root: []const u8,
) !std.json.Parsed(Rockspec) {
    return parse_rockspec_for_target(allocator, io, content, lua_exe, temp_root, null);
}

pub fn parse_rockspec_for_target(
    allocator: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
    lua_exe: ?[]const u8,
    temp_root: []const u8,
    target: ?[]const u8,
) !std.json.Parsed(Rockspec) {
    const root = @import("../root.zig");

    const lua_bin = lua_exe orelse "lua";
    const platform = try platform_for_target(target);

    const tmp_dir_path = try create_parse_workspace(allocator, io, temp_root);
    defer allocator.free(tmp_dir_path);
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
        .argv = &.{ lua_bin, bridge_path, rs_path, platform },
    });
    defer {
        allocator.free(res.stdout);
        allocator.free(res.stderr);
    }

    if (res.term != .exited or res.term.exited != 0) {
        if (std.mem.indexOf(u8, res.stderr, "[UnsupportedRockspecFormat]") != null) {
            return error.UnsupportedRockspecFormat;
        }
        if (std.mem.indexOf(u8, res.stderr, "[InvalidRockspecSchema]") != null) {
            return error.InvalidRockspecSchema;
        }
        return error.RockspecParseError;
    }

    return std.json.parseFromSlice(Rockspec, allocator, res.stdout, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("parseFromSlice Rockspec error: {s}\nJSON: {s}\n", .{ @errorName(err), res.stdout });
        return err;
    };
}

test "LuaRocks platform projection follows the selected target profile" {
    try std.testing.expectEqualStrings("win32", try platform_for_target("x86_64-windows-gnu"));
    try std.testing.expectEqualStrings("win32", try platform_for_target("aarch64-windows-msvc"));
    try std.testing.expectEqualStrings("macosx", try platform_for_target("aarch64-macos"));
    try std.testing.expectEqualStrings("linux", try platform_for_target("x86_64-linux-gnu"));
    try std.testing.expectEqualStrings("freebsd", try platform_for_target("x86_64-freebsd"));
    try std.testing.expectError(error.UnsupportedLuaRocksTargetPlatform, platform_for_target("wasm32-wasi"));
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
