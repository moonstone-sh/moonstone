const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const EnvCommand = struct {
    pub const name = "env";
    pub const description = "Show project environment configuration";

    json: bool = false,
    paths: bool = false,
    shell: ?[]const u8 = null,
    prod: bool = false,
    dev: bool = true,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon env [flags]
            \\
            \\Show Moonstone environment configuration for the current project.
            \\
            \\Flags:
            \\  --json        Output as JSON
            \\  --paths       Output only PATH additions
            \\  --shell <s>   Output export commands for shell: bash, zsh, fish, cmd, powershell
            \\  --prod        Exclude development dependencies
            \\
        , .{});
    }

    /// Shell syntaxes `moon env --shell` can emit. The two templates differ in
    /// how a variable is set, so anything generated rather than substituted
    /// has to be written in the target syntax instead of assuming POSIX.
    const ShellSyntax = enum { posix, fish };

    fn writeShellAssignment(
        writer: *std.Io.Writer,
        syntax: ShellSyntax,
        key: []const u8,
        value: []const u8,
    ) !void {
        switch (syntax) {
            .posix => try writer.print("export {s}=\"{s}\"\n", .{ key, value }),
            .fish => try writer.print("set -gx {s} \"{s}\"\n", .{ key, value }),
        }
    }

    fn renderShellTemplate(
        allocator: std.mem.Allocator,
        template: []const u8,
        run_env: moonstone.project.run_env.RunEnv,
        project_root: []const u8,
        syntax: ShellSyntax,
    ) ![]const u8 {
        var result = try allocator.dupe(u8, template);
        errdefer allocator.free(result);

        var native_library_export = std.Io.Writer.Allocating.init(allocator);
        defer native_library_export.deinit();
        if (run_env.native_lib_path) |native_lib_path| {
            if (moonstone.project.environment.nativeLibraryEnvironmentVariable()) |key| {
                switch (syntax) {
                    .posix => try native_library_export.writer.print(
                        "export {s}=\"{s}:${{{s}:-}}\"\n",
                        .{ key, native_lib_path, key },
                    ),
                    .fish => try native_library_export.writer.print(
                        "set -gx {s} \"{s}\" ${s}\n",
                        .{ key, native_lib_path, key },
                    ),
                }
            }
        }
        try native_library_export.writer.flush();

        var package_root_exports = std.Io.Writer.Allocating.init(allocator);
        defer package_root_exports.deinit();
        for (run_env.package_roots) |entry| {
            try writeShellAssignment(&package_root_exports.writer, syntax, entry.key, entry.root);
        }
        try package_root_exports.writer.flush();

        const replacements = [_]struct { key: []const u8, value: []const u8 }{
            .{ .key = "{{bin_path}}", .value = run_env.bin_path },
            .{ .key = "{{lua_path}}", .value = run_env.lua_path },
            .{ .key = "{{lua_cpath}}", .value = run_env.lua_cpath },
            .{ .key = "{{native_library_export}}", .value = native_library_export.writer.buffer[0..native_library_export.writer.end] },
            .{ .key = "{{package_root_exports}}", .value = package_root_exports.writer.buffer[0..package_root_exports.writer.end] },
            .{ .key = "{{project_root}}", .value = project_root },
        };

        for (replacements) |rep| {
            while (std.mem.indexOf(u8, result, rep.key)) |pos| {
                const new_res = try std.mem.concat(allocator, u8, &.{ result[0..pos], rep.value, result[pos + rep.key.len ..] });
                allocator.free(result);
                result = new_res;
            }
        }

        return result;
    }

    pub fn run(self: EnvCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var run_env = if (ctx.working_directory) |project_root|
            try moonstone.project.run_env.get_run_env_at_root(allocator, io, project_root, env)
        else
            try moonstone.project.run_env.get_run_env(allocator, io, ".", env);
        defer run_env.deinit();

        if (self.json) {
            const JsonPackageRoot = struct {
                name: []const u8,
                root: []const u8,
                env: []const u8,
                projection: []const u8,
            };
            const package_roots = try allocator.alloc(JsonPackageRoot, run_env.package_roots.len);
            defer allocator.free(package_roots);
            for (run_env.package_roots, 0..) |entry, index| {
                package_roots[index] = .{
                    .name = entry.name,
                    .root = entry.root,
                    .env = entry.key,
                    .projection = entry.projection.asString(),
                };
            }

            try std.json.Stringify.value(.{
                .path = run_env.bin_path,
                .lua_path = run_env.lua_path,
                .lua_cpath = run_env.lua_cpath,
                .native_lib_path = run_env.native_lib_path,
                .lua_version = run_env.lua_ver_dot,
                .package_roots = package_roots,
            }, .{}, stdout);
            try stdout.writeAll("\n");
        } else if (self.paths) {
            try stdout.print("{s}\n", .{run_env.bin_path});
        } else if (self.shell) |s| {
            const project_root = try std.process.currentPathAlloc(io, allocator);
            defer allocator.free(project_root);

            if (std.mem.eql(u8, s, "bash") or std.mem.eql(u8, s, "zsh")) {
                const content = try renderShellTemplate(allocator, moonstone.assets.raw.shells.posix, run_env, project_root, .posix);
                defer allocator.free(content);
                try stdout.writeAll(content);
            } else if (std.mem.eql(u8, s, "fish")) {
                const content = try renderShellTemplate(allocator, moonstone.assets.raw.shells.fish, run_env, project_root, .fish);
                defer allocator.free(content);
                try stdout.writeAll(content);
            } else {
                try stdout.print("Shell '{s}' not yet supported for env export.\n", .{s});
            }
        } else {
            try stdout.print("Moonstone Environment:\n", .{});
            try stdout.print("  PATH:      {s}\n", .{run_env.bin_path});
            try stdout.print("  LUA_PATH:  {s}\n", .{run_env.lua_path});
            try stdout.print("  LUA_CPATH: {s}\n", .{run_env.lua_cpath});
            if (run_env.native_lib_path) |native_lib_path| try stdout.print("  NATIVE_LIB_PATH: {s}\n", .{native_lib_path});
            if (run_env.package_roots.len > 0) {
                try stdout.print("  Package roots:\n", .{});
                for (run_env.package_roots) |entry| {
                    try stdout.print("    {s} ({s}) {s}={s}\n", .{ entry.name, entry.projection.asString(), entry.key, entry.root });
                }
            }
        }
    }
};
