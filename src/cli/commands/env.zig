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
    global: bool = false,
    bin_runtime_names: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon env [flags]
            \\
            \\Show Moonstone environment configuration for the current project.
            \\
            \\Flags:
            \\  --json                Output as JSON
            \\  --paths               Output only PATH additions
            \\  --shell <s>           Output export commands for shell: bash, zsh, fish, powershell, cmd
            \\  --prod                Exclude development dependencies
            \\  --global              Show the global tools environment instead of the current project
            \\  --bin-runtime-names   List bin-runtime-scoped tool names (one per line), each usable with `moon exec`
            \\
            \\Environment exports are a shell-integration primitive; moon exec applies
            \\the environment to one child process, and moon run executes a named task.
            \\
            \\Examples:
            \\  moon env
            \\  moon env --shell zsh
            \\  moon exec -- lua build.lua
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
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.UnrepresentableShellValue;
        if (syntax == .posix) try writer.print("export {s}=", .{key}) else try writer.print("set -gx {s} ", .{key});
        try writeLiteral(writer, syntax, value);
        try writer.writeByte('\n');
    }

    fn writeLiteral(writer: *std.Io.Writer, syntax: ShellSyntax, value: []const u8) !void {
        try writer.writeByte(39);
        for (value) |c| {
            if (c == 39) {
                try writer.writeAll(if (syntax == .posix) "'\\''" else "\\'");
            } else {
                if (syntax == .fish and c == '\\') try writer.writeByte('\\');
                try writer.writeByte(c);
            }
        }
        try writer.writeByte(39);
    }

    /// CMD output is a batch-file fragment. Delayed expansion must be disabled
    /// by the caller so literal exclamation marks in project paths survive.
    fn writeWindowsAssignment(writer: *std.Io.Writer, powershell: bool, key: []const u8, value: []const u8, prepend: bool) !void {
        // Environment values cannot safely span commands in either shell.
        if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.UnrepresentableShellValue;
        if (powershell) {
            try writer.print("$env:{s} = '", .{key});
            for (value) |c| {
                try writer.writeByte(c);
                if (c == 39) try writer.writeByte(c);
            }
            try writer.writeAll(if (prepend) ";' + $env:PATH\n" else "'\n");
        } else {
            if (std.mem.indexOfScalar(u8, value, '"') != null) return error.UnrepresentableShellValue;
            try writer.print("set \"{s}=", .{key});
            for (value) |c| {
                try writer.writeByte(c);
                if (c == '%') try writer.writeByte(c);
            }
            if (prepend) try writer.writeAll(";%PATH%");
            try writer.writeAll("\"\r\n");
        }
    }

    fn renderShellTemplate(
        allocator: std.mem.Allocator,
        template: []const u8,
        run_env: moonstone.project.run_env.RunEnv,
        project_root: []const u8,
        syntax: ShellSyntax,
    ) ![]const u8 {
        _ = template;
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        const writer = &output.writer;
        try writer.writeAll(if (syntax == .posix) "export PATH=" else "set -gx PATH ");
        try writeLiteral(writer, syntax, run_env.bin_path);
        try writer.writeAll(if (syntax == .posix) ":\"$PATH\"\n" else " $PATH\n");
        try writeShellAssignment(writer, syntax, "LUA_PATH", run_env.lua_path);
        try writeShellAssignment(writer, syntax, "LUA_CPATH", run_env.lua_cpath);
        if (run_env.native_lib_path) |path| {
            if (moonstone.project.environment.nativeLibraryEnvironmentVariable()) |key| {
                if (syntax == .posix) try writer.print("export {s}=", .{key}) else try writer.print("set -gx {s} ", .{key});
                try writeLiteral(writer, syntax, path);
                if (syntax == .posix) try writer.print(":\"${{{s}:-}}\"\n", .{key}) else try writer.print(" ${s}\n", .{key});
            }
        }
        for (run_env.package_roots) |entry| try writeShellAssignment(writer, syntax, entry.key, entry.root);
        try writeShellAssignment(writer, syntax, "MOONSTONE_ENV_ACTIVE", project_root);
        return allocator.dupe(u8, writer.buffered());
    }

    pub fn run(self: EnvCommand, ctx: *router.Context) !void {
        if (self.shell) |shell| {
            if (!std.mem.eql(u8, shell, "bash") and !std.mem.eql(u8, shell, "zsh") and !std.mem.eql(u8, shell, "fish") and !std.mem.eql(u8, shell, "powershell") and !std.mem.eql(u8, shell, "cmd")) {
                ctx.error_detail = .{ .message = .{ .msg = "Environment export supports bash, zsh, fish, powershell, and cmd. Choose one with --shell." } };
                return error.UnsupportedShell;
            }
        }
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const global_project = if (self.global) try @import("global_tools.zig").enterProject(allocator, env, io) else null;
        defer if (global_project) |gp| @import("global_tools.zig").leaveProject(allocator, io, gp);

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
        } else if (self.bin_runtime_names) {
            // bin-runtime scopes live as a sibling of the flat bin/ directory
            // this same run_env resolved above (`--paths` prints that
            // directory directly; here we look at its sibling instead of
            // re-deriving the project root ourselves).
            const bin_runtime_path = try std.fs.path.join(allocator, &.{
                std.fs.path.dirname(run_env.bin_path) orelse ".",
                "bin-runtime",
            });
            defer allocator.free(bin_runtime_path);

            var bin_runtime_dir = std.Io.Dir.openDirAbsolute(io, bin_runtime_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return,
                else => return err,
            };
            defer bin_runtime_dir.close(io);

            var it = bin_runtime_dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .directory) continue;
                try stdout.print("{s}\n", .{entry.name});
            }
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
            } else if (std.mem.eql(u8, s, "powershell") or std.mem.eql(u8, s, "cmd")) {
                const powershell = std.mem.eql(u8, s, "powershell");
                try writeWindowsAssignment(stdout, powershell, "PATH", run_env.bin_path, true);
                try writeWindowsAssignment(stdout, powershell, "LUA_PATH", run_env.lua_path, false);
                try writeWindowsAssignment(stdout, powershell, "LUA_CPATH", run_env.lua_cpath, false);
                for (run_env.package_roots) |entry| try writeWindowsAssignment(stdout, powershell, entry.key, entry.root, false);
                try writeWindowsAssignment(stdout, powershell, "MOONSTONE_ENV_ACTIVE", project_root, false);
            } else {
                unreachable; // Shell names are validated before environment discovery.
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

test "unsupported shell fails before project or global environment discovery" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = router.Context{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdout = &writer,
        .stderr = &writer,
        .env = &env,
    };
    try std.testing.expectError(error.UnsupportedShell, (EnvCommand{ .shell = "unsupported", .global = true }).run(&ctx));
    try std.testing.expect(ctx.error_detail != null);
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "Windows environment exports quote literals and reject command injection" {
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try EnvCommand.writeWindowsAssignment(&writer, true, "PATH", "C:\\Lua's $tools", true);
    try std.testing.expectEqualStrings("$env:PATH = 'C:\\Lua''s $tools;' + $env:PATH\n", writer.buffered());
    writer.end = 0;
    try EnvCommand.writeWindowsAssignment(&writer, false, "ROOT", "C:\\100% & tools", false);
    try std.testing.expectEqualStrings("set \"ROOT=C:\\100%% & tools\"\r\n", writer.buffered());
    try std.testing.expectError(error.UnrepresentableShellValue, EnvCommand.writeWindowsAssignment(&writer, true, "ROOT", "x\ny", false));
    try std.testing.expectError(error.UnrepresentableShellValue, EnvCommand.writeWindowsAssignment(&writer, false, "ROOT", "x\" & echo bad", false));
}
