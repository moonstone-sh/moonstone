const std = @import("std");
const moonstone = @import("moonstone");
const MoonstoneToml = moonstone.domain.manifest.MoonstoneToml;
const Kind = moonstone.domain.manifest.Kind;
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");
const command_mod = @import("command.zig");

pub const init_command = struct {
    pub const command_name = "init";
    pub const description = "Create a new Moonstone project";

    positionals: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    template: ?[]const u8 = null,
    license: ?[]const u8 = null,
    lib: bool = false,
    bin: bool = false,
    no_git: bool = false,
    no_sync: bool = false,
    yes: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon init [path] [flags]
            \\
            \\Create a new Moonstone project.
            \\
            \\Arguments:
            \\  [path]           Target directory (default: current directory)
            \\
            \\Flags:
            \\  --name <name>    Project name (default: basename of target directory)
            \\  --version <v>    Initial version (default: 0.1.0)
            \\  --description <d> Project description
            \\  --kind <kind>    Package kind: script|lib|bin|runtime (default: script)
            \\  --lib            Shortcut for --kind lib
            \\  --bin            Shortcut for --kind bin
            \\  --runtime <spec> Lua runtime spec: lua@5.4|luajit@2.1|...
            \\  --template <t>   Project template: script|lib|nvim|love|c-bin|zig-bin|rust-bin|bin
            \\  --license <id>   SPDX license identifier
            \\  --no-git         Do not initialize a git repository
            \\  --no-sync     Do not run moon sync after init
            \\  --yes            Assume yes for all prompts
            \\  --json           Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn deinit(self: *init_command, allocator: std.mem.Allocator) void {
        allocator.free(self.positionals);
    }

    fn renderTemplate(allocator: std.mem.Allocator, template: []const u8, name: []const u8, lua_ver: []const u8) ![]const u8 {
        var result = try allocator.dupe(u8, template);
        errdefer allocator.free(result);

        // Replace {{name}}
        while (std.mem.indexOf(u8, result, "{{name}}")) |pos| {
            const new_res = try std.mem.concat(allocator, u8, &.{ result[0..pos], name, result[pos + 8 ..] });
            allocator.free(result);
            result = new_res;
        }

        // Replace {{lua_ver}}
        while (std.mem.indexOf(u8, result, "{{lua_ver}}")) |pos| {
            const new_res = try std.mem.concat(allocator, u8, &.{ result[0..pos], lua_ver, result[pos + 11 ..] });
            allocator.free(result);
            result = new_res;
        }

        return result;
    }

    fn defaultRuntimeSpec(allocator: std.mem.Allocator, env: *std.process.Environ.Map, io: std.Io) !?[]const u8 {
        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var mp = paths; mp.deinit(allocator); }

        const config_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
        defer allocator.free(config_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer allocator.free(content);

        var parser = moonstone.domain.manifest.toml.Parser(moonstone.domain.manifest.toml.Table).init(allocator);
        defer parser.deinit();
        const parsed = try parser.parseString(content);
        defer parsed.deinit();

        const moonstone_table = parsed.value.get("moonstone") orelse return null;
        const default_runtime = moonstone_table.table.get("default_runtime") orelse return null;
        const raw_spec = default_runtime.string;
        const separator = std.mem.indexOfScalar(u8, raw_spec, '-') orelse return try allocator.dupe(u8, raw_spec);
        return try std.fmt.allocPrint(allocator, "{s}@{s}", .{ raw_spec[0..separator], raw_spec[separator + 1 ..] });
    }

    pub fn run(self: init_command, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        _ = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, command_name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(io, .START, command_name, "begin", .{ .path = if (self.positionals.len > 0) self.positionals[0] else "." });
        }

        const target_path = if (self.positionals.len > 0) self.positionals[0] else ".";

        var project_dir = if (std.mem.eql(u8, target_path, ".")) blk: {
            break :blk try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
        } else blk: {
            break :blk std.Io.Dir.cwd().createDirPathOpen(io, target_path, .{}) catch |err| {
                if (err == error.PathAlreadyExists) {
                    break :blk try std.Io.Dir.cwd().openDir(io, target_path, .{ .iterate = true });
                }
                return err;
            };
        };
        defer project_dir.close(io);

        const final_name = if (self.name) |n| try allocator.dupe(u8, n) else blk: {
            if (std.mem.eql(u8, target_path, ".")) {
                const path = std.process.currentPathAlloc(io, allocator) catch break :blk try allocator.dupe(u8, "unnamed-project");
                defer allocator.free(path);
                break :blk try allocator.dupe(u8, std.fs.path.basename(path));
            } else {
                break :blk try allocator.dupe(u8, std.fs.path.basename(target_path));
            }
        };
        defer allocator.free(final_name);

        // Check for global name collision in links
        {
            const paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
            defer { var mp = paths; mp.deinit(allocator); }
            
            try std.Io.Dir.cwd().createDirPath(io, paths.index);

            const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
            defer allocator.free(index_db_path);
            const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
            defer allocator.free(index_db_path_z);

            var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
            defer idx.deinit();
            const lr = moonstone.store.links.LinkStore.init(&idx);
            const found = try lr.get(final_name);
            if (found) |existing| {
                var mut_existing = existing;
                mut_existing.deinit(allocator);
                ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "project name '{s}' is already taken by a registered link.", .{final_name}) } };
                return error.NameAlreadyTaken;
            }
        }

        const pkg_kind = blk: {
            if (self.lib) break :blk Kind.lib;
            if (self.bin) break :blk Kind.bin;
            if (self.kind) |k| break :blk try Kind.from_string(k);
            if (self.template) |t| {
                if (std.mem.eql(u8, t, "lib")) break :blk Kind.lib;
                if (std.mem.eql(u8, t, "nvim")) break :blk Kind.lib;
                if (std.mem.eql(u8, t, "c-bin") or std.mem.eql(u8, t, "zig-bin") or std.mem.eql(u8, t, "rust-bin") or std.mem.eql(u8, t, "bin")) break :blk Kind.bin;
            }
            break :blk Kind.script;
        };

        const template = self.template orelse if (pkg_kind == .lib) "lib" else "script";
        const configured_runtime = if (self.runtime == null) try defaultRuntimeSpec(allocator, ctx.env, io) else null;
        defer if (configured_runtime) |spec| allocator.free(spec);
        const runtime_spec = self.runtime orelse configured_runtime orelse "5.4";
        const runtime_name = moonstone.domain.manifest.runtimeNameFromSpec(runtime_spec);
        const runtime_version = moonstone.domain.manifest.runtimeVersionFromSpec(runtime_spec);
        const runtime_abi = try moonstone.domain.manifest.inferRuntimeAbi(allocator, runtime_name, runtime_version);
        defer allocator.free(runtime_abi);
        const lua_ver = runtime_abi;

        const T = moonstone.assets.raw.templates;

        if (std.mem.eql(u8, template, "script")) {
            try project_dir.createDirPath(io, "src");
            if (project_dir.access(io, "src/main.lua", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "src/main.lua", .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.script_main);
            }
            if (project_dir.access(io, ".luarc.json", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, ".luarc.json", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.generic_luarc, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        } else if (std.mem.eql(u8, template, "lib")) {
            try project_dir.createDirPath(io, "src");
            const lib_file_name = try std.fmt.allocPrint(allocator, "src/{s}.lua", .{final_name});
            defer allocator.free(lib_file_name);
            if (project_dir.access(io, lib_file_name, .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, lib_file_name, .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.lib_lua, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
            if (project_dir.access(io, ".luarc.json", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, ".luarc.json", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.generic_luarc, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        }
 else if (std.mem.eql(u8, template, "nvim")) {
            const lua_path = try std.fmt.allocPrint(allocator, "lua/{s}", .{final_name});
            defer allocator.free(lua_path);
            try project_dir.createDirPath(io, lua_path);
            try project_dir.createDirPath(io, "plugin");

            const init_lua_path = try std.fmt.allocPrint(allocator, "lua/{s}/init.lua", .{final_name});
            defer allocator.free(init_lua_path);
            if (project_dir.access(io, init_lua_path, .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, init_lua_path, .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.nvim_init, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }

            const config_lua_path = try std.fmt.allocPrint(allocator, "lua/{s}/config.lua", .{final_name});
            defer allocator.free(config_lua_path);
            if (project_dir.access(io, config_lua_path, .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, config_lua_path, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.nvim_config);
            }

            const plugin_lua_path = try std.fmt.allocPrint(allocator, "plugin/{s}.lua", .{final_name});
            defer allocator.free(plugin_lua_path);
            if (project_dir.access(io, plugin_lua_path, .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, plugin_lua_path, .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.nvim_plugin, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }

            if (project_dir.access(io, ".luarc.json", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, ".luarc.json", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.nvim_luarc, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        } else if (std.mem.eql(u8, template, "love")) {
            if (project_dir.access(io, "main.lua", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "main.lua", .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.love_main);
            }
            if (project_dir.access(io, "conf.lua", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "conf.lua", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.love_conf, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
            if (project_dir.access(io, ".luarc.json", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, ".luarc.json", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.generic_luarc, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        }
 else if (std.mem.eql(u8, template, "c-bin")) {
            try project_dir.createDirPath(io, "src");
            if (project_dir.access(io, "src/main.c", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "src/main.c", .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.c_bin_main);
            }
            if (project_dir.access(io, "Makefile", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "Makefile", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.c_bin_makefile, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        } else if (std.mem.eql(u8, template, "zig-bin")) {
            try project_dir.createDirPath(io, "src");
            if (project_dir.access(io, "src/main.zig", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "src/main.zig", .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.zig_bin_main);
            }
            if (project_dir.access(io, "build.zig", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "build.zig", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.zig_bin_build, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        } else if (std.mem.eql(u8, template, "rust-bin")) {
            try project_dir.createDirPath(io, "src");
            if (project_dir.access(io, "src/main.rs", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "src/main.rs", .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.rust_bin_main);
            }
            if (project_dir.access(io, "Cargo.toml", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "Cargo.toml", .{});
                defer f.close(io);
                const content = try renderTemplate(allocator, T.rust_bin_cargo, final_name, lua_ver);
                defer allocator.free(content);
                try f.writeStreamingAll(io, content);
            }
        } else if (std.mem.eql(u8, template, "bin")) {
             try project_dir.createDirPath(io, "src");
             if (project_dir.access(io, "src/main.c", .{})) |_| {} else |_| {
                const f = try project_dir.createFile(io, "src/main.c", .{});
                defer f.close(io);
                try f.writeStreamingAll(io, T.bin_main);
            }
        }

        var pkg = MoonstoneToml.init(allocator);
        defer pkg.deinit(allocator);

        pkg.package = .{
            .name = try allocator.dupe(u8, final_name),
            .version = try allocator.dupe(u8, self.version orelse "0.1.0"),
            .kind = pkg_kind,
            .description = if (self.description) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, "A new Moonstone Lua project"),
        };
        
        pkg.runtime = .{
            .name = try allocator.dupe(u8, runtime_name),
            .version = try allocator.dupe(u8, runtime_version),
            .abi = try allocator.dupe(u8, runtime_abi),
        };

        if (std.mem.eql(u8, template, "script")) {
            try pkg.scripts.put(allocator, try allocator.dupe(u8, "dev"), try allocator.dupe(u8, "lua ./src/main.lua \"$@\""));
        }

        const toml_path = "moonstone.toml";
        if (project_dir.access(io, toml_path, .{})) |_| {
            ctx.error_detail = .{ .message = .{ .msg = "project already initialized (moonstone.toml exists)." } };
            return error.AlreadyInitialized;
        } else |_| {}

        const toml_file = try project_dir.createFile(io, toml_path, .{});
        defer toml_file.close(io);

        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try pkg.serialize(allocator, &aw.writer);
        try aw.writer.flush();
        try toml_file.writeStreamingAll(io, aw.writer.buffer[0..aw.writer.end]);

        if (emitter) |e| {
            try e.terminate(io, command_name, "ok", .{ .name = final_name, .path = target_path });
        } else {
            try stdout.print("Project '{s}' initialized successfully.\n", .{final_name});
        }

        // Initialize git repository
        if (!self.no_git) {
            const git_dir_path = try std.fs.path.join(allocator, &.{ target_path, ".git" });
            defer allocator.free(git_dir_path);

            if (std.Io.Dir.cwd().access(io, git_dir_path, .{})) |_| {
                // Git already initialized, skip
            } else |_| {
                if (emitter == null) try stdout.print("Initializing git repository...\n", .{});
                
                const git_res = try std.process.run(allocator, io, .{
                    .argv = &.{ "git", "init", target_path },
                });

                if (git_res.term != .exited or git_res.term.exited != 0) {
                    if (emitter == null) try stdout.print("Warning: git init failed.\n", .{});
                } else {
                    const gitignore_path = try std.fs.path.join(allocator, &.{ target_path, ".gitignore" });
                    defer allocator.free(gitignore_path);

                    if (std.Io.Dir.cwd().access(io, gitignore_path, .{})) |_| {
                        // gitignore exists, skip
                    } else |_| {
                        const gitignore_file = try std.Io.Dir.cwd().createFile(io, gitignore_path, .{});
                        defer gitignore_file.close(io);
                        try gitignore_file.writeStreamingAll(io, moonstone.assets.raw.gitignore);
                    }
                }
            }
        }
    }
};
