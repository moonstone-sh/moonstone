const std = @import("std");
const builtin = @import("builtin");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const toml = @import("toml");

fn pathSeparator() u8 {
    return if (builtin.os.tag == .windows) ';' else ':';
}

/// Whether this target carries POSIX permission bits worth reporting.
const reports_modes: bool = builtin.os.tag != .windows and builtin.os.tag != .wasi;

/// Diagnose an exec that failed with AccessDenied. Returns an owned message when
/// the resolved path is a real file with no execute bit anywhere — the signature
/// of a package published without it — and null in every other case so the caller
/// can fall back to a generic message. A diagnostic must never itself fail the
/// command, so each probe degrades to null rather than propagating.
fn nonExecutableDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    resolved_path: []const u8,
) ?[]u8 {
    if (comptime !reports_modes) return null;
    const st = std.Io.Dir.cwd().statFile(io, resolved_path, .{}) catch return null;
    if (st.kind != .file) return null;
    const mode: u32 = @intCast(st.permissions.toMode());
    if (mode & 0o111 != 0) return null;
    return std.fmt.allocPrint(
        allocator,
        "'{s}' resolved to {s} but is not executable (mode {o:0>4}) — the package may have been published without the executable bit",
        .{ command, resolved_path, mode & 0o777 },
    ) catch null;
}

/// Append the `[provides]` bin names declared by a store manifest.
fn appendProvidedBinNames(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    provides: *const toml.Table,
) !void {
    // A package declares runnable provisions under several keys depending on
    // whether the bin is native or a Lua entry point. Read them all.
    for ([_][]const u8{ "bins", "bin", "bin_lua", "bin_luas", "scripts" }) |key| {
        const value = provides.get(key) orelse continue;
        if (value != .array) continue;
        for (value.array.items) |item| {
            if (item != .table) continue;
            const name_value = item.table.get("name") orelse continue;
            if (name_value != .string) continue;
            if (name_value.string.len == 0) continue;
            try names.append(allocator, try allocator.dupe(u8, name_value.string));
        }
    }
}

/// When a command name is in fact a resolved dependency's PACKAGE name, report
/// the bin names that package actually provides. `moon exec` takes a command
/// name, never a package name, and the two are legitimately different, so the
/// remedy is to name the real command rather than to resolve package names here.
///
/// Returns an owned ", "-joined list, or null when there is no unambiguous match.
/// Every failure path yields null: this runs only while reporting another error
/// and must not replace it with one of its own.
fn providedBinsForPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    working_directory: ?[]const u8,
    package_name: []const u8,
) ?[]u8 {
    const base = working_directory orelse ".";
    const deps_path = std.fs.path.join(allocator, &.{ base, ".moonstone", "env", "dependencies.toml" }) catch return null;
    defer allocator.free(deps_path);

    const deps_text = std.Io.Dir.cwd().readFileAlloc(io, deps_path, allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch return null;
    defer allocator.free(deps_text);

    var deps_parser = toml.Parser(toml.Table).init(allocator);
    defer deps_parser.deinit();
    var deps_doc = deps_parser.parseString(deps_text) catch return null;
    defer deps_doc.deinit();

    const dependencies = deps_doc.value.get("dependencies") orelse return null;
    if (dependencies != .array) return null;

    // Locate the dependency whose package name is exactly what was typed.
    var artifact_path: ?[]const u8 = null;
    for (dependencies.array.items) |entry| {
        if (entry != .table) continue;
        const name_value = entry.table.get("name") orelse continue;
        if (name_value != .string) continue;
        if (!std.mem.eql(u8, name_value.string, package_name)) continue;
        const path_value = entry.table.get("path") orelse continue;
        if (path_value != .string) continue;
        if (artifact_path != null) return null; // ambiguous; say nothing
        artifact_path = path_value.string;
    }
    const resolved_artifact = artifact_path orelse return null;

    const manifest_path = std.fs.path.join(allocator, &.{ resolved_artifact, "manifest.toml" }) catch return null;
    defer allocator.free(manifest_path);

    const manifest_text = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch return null;
    defer allocator.free(manifest_text);

    var manifest_parser = toml.Parser(toml.Table).init(allocator);
    defer manifest_parser.deinit();
    var manifest_doc = manifest_parser.parseString(manifest_text) catch return null;
    defer manifest_doc.deinit();

    const provides = manifest_doc.value.get("provides") orelse return null;
    if (provides != .table) return null;

    var names = std.ArrayList([]const u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    appendProvidedBinNames(allocator, &names, provides.table) catch return null;
    if (names.items.len == 0) return null;

    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (names.items, 0..) |n, i| {
        if (i > 0) joined.appendSlice(allocator, ", ") catch return null;
        joined.append(allocator, '\'') catch return null;
        joined.appendSlice(allocator, n) catch return null;
        joined.append(allocator, '\'') catch return null;
    }
    return allocator.dupe(u8, joined.items) catch null;
}

pub const ExecCommand = struct {
    pub const name = "exec";
    pub const description = "Run arbitrary command inside environment";
    pub const opaque_arguments_after = 1;

    positionals: []const []const u8 = &.{},
    prod: bool = false,
    dev: bool = false,
    interpreter: ?[]const u8 = null,
    json: bool = false,
    global: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon exec [options] <command> [args...]
            \\
            \\Executes an arbitrary command inside the project environment.
            \\
            \\All Moonstone options must appear BEFORE <command>. Once <command> is
            \\encountered, ownership of all remaining arguments transfers to the child
            \\process unchanged.
            \\
            \\An optional '--' may appear before <command> to explicitly terminate Moonstone
            \\option parsing. One '--' after <command> is treated as an argument delimiter
            \\and is not forwarded; use a second '--' to pass a literal delimiter.
            \\
            \\Options:
            \\  --prod           Exclude development dependencies
            \\  --dev            Include development dependencies (default)
            \\  --interpreter <i> Override interpreter
            \\  --json           Output results as JSON
            \\  --global         Run command from the global tools environment
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

        const global_project = if (self.global) try @import("global_tools.zig").enterProject(allocator, env, io) else null;
        defer if (global_project) |gp| @import("global_tools.zig").leaveProject(allocator, io, gp);

        // Recursion protection
        const depth_str = env.get("MOONSTONE_EXEC_DEPTH") orelse "0";
        const depth = std.fmt.parseInt(u32, depth_str, 10) catch 0;
        if (depth > 10) return error.InfiniteRecursion;

        var run_env = (if (ctx.working_directory) |root|
            moonstone.project.run_env.get_run_env_at_root(allocator, io, root, env)
        else
            moonstone.project.run_env.get_run_env(allocator, io, ".", env)) catch |err| {
            if (self.global and err == error.NoActiveEnvironment) {
                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, "global tools environment is not synced; install a tool with `moon add --global --tool <pkg>` first") } };
            }
            return err;
        };
        defer run_env.deinit();

        const depth_val = try std.fmt.allocPrint(allocator, "{d}", .{depth + 1});
        defer allocator.free(depth_val);
        try run_env.env_map.put("MOONSTONE_EXEC_DEPTH", depth_val);

        // Check for isolated runtime env metadata for this binary
        const bin_runtime_env_path = try std.fs.path.join(allocator, &.{ ".moonstone", "env", "bin-runtime", self.positionals[0], "env.toml" });
        defer allocator.free(bin_runtime_env_path);

        if (std.Io.Dir.cwd().access(io, bin_runtime_env_path, .{})) |_| {
            const env_content = try std.Io.Dir.cwd().readFileAlloc(io, bin_runtime_env_path, allocator, std.Io.Limit.limited(1024 * 1024));
            defer allocator.free(env_content);

            var parser = toml.Parser(toml.Table).init(allocator);
            defer parser.deinit();
            var res = try parser.parseString(env_content);
            defer res.deinit();

            if (res.value.get("env")) |env_val| {
                const env_table = env_val.table;

                if (env_table.get("path_prepend")) |pp| {
                    for (pp.array.items) |item| {
                        const path_to_prepend = item.string;
                        const old_path = run_env.env_map.get("PATH") orelse "";
                        const new_path = if (old_path.len > 0)
                            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ path_to_prepend, pathSeparator(), old_path })
                        else
                            try allocator.dupe(u8, path_to_prepend);
                        defer allocator.free(new_path);
                        try run_env.env_map.put("PATH", new_path);
                    }
                }

                if (env_table.get("lua_path")) |lp| {
                    var lua_path_list = std.ArrayList(u8).empty;
                    defer lua_path_list.deinit(allocator);
                    for (lp.array.items, 0..) |item, i| {
                        if (i > 0) try lua_path_list.appendSlice(allocator, ";");
                        try lua_path_list.appendSlice(allocator, item.string);
                    }
                    // Prepend to existing project LUA_PATH
                    if (run_env.env_map.get("LUA_PATH")) |old_lp| {
                        if (old_lp.len > 0) {
                            try lua_path_list.appendSlice(allocator, ";");
                            try lua_path_list.appendSlice(allocator, old_lp);
                        }
                    }
                    try lua_path_list.appendSlice(allocator, ";;");
                    try run_env.env_map.put("LUA_PATH", lua_path_list.items);
                    const lua_path_key = try std.fmt.allocPrint(allocator, "LUA_PATH_{s}", .{run_env.lua_ver_suffix});
                    defer allocator.free(lua_path_key);
                    try run_env.env_map.put(lua_path_key, lua_path_list.items);
                }

                if (env_table.get("lua_cpath")) |lp| {
                    var lua_cpath_list = std.ArrayList(u8).empty;
                    defer lua_cpath_list.deinit(allocator);
                    for (lp.array.items, 0..) |item, i| {
                        if (i > 0) try lua_cpath_list.appendSlice(allocator, ";");
                        try lua_cpath_list.appendSlice(allocator, item.string);
                    }
                    // Prepend to existing project LUA_CPATH
                    if (run_env.env_map.get("LUA_CPATH")) |old_lp| {
                        if (old_lp.len > 0) {
                            try lua_cpath_list.appendSlice(allocator, ";");
                            try lua_cpath_list.appendSlice(allocator, old_lp);
                        }
                    }
                    try lua_cpath_list.appendSlice(allocator, ";;");
                    try run_env.env_map.put("LUA_CPATH", lua_cpath_list.items);
                    const lua_cpath_key = try std.fmt.allocPrint(allocator, "LUA_CPATH_{s}", .{run_env.lua_ver_suffix});
                    defer allocator.free(lua_cpath_key);
                    try run_env.env_map.put(lua_cpath_key, lua_cpath_list.items);
                }
            }
        } else |_| {}

        // Filter out shims directory from PATH to avoid looping back to them if absolute resolution fails
        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        const real_shims = std.Io.Dir.cwd().realPathFileAlloc(io, paths.shims, allocator) catch try allocator.dupe(u8, paths.shims);
        defer allocator.free(real_shims);

        if (run_env.env_map.get("PATH")) |path_val| {
            var new_path = std.ArrayList(u8).empty;
            defer new_path.deinit(allocator);

            var it = std.mem.splitScalar(u8, path_val, pathSeparator());
            var first = true;
            while (it.next()) |p| {
                if (p.len == 0 or !std.fs.path.isAbsolute(p)) continue;
                const real_p = std.Io.Dir.cwd().realPathFileAlloc(io, p, allocator) catch try allocator.dupe(u8, p);
                defer allocator.free(real_p);

                if (std.mem.eql(u8, real_p, real_shims)) continue;
                if (!first) try new_path.append(allocator, pathSeparator());
                try new_path.appendSlice(allocator, p);
                first = false;
            }
            try run_env.env_map.put("PATH", new_path.items);
        }

        var argv = try allocator.dupe([]const u8, self.positionals);
        defer allocator.free(argv);

        // Try to resolve executable in environment's bin directory first
        if (try moonstone.platform.executable.resolveInDirectory(allocator, io, run_env.bin_path, self.positionals[0])) |bin_exec| {
            defer allocator.free(bin_exec);
            // In runtime mode, verify the binary is not dev-only
            var allow = true;
            if (!self.dev) {
                allow = moonstone.project.run_env.isEnvEntryAllowed(allocator, io, ".", self.positionals[0], .runtime) catch true;
            }
            if (allow) {
                argv[0] = try allocator.dupe(u8, bin_exec);
            } else {
                if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
                ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "'{s}' is a development-only binary. Use 'moon exec --dev {s}' to run it.", .{ self.positionals[0], self.positionals[0] }) } };
                return error.DevOnlyBinary;
            }
        } else {
            // If we are trying to run 'lua' or 'luac' and we didn't find them in the bin dir,
            // we should NOT fallback to bare name if we are called from a shim.
            if (depth > 0 and (std.mem.eql(u8, self.positionals[0], "lua") or std.mem.eql(u8, self.positionals[0], "luac"))) {
                return error.FileNotFound;
            }
        }

        // Workaround: std.process.spawn uses parent PATH for expand_arg0 resolution,
        // ignoring environ_map PATH. Manually search PATH from run_env.env_map.
        if (!std.fs.path.isAbsolute(argv[0])) {
            if (run_env.env_map.get("PATH")) |path_val| {
                var path_it = std.mem.splitScalar(u8, path_val, pathSeparator());
                while (path_it.next()) |dir| {
                    if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
                    if (try moonstone.platform.executable.resolveInDirectory(allocator, io, dir, self.positionals[0])) |candidate| {
                        defer allocator.free(candidate);
                        argv[0] = try allocator.dupe(u8, candidate);
                        break;
                    }
                }
            }
        }

        var prepared_argv = try moonstone.platform.process.prepareArgv(allocator, argv);
        defer prepared_argv.deinit(allocator);

        try stdout.flush();

        if (emitter) |e| {
            try e.emit(io, .STATUS, "exec", "starting", .{ .resolved_argv = prepared_argv.argv });
            try e.terminate(io, name, "executing", .{});
            try stdout.flush();
        }

        if (comptime std.process.can_replace) {
            // Replace this process with the child. Signals (SIGINT, SIGTERM,
            // etc.) are delivered directly to the child, avoiding orphaned
            // process trees when the user presses Ctrl+C.
            const err = std.process.replace(io, .{
                .argv = prepared_argv.argv,
                .environ_map = &run_env.env_map,
                .expand_arg0 = .expand,
            });
            return self.reportSpawnFailure(ctx, io, argv[0], err);
        }

        var child = std.process.spawn(io, .{
            .argv = prepared_argv.argv,
            .environ_map = &run_env.env_map,
            .expand_arg0 = .expand,
        }) catch |err| {
            return self.reportSpawnFailure(ctx, io, argv[0], err);
        };
        const wait_result = try child.wait(io);
        if (wait_result != .exited or wait_result.exited != 0) {
            std.process.exit(if (wait_result == .exited) @intCast(wait_result.exited) else 1);
        }
    }

    /// Turn a raw spawn failure into an actionable message. `execve` reports the
    /// kernel's verdict, not the reason: AccessDenied on a package binary almost
    /// always means the file shipped without its execute bit, and FileNotFound on
    /// a name containing a package's shape usually means a package name was typed
    /// where a command name belongs. Unrecognized errors pass through untouched.
    fn reportSpawnFailure(
        self: ExecCommand,
        ctx: *router.Context,
        io: std.Io,
        resolved_path: []const u8,
        err: anyerror,
    ) anyerror {
        const allocator = ctx.allocator;
        const command = self.positionals[0];

        const message: []u8 = switch (err) {
            error.FileNotFound => blk: {
                if (providedBinsForPackage(allocator, io, ctx.working_directory, command)) |bins| {
                    defer allocator.free(bins);
                    break :blk std.fmt.allocPrint(
                        allocator,
                        "command not found: '{s}' (did you mean the bin it provides: {s}?)",
                        .{ command, bins },
                    ) catch return err;
                }
                break :blk std.fmt.allocPrint(allocator, "command not found: '{s}'", .{command}) catch return err;
            },
            error.AccessDenied => nonExecutableDiagnostic(allocator, io, command, resolved_path) orelse
                (std.fmt.allocPrint(
                    allocator,
                    "cannot execute '{s}' ({s}): permission denied",
                    .{ command, resolved_path },
                ) catch return err),
            else => return err,
        };

        if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
        ctx.error_detail = .{ .message = .{ .msg = message } };
        return if (err == error.FileNotFound) error.CommandNotFound else err;
    }
};
