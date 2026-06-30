const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");

pub const InterpreterSetCommand = struct {
    pub const name = "set";
    pub const description = "Select project or global Lua interpreter";

    positionals: []const []const u8 = &.{},
    target: ?[]const u8 = null,
    global: bool = false,
    sync: bool = true,
    no_sync: bool = false,
    save: bool = true,
    no_save: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon interpreter set <spec> [flags]
            \\
            \\Select the project or global Lua interpreter.
            \\
            \\Arguments:
            \\  <spec>           Interpreter spec (e.g. lua@5.4, luajit@2.1)
            \\
            \\Flags:
            \\  --global         Set as the global default interpreter
            \\  --target <t>     Target triple
            \\  --no-sync     Do not run moon sync
            \\  --no-save        Do not update moonstone.toml
            \\  --json           Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        const current = if (args.len > 0) args[args.len - 1] else "";
        if (std.mem.startsWith(u8, current, "--")) return &.{};

        var list = std.ArrayList([]const u8).empty;
        var seen = std.StringHashMap(void).init(ctx.allocator);
        defer seen.deinit();

        try appendInstalledInterpreters(ctx, current, &list, &seen);

        const defaults = [_][]const u8{ "lua@5.1", "lua@5.2", "lua@5.3", "lua@5.4", "luajit@2.1" };
        for (defaults) |spec| try appendSuggestion(ctx.allocator, &list, &seen, current, spec);

        return list.toOwnedSlice(ctx.allocator);
    }

    fn appendInstalledInterpreters(ctx: *router.Context, prefix: []const u8, list: *std.ArrayList([]const u8), seen: *std.StringHashMap(void)) !void {
        const paths = moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io) catch return;
        var mutable_paths = paths;
        defer mutable_paths.deinit(ctx.allocator);

        const index_db_path = try std.fs.path.join(ctx.allocator, &.{ paths.index, "index.sqlite" });
        defer ctx.allocator.free(index_db_path);
        const index_db_path_z = try ctx.allocator.dupeZ(u8, index_db_path);
        defer ctx.allocator.free(index_db_path_z);

        var idx = moonstone.store.driver.StoreDriver.init(ctx.allocator, index_db_path_z) catch return;
        defer idx.deinit();

        const c = moonstone.store.driver.c;
        const sql = "SELECT DISTINCT name, version FROM artifacts WHERE kind = 'runtime' ORDER BY name, version DESC;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            var interpreter_name = std.mem.span(c.sqlite3_column_text(stmt, 0));
            const version = std.mem.span(c.sqlite3_column_text(stmt, 1));
            if (std.mem.startsWith(u8, interpreter_name, "moonstone/")) interpreter_name = interpreter_name["moonstone/".len..];
            const spec = try std.fmt.allocPrint(ctx.allocator, "{s}@{s}", .{ interpreter_name, version });
            defer ctx.allocator.free(spec);
            try appendSuggestion(ctx.allocator, list, seen, prefix, spec);
        }
    }

    fn appendSuggestion(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), seen: *std.StringHashMap(void), prefix: []const u8, suggestion: []const u8) !void {
        if (prefix.len > 0 and !std.mem.startsWith(u8, suggestion, prefix)) return;
        if (seen.contains(suggestion)) return;
        const owned = try allocator.dupe(u8, suggestion);
        try seen.put(owned, {});
        try list.append(allocator, owned);
    }

    pub fn run(self: InterpreterSetCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (self.positionals.len == 0) {
            ctx.error_detail = .{ .message = .{ .msg = "interpreter spec required (e.g. lua@5.4)" } };
            return error.MissingArgument;
        }
        const spec = self.positionals[0];

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{ .spec = spec, .global = self.global });
        }

        var interpreter_name: []const u8 = "lua";
        var version = spec;
        if (std.mem.indexOfScalar(u8, spec, '@')) |pos| {
            interpreter_name = spec[0..pos];
            version = spec[pos+1..];
        }

        if (self.global) {
            try self.runGlobal(ctx, version, emitter);
            return;
        }

        const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
        defer project_root.deinit(allocator);

        const toml_path = "moonstone.toml";
        const content = std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                if (emitter == null) {
                    try stdout.print("Error: moonstone.toml not found. Did you mean `moon interpreter set --global`?\n", .{});
                }
                return error.FileNotFound;
            }
            return err;
        };
        defer allocator.free(content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, content);
        defer mt.deinit(allocator);

        const effective_save = self.save and !self.no_save;
        if (effective_save) {
            allocator.free(mt.runtime.name);
            allocator.free(mt.runtime.version);
            allocator.free(mt.runtime.abi);

            const interpreter_abi = try moonstone.domain.manifest.inferRuntimeAbi(allocator, interpreter_name, version);
            
            mt.runtime.name = try allocator.dupe(u8, interpreter_name);
            mt.runtime.version = try allocator.dupe(u8, version);
            mt.runtime.abi = interpreter_abi;

            const toml_file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
            defer toml_file.close(io);

            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try mt.serialize(allocator, &aw.writer);
            try aw.writer.flush();
            try toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

            // TODO(interpreter-luarc): update .luarc.json workspace targets when the project interpreter changes.

            if (emitter) |e| {
                try e.emit(io, .STATUS, "manifest", "written", .{ .interpreter = version, .abi = interpreter_abi });
            } else {
                try stdout.print("Project interpreter updated to {s} {s}.\n", .{ interpreter_name, version });
            }
        }

        const effective_sync = self.sync and !self.no_sync;
        if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .version = version, .env_regenerated = effective_sync });
        }

        if (effective_sync) {
            if (emitter == null) {
                try @import("command.zig").progress(stdout, "Running sync...\n", .{});
            }
            const sync_command = @import("sync.zig").sync_command{ .json = self.json };
            try sync_command.run(ctx);
        }
    }

    fn runGlobal(self: InterpreterSetCommand, ctx: *router.Context, version: []const u8, emitter: ?*ndjson.Emitter) !void {
        _ = self;
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);
        
        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        const registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        defer moonstone.registry.core.deinitResolved(registries, allocator);

        var resolver = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };
        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
        };

        const rt_res = try resolver.resolve(moonstone.domain.package_spec.canonicalOfficialRuntime("lua"), version, idx, registries, .{
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        }, env);
        defer { var r = rt_res; r.deinit(allocator); }

        // Materialize if remote
        if (rt_res.local_path == null) {
            var mat = moonstone.materialization.materializer.Materializer{
                .allocator = allocator,
                .io = io,
                .environ_map = env,
                .on_event = @import("command.zig").onResolveEvent,
                .on_event_context = &resolve_cb_ctx,
            };
            const m = try mat.materialize_remote(
                rt_res.registry_url.?,
                rt_res.registry_token,
                rt_res.descriptor_path.?,
                rt_res.remote_desc.?,
                rt_res.artifact_idx.?,
            );
            m.deinit(allocator);
        }

        // Update config.toml
        const config_toml_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
        defer allocator.free(config_toml_path);

        const config_content = try std.Io.Dir.cwd().readFileAlloc(io, config_toml_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(config_content);

        // Simple string replacement for now to avoid parsing/serializing the whole thing and losing comments
        // Real implementation should use a proper TOML editor if we want to preserve structure.
        // For now, let's just use the parser to verify and then do a surgical edit.
        
        var parser = moonstone.domain.manifest.toml.Parser(moonstone.domain.manifest.toml.Table).init(allocator);
        defer parser.deinit();
        var res = try parser.parseString(config_content);
        defer res.deinit();

        const full_spec = try std.fmt.allocPrint(allocator, "lua-{s}", .{rt_res.version});
        defer allocator.free(full_spec);

        // This is a bit hacky but efficient for preservation
        const key = "default_runtime = \"";
        if (std.mem.indexOf(u8, config_content, key)) |pos| {
            const end_pos = std.mem.indexOfScalarPos(u8, config_content, pos + key.len, '"') orelse return error.InvalidConfig;
            const new_config = try std.mem.concat(allocator, u8, &.{ config_content[0 .. pos + key.len], full_spec, config_content[end_pos..] });
            defer allocator.free(new_config);

            const file = try std.Io.Dir.cwd().createFile(io, config_toml_path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, new_config);
        } else {
            return error.ConfigKeyNotFound;
        }

        if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .version = rt_res.version, .global = true });
        } else {
            try stdout.print("Global default interpreter updated to Lua {s}.\n", .{rt_res.version});
        }
    }
};
