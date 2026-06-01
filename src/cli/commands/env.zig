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

    fn renderShellTemplate(allocator: std.mem.Allocator, template: []const u8, run_env: moonstone.project.run_env.RunEnv, project_root: []const u8) ![]const u8 {
        var result = try allocator.dupe(u8, template);
        errdefer allocator.free(result);

        const replacements = [_]struct { key: []const u8, value: []const u8 }{
            .{ .key = "{{bin_path}}", .value = run_env.bin_path },
            .{ .key = "{{lua_path}}", .value = run_env.lua_path },
            .{ .key = "{{lua_cpath}}", .value = run_env.lua_cpath },
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

        var run_env = try moonstone.project.run_env.get_run_env(allocator, io, ".", env);
        defer run_env.deinit();

        if (self.json) {
            try stdout.print(
                \\{{"path":"{s}","lua_path":"{s}","lua_cpath":"{s}","lua_version":"{s}"}}
                \\
            , .{ run_env.bin_path, run_env.lua_path, run_env.lua_cpath, run_env.lua_ver_dot });
        } else if (self.paths) {
            try stdout.print("{s}\n", .{run_env.bin_path});
        } else if (self.shell) |s| {
            const project_root = try std.process.currentPathAlloc(io, allocator);
            defer allocator.free(project_root);

            if (std.mem.eql(u8, s, "bash") or std.mem.eql(u8, s, "zsh")) {
                const content = try renderShellTemplate(allocator, moonstone.assets.raw.shells.posix, run_env, project_root);
                defer allocator.free(content);
                try stdout.writeAll(content);
            } else if (std.mem.eql(u8, s, "fish")) {
                const content = try renderShellTemplate(allocator, moonstone.assets.raw.shells.fish, run_env, project_root);
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
        }
    }
};
