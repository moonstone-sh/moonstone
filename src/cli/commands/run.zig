const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");

pub const RunCommand = struct {
    pub const name = "run";
    pub const description = "Run a named script from moonstone.toml";

    positionals: []const []const u8 = &.{},
    prod: bool = false,
    dev: bool = true,
    shell: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    target: ?[]const u8 = null,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon run <script-name> [-- [args...]]
            \\
            \\Run a named script from [scripts] in moonstone.toml.
            \\
            \\Flags:
            \\  --prod           Exclude development dependencies
            \\  --dev            Include development dependencies (default)
            \\  --shell <s>      Shell to use for execution
            \\  --runtime <r>    Override runtime
            \\  --target <t>     Override target
            \\  --json           Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        _ = args;
        const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch return &.{};
        defer ctx.allocator.free(content);
        var mt = moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content) catch return &.{};
        defer mt.deinit(ctx.allocator);

        var list = std.ArrayList([]const u8).empty;
        var sit = mt.scripts.iterator();
        while (sit.next()) |entry| {
            try list.append(ctx.allocator, try ctx.allocator.dupe(u8, entry.key_ptr.*));
        }
        return list.toOwnedSlice(ctx.allocator);
    }

    pub fn run(self: RunCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
        defer project_root.deinit(allocator);

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (self.positionals.len == 0) {
            if (emitter) |e| {
                try e.fail(io, "args", "error.ScriptRequired", .{});
                return command_mod.CommonError.AlreadyReported;
            } else {
                try stdout.print("Error: script name required.\n", .{});
                return error.ScriptRequired;
            }
        }
        const s_name = self.positionals[0];
        const script_args = self.positionals[1..];

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{ .script = s_name, .args = script_args });
        }

        const content = try std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        const script_cmd = mt.scripts.get(s_name) orelse {
            if (emitter) |e| {
                try e.fail(io, s_name, "error.ScriptNotFound", .{});
            } else {
                try stdout.print("Error: script '{s}' not found in moonstone.toml\n", .{s_name});
            }
            return error.ScriptNotFound;
        };

        if (emitter == null) {
            try stdout.print("> {s}\n\n", .{ script_cmd });
        }

        var run_env = try moonstone.project.run_env.get_run_env(allocator, io, ".", env);
        defer run_env.deinit();

        // npm-like behavior: scripts are shell strings
        const shell_bin = self.shell orelse "sh";

        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, shell_bin);
        try argv.append(allocator, "-c");
        try argv.append(allocator, script_cmd);
        try argv.append(allocator, s_name);
        for (script_args) |arg| {
            try argv.append(allocator, arg);
        }

        var term = try std.process.spawn(io, .{
            .argv = argv.items,
            .environ_map = &run_env.env_map,
            .expand_arg0 = .expand,
            .stdout = .inherit,
            .stderr = .inherit,
        });

        const wait_res = try term.wait(io);
        if (wait_res != .exited or wait_res.exited != 0) {
            std.process.exit(if (wait_res == .exited) @intCast(wait_res.exited) else 1);
        }

        if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .script = s_name, .args = script_args });
        }
    }
};
