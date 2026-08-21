const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("../../domain/manifest.zig");
const c_api = @import("../../runtime/c_api.zig");

fn is_macos_target(target: []const u8) bool {
    if (std.mem.endsWith(u8, target, "-macos")) return true;
    if (comptime builtin.os.tag == .macos) return std.mem.eql(u8, target, "native");
    return false;
}

fn is_elf_target(target: []const u8) bool {
    if (std.mem.eql(u8, target, "native")) return switch (builtin.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };

    return std.mem.indexOf(u8, target, "-linux") != null or
        std.mem.indexOf(u8, target, "-freebsd") != null or
        std.mem.indexOf(u8, target, "-netbsd") != null or
        std.mem.indexOf(u8, target, "-openbsd") != null or
        std.mem.indexOf(u8, target, "-dragonfly") != null;
}

fn normalize_macos_uuid(io: std.Io, output_path: []const u8) !void {
    const mach_header_64_magic: u32 = 0xfeedfacf;
    const lc_uuid: u32 = 0x1b;

    var file = try std.Io.Dir.cwd().openFile(io, output_path, .{ .mode = .read_write });
    defer file.close(io);

    var header: [32]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidMachO;
    if (std.mem.readInt(u32, header[0..4], .little) != mach_header_64_magic) return error.InvalidMachO;

    const command_count = std.mem.readInt(u32, header[16..20], .little);
    var offset: u64 = header.len;
    for (0..command_count) |_| {
        var command_header: [8]u8 = undefined;
        if (try file.readPositionalAll(io, &command_header, offset) != command_header.len) return error.InvalidMachO;

        const command = std.mem.readInt(u32, command_header[0..4], .little);
        const command_size = std.mem.readInt(u32, command_header[4..8], .little);
        if (command_size < command_header.len) return error.InvalidMachO;
        if (command == lc_uuid) {
            if (command_size < 24) return error.InvalidMachO;
            try file.writePositionalAll(io, &([_]u8{0} ** 16), offset + command_header.len);
            return;
        }
        offset = std.math.add(u64, offset, command_size) catch return error.InvalidMachO;
    }

    return error.InvalidMachO;
}

const macos_signature = switch (builtin.os.tag) {
    .macos => struct {
        fn sign(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8, module_name: []const u8) !void {
            const identifier = try std.fmt.allocPrint(allocator, "sh.moonstone.native.{s}", .{module_name});
            defer allocator.free(identifier);
            const result = try std.process.run(allocator, io, .{
                .argv = &.{ "codesign", "--force", "--sign", "-", "--identifier", identifier, "--timestamp=none", output_path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term != .exited or result.term.exited != 0) return error.MacOSCodeSignatureFailed;
        }
    },
    else => struct {
        fn sign(_: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) !void {}
    },
};

const macos_sdk = switch (builtin.os.tag) {
    .macos => struct {
        fn path(allocator: std.mem.Allocator, io: std.Io) !?[]const u8 {
            const result = try std.process.run(allocator, io, .{ .argv = &.{ "xcrun", "--show-sdk-path" } });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term != .exited or result.term.exited != 0) return error.MacOSSDKUnavailable;
            const value = std.mem.trim(u8, result.stdout, " \t\r\n");
            if (value.len == 0) return error.MacOSSDKUnavailable;
            return try allocator.dupe(u8, value);
        }
    },
    else => struct {
        fn path(_: std.mem.Allocator, _: std.Io) !?[]const u8 {
            return null;
        }
    },
};

fn append_external_path_flag(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    argv: *std.ArrayList([]const u8),
    owned_flags: *std.ArrayList([]const u8),
    flag: []const u8,
) !void {
    const prefix = if (std.mem.startsWith(u8, flag, "-I")) "-I" else if (std.mem.startsWith(u8, flag, "-L")) "-L" else {
        try argv.append(allocator, flag);
        return;
    };
    const value_reference = flag[prefix.len..];
    if (!std.mem.startsWith(u8, value_reference, "$(") or !std.mem.endsWith(u8, value_reference, ")")) {
        try argv.append(allocator, flag);
        return;
    }

    const variable_name = value_reference[2 .. value_reference.len - 1];
    const value = env_map.get(variable_name) orelse return error.LuaRocksExternalDependencyPathRequired;
    if (value.len == 0) return error.LuaRocksExternalDependencyPathRequired;

    const expanded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value });
    errdefer allocator.free(expanded);
    try owned_flags.append(allocator, expanded);
    try argv.append(allocator, expanded);
}

test "native C modules require declared external path variables" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    var owned_flags = std.ArrayList([]const u8).empty;
    defer {
        for (owned_flags.items) |flag| allocator.free(flag);
        owned_flags.deinit(allocator);
    }

    try std.testing.expectError(
        error.LuaRocksExternalDependencyPathRequired,
        append_external_path_flag(allocator, &env, &argv, &owned_flags, "-I$(SQLITE_INCDIR)"),
    );

    try env.put("SQLITE_INCDIR", "/sdk/include");
    try append_external_path_flag(allocator, &env, &argv, &owned_flags, "-I$(SQLITE_INCDIR)");
    try std.testing.expectEqualStrings("-I/sdk/include", argv.items[0]);
}

fn find_lua_include(allocator: std.mem.Allocator, io: std.Io, runtime_path: []const u8) ![]const u8 {
    const inc_files = try std.fs.path.join(allocator, &.{ runtime_path, "files", "include" });
    const inc_direct = try std.fs.path.join(allocator, &.{ runtime_path, "include" });

    const candidates = [_][]const u8{ inc_files, inc_direct };
    defer {
        allocator.free(inc_files);
        allocator.free(inc_direct);
    }

    for (candidates) |include_path| {
        const direct_header = try std.fs.path.join(allocator, &.{ include_path, "lua.h" });
        defer allocator.free(direct_header);
        if (std.Io.Dir.cwd().access(io, direct_header, .{})) |_| {
            return try allocator.dupe(u8, include_path);
        } else |_| {}

        if (std.Io.Dir.cwd().openDir(io, include_path, .{ .iterate = true })) |include_dir_val| {
            var include_dir = include_dir_val;
            defer include_dir.close(io);
            var iterator = include_dir.iterate();
            while (iterator.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                const nested_path = try std.fs.path.join(allocator, &.{ include_path, entry.name });
                const nested_header = try std.fs.path.join(allocator, &.{ nested_path, "lua.h" });
                defer allocator.free(nested_header);
                if (std.Io.Dir.cwd().access(io, nested_header, .{})) |_| {
                    return nested_path;
                } else |_| {
                    allocator.free(nested_path);
                }
            }
        } else |_| {}
    }

    return try std.fs.path.join(allocator, &.{ runtime_path, "include" });
}

fn find_lua_link_library(allocator: std.mem.Allocator, io: std.Io, runtime_path: []const u8) !?[]const u8 {
    const files_lib = try std.fs.path.join(allocator, &.{ runtime_path, "files", "lib" });
    const direct_lib = try std.fs.path.join(allocator, &.{ runtime_path, "lib" });
    defer {
        allocator.free(files_lib);
        allocator.free(direct_lib);
    }

    const directories = [_][]const u8{ files_lib, direct_lib };
    const candidates = [_][]const u8{
        "liblua.a",
        "libluajit-5.1.a",
        "lua54.lib",
        "lua53.lib",
        "lua52.lib",
        "lua51.lib",
        "lua.lib",
    };

    for (directories) |directory| {
        for (candidates) |candidate| {
            const path = try std.fs.path.join(allocator, &.{ directory, candidate });
            if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                return path;
            } else |_| {
                allocator.free(path);
            }
        }
    }

    return null;
}

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    source_dir_path: []const u8,
    out_dir_path: []const u8,
    runtime_path: []const u8,
    runtime_c_api: c_api.Profile,
    config: manifest.MaterializeConfig,
    target: []const u8,
    log_file_name: []const u8,
    on_event: ?@import("../../resolution/options.zig").ResolveCallback,
    on_event_context: ?*anyopaque,
) !void {
    const target_is_macos = is_macos_target(target);
    const target_is_elf = is_elf_target(target);

    // 1. Resolve Lua headers path
    const lua_include = try find_lua_include(allocator, io, runtime_path);
    defer allocator.free(lua_include);
    const lua_link_library = if (target_is_macos) null else try find_lua_link_library(allocator, io, runtime_path);
    defer if (lua_link_library) |path| allocator.free(path);

    // 2. Prepare argv for zig cc
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    var expanded_flags = std.ArrayList([]const u8).empty;
    defer {
        for (expanded_flags.items) |flag| allocator.free(flag);
        expanded_flags.deinit(allocator);
    }

    try argv.append(allocator, "zig");
    try argv.append(allocator, "cc");

    const sdk_path = if (target_is_macos) try macos_sdk.path(allocator, io) else null;
    defer if (sdk_path) |path| allocator.free(path);
    var sdk_include_path: ?[]const u8 = null;
    defer if (sdk_include_path) |path| allocator.free(path);
    var sdk_library_path: ?[]const u8 = null;
    defer if (sdk_library_path) |path| allocator.free(path);

    if (target.len > 0) {
        try argv.append(allocator, "-target");
        try argv.append(allocator, target);
    }

    try argv.append(allocator, "-shared");
    try argv.append(allocator, "-fPIC");

    if (target_is_macos) {
        // macOS specific flags for Lua modules
        try argv.append(allocator, "-undefined");
        try argv.append(allocator, "dynamic_lookup");
    }

    if (sdk_path) |path| {
        // Apple system libraries and headers belong to the selected SDK, not
        // the temporary LuaRocks workspace. This is required for explicit
        // external dependencies such as SQLite on Command Line Tools hosts.
        sdk_include_path = try std.fs.path.join(allocator, &.{ path, "usr", "include" });
        sdk_library_path = try std.fs.path.join(allocator, &.{ path, "usr", "lib" });
        try argv.append(allocator, "-isysroot");
        try argv.append(allocator, path);
        try argv.append(allocator, "-I");
        try argv.append(allocator, sdk_include_path.?);
        try argv.append(allocator, "-L");
        try argv.append(allocator, sdk_library_path.?);
    }

    try argv.append(allocator, "-I");
    try argv.append(allocator, lua_include);

    try argv.append(allocator, "-I");
    try argv.append(allocator, source_dir_path);

    const src_inc_dir = try std.fs.path.join(allocator, &.{ source_dir_path, "src" });
    defer allocator.free(src_inc_dir);
    if (std.Io.Dir.cwd().access(io, src_inc_dir, .{})) |_| {
        try argv.append(allocator, "-I");
        try argv.append(allocator, src_inc_dir);
    } else |_| {}

    if (runtime_c_api.compilerDefine()) |define| try argv.append(allocator, define);

    // Apply custom CFLAGS (stored in .args)
    for (config.args) |flag| {
        try append_external_path_flag(allocator, env_map, &argv, &expanded_flags, flag);
    }

    // Native module artifacts are release closures, not debugger payloads.
    // Suppress temporary workspace paths in DWARF on every target.
    try argv.append(allocator, "-g0");

    if (target_is_elf) {
        // LLD may otherwise emit an ELF build ID based on host/linker defaults.
        // The module closure already has Moonstone's content identity, so omit
        // that non-semantic linker note to keep source replay byte-stable.
        try argv.append(allocator, "-Wl,--build-id=none");
    }

    // Output path
    const output_abs_path = try std.fs.path.join(allocator, &.{ out_dir_path, config.output.?.path });
    defer allocator.free(output_abs_path);

    // Ensure output parent directory exists
    const output_dir = std.fs.path.dirname(output_abs_path) orelse return error.InvalidOutputPath;
    try std.Io.Dir.cwd().createDirPath(io, output_dir);

    var install_name: ?[]const u8 = null;
    defer if (install_name) |value| allocator.free(value);
    if (target_is_macos) {
        // Zig's Mach-O linker otherwise writes the absolute temporary output
        // path into LC_ID_DYLIB. A stable module-relative install name keeps
        // equivalent source builds byte-identical across workspaces.
        install_name = try std.fmt.allocPrint(allocator, "@rpath/{s}", .{std.fs.path.basename(config.output.?.path)});
        try argv.append(allocator, "-install_name");
        try argv.append(allocator, install_name.?);
    }

    try argv.append(allocator, "-o");
    try argv.append(allocator, output_abs_path);

    // Apply custom LDFLAGS
    for (config.ldflags) |flag| {
        try append_external_path_flag(allocator, env_map, &argv, &expanded_flags, flag);
    }

    // Add source files
    for (config.input.?.sources) |src| {
        // The process cwd is source_dir_path. Retaining the manifest-relative
        // spelling prevents __FILE__ and debug metadata from embedding the
        // per-materialization temporary directory into the produced artifact.
        try argv.append(allocator, src);
    }

    if (lua_link_library) |path| {
        // Moonstone's Linux and Windows runtimes do not promise to export Lua
        // C API symbols from the interpreter executable. Resolve them into the
        // module from the matching runtime archive instead. The library must
        // follow module objects so static archive resolution sees their uses.
        try argv.append(allocator, path);
    } else if (!target_is_macos) {
        return error.RuntimeLuaLibraryNotFound;
    }

    // 3. Spawn compilation
    const res = std.process.run(allocator, io, .{
        .argv = argv.items,
        .environ_map = env_map,
        .cwd = .{ .path = source_dir_path },
    }) catch |err| {
        if (err == error.FileNotFound) {
            return error.CompilerNotFound;
        }
        return err;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.term != .exited or res.term.exited != 0) {
        var log_path: ?[]const u8 = null;
        if (std.Io.Dir.cwd().openDir(io, ".moonstone", .{})) |moon_dir| {
            if (moon_dir.createDirPath(io, "logs/build")) |_| {
                const log_full_path = try std.fs.path.join(allocator, &.{ ".moonstone", "logs", "build", log_file_name });
                if (std.Io.Dir.cwd().createFile(io, log_full_path, .{})) |log_file| {
                    log_file.writeStreamingAll(io, "=== STDOUT ===\n") catch {};
                    log_file.writeStreamingAll(io, res.stdout) catch {};
                    log_file.writeStreamingAll(io, "\n=== STDERR ===\n") catch {};
                    log_file.writeStreamingAll(io, res.stderr) catch {};
                    log_file.close(io);
                    log_path = log_full_path;
                } else |_| {
                    allocator.free(log_full_path);
                }
            } else |_| {}
            moon_dir.close(io);
        } else |_| {}

        if (on_event) |cb| {
            const tail_len = @min(res.stderr.len, 2048);
            const tail = res.stderr[res.stderr.len - tail_len ..];
            cb(on_event_context, .{ .build_failed = .{
                .pkg_name = std.fs.path.basename(out_dir_path),
                .command = "zig cc",
                .stderr_tail = tail,
                .log_path = log_path,
            } });
        } else {
            const tail_len = @min(res.stderr.len, 2048);
            const tail = res.stderr[res.stderr.len - tail_len ..];
            std.debug.print("native module compilation failed:\n", .{});
            if (log_path) |lp| std.debug.print("Full log written to: {s}\n", .{lp});
            std.debug.print("Tail of stderr:\n{s}\n", .{tail});
        }
        if (log_path) |lp| allocator.free(lp);
        return error.CompilationFailed;
    }

    if (target_is_macos) {
        // Zig's Mach-O linker emits a random LC_UUID. It is not required for
        // Lua module loading, but it changes both the binary and its signature
        // across otherwise identical materializations.
        try normalize_macos_uuid(io, output_abs_path);
        // Zig's linker derives its ad-hoc signature identifier from the
        // temporary output path. Re-sign with a Moonstone-owned stable id so
        // the valid signature, UUID, and linkedit closure replay byte-for-byte.
        try macos_signature.sign(allocator, io, output_abs_path, std.fs.path.basename(config.output.?.path));
    }
}

test "macOS target detection is independent of the build host" {
    try std.testing.expect(is_macos_target("aarch64-macos"));
    try std.testing.expect(is_macos_target("x86_64-macos"));
    try std.testing.expect(!is_macos_target("x86_64-linux-gnu"));
    try std.testing.expect(!is_macos_target("x86_64-windows-gnu"));
    try std.testing.expectEqual(comptime builtin.os.tag == .macos, is_macos_target("native"));
}

test "ELF target detection is independent of the build host" {
    try std.testing.expect(is_elf_target("x86_64-linux-gnu"));
    try std.testing.expect(is_elf_target("aarch64-linux-musl"));
    try std.testing.expect(is_elf_target("x86_64-freebsd"));
    try std.testing.expect(!is_elf_target("aarch64-macos"));
    try std.testing.expect(!is_elf_target("x86_64-windows-gnu"));
}
