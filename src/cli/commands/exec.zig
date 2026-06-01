const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const ExecCommand = struct {
    pub const name = "exec";
    pub const description = "Run arbitrary command inside environment";

    positionals: []const []const u8 = &.{},
    prod: bool = false,
    dev: bool = true,
    runtime: ?[]const u8 = null,
    target: ?[]const u8 = null,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon exec [flags] <command> [args...]
            \\
            \\Executes an arbitrary command in the project environment.
            \\
            \\Flags:
            \\  --prod           Exclude development dependencies
            \\  --dev            Include development dependencies (default)
            \\  --runtime <r>    Override runtime
            \\  --target <t>     Override target
            \\  --json           Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn run(self: ExecCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (self.positionals.len == 0) {
            if (emitter) |e| {
                try e.emit(io, .ERROR, "args", "error.CommandRequired", .{});
            } else {
                try stdout.print("Error: command required.\n", .{});
            }
            return error.CommandRequired;
        }

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{ .argv = self.positionals });
        }

        // Recursion protection
        const depth_str = env.get("MOONSTONE_EXEC_DEPTH") orelse "0";
        const depth = std.fmt.parseInt(u32, depth_str, 10) catch 0;
        if (depth > 10) return error.InfiniteRecursion;

        var run_env = try moonstone.project.run_env.get_run_env(allocator, io, ".", env);
        defer run_env.deinit();

        const depth_val = try std.fmt.allocPrint(allocator, "{d}", .{depth + 1});
        defer allocator.free(depth_val);
        try run_env.env_map.put("MOONSTONE_EXEC_DEPTH", depth_val);

        // Filter out shims directory from PATH to avoid looping back to them if absolute resolution fails
        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }
        
        const real_shims = std.Io.Dir.cwd().realPathFileAlloc(io, paths.shims, allocator) catch try allocator.dupe(u8, paths.shims);
        defer allocator.free(real_shims);

        if (run_env.env_map.get("PATH")) |path_val| {
            var new_path = std.ArrayList(u8).empty;
            defer new_path.deinit(allocator);
            
            var it = std.mem.splitScalar(u8, path_val, ':');
            var first = true;
            while (it.next()) |p| {
                if (p.len == 0) continue;
                const real_p = std.Io.Dir.cwd().realPathFileAlloc(io, p, allocator) catch blk: {
                    if (std.fs.path.isAbsolute(p)) break :blk try allocator.dupe(u8, p);
                    break :blk try std.fs.path.resolve(allocator, &.{p});
                };
                defer allocator.free(real_p);

                if (std.mem.eql(u8, real_p, real_shims)) continue;
                if (!first) try new_path.append(allocator, ':');
                try new_path.appendSlice(allocator, p);
                first = false;
            }
            try run_env.env_map.put("PATH", new_path.items);
        }

        var argv = try allocator.dupe([]const u8, self.positionals);
        defer allocator.free(argv);

        // Try to resolve executable in environment's bin directory first
        const bin_exec = try std.fs.path.join(allocator, &.{ run_env.bin_path, self.positionals[0] });
        defer allocator.free(bin_exec);
        
        if (std.Io.Dir.openFileAbsolute(io, bin_exec, .{})) |file| {
            file.close(io);
            argv[0] = try allocator.dupe(u8, bin_exec);
        } else |err| {
            // If we are trying to run 'lua' or 'luac' and we didn't find them in the bin dir,
            // we should NOT fallback to bare name if we are called from a shim.
            if (depth > 0 and (std.mem.eql(u8, self.positionals[0], "lua") or std.mem.eql(u8, self.positionals[0], "luac"))) {
                return err;
            }
        }

        if (emitter) |e| {
            try e.emit(io, .STATUS, "exec", "starting", .{ .resolved_argv = argv });
            try e.terminate(io, name, "executing", .{});
            try stdout.flush();
        }

        var term = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = &run_env.env_map,
            .expand_arg0 = .expand,
        });

        const wait_res = try term.wait(io);

        if (wait_res != .exited or wait_res.exited != 0) {
            std.process.exit(if (wait_res == .exited) @intCast(wait_res.exited) else 1);
        }
    }
};
