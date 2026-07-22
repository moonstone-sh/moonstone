const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const progress_runtime = @import("../progress.zig");
const profiler = moonstone.diagnostics.profiler;

fn packageNamesMatch(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right) or std.ascii.eqlIgnoreCase(left, right);
}

fn solutionContainsPackage(solution: *const std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact), name: []const u8) bool {
    for (solution.keys()) |candidate_name| {
        if (packageNamesMatch(candidate_name, name)) return true;
    }
    return false;
}

fn appendCompletionUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn appendCompletionIfMatches(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8, prefix: []const u8) !void {
    if (prefix.len > 0 and !std.mem.startsWith(u8, value, prefix)) return;
    try appendCompletionUnique(allocator, list, value);
}

fn appendCachedManifestCompletions(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, list: *std.ArrayList([]const u8), prefix: []const u8) void {
    const paths = moonstone.platform.fs.resolve_moonstone(allocator, env, io) catch return;
    defer {
        var p = paths;
        p.deinit(allocator);
    }
    const cfg = moonstone.cache.manifest.getConfig(allocator, env, io);
    var cache = moonstone.cache.manifest.ManifestCache.init(allocator, io, paths, cfg) catch return;
    defer cache.deinit();
    const entries = cache.list() catch return;
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    for (entries) |entry| {
        const payload = std.Io.Dir.cwd().readFileAlloc(io, entry.metadata.payload_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch continue;
        defer allocator.free(payload);
        switch (entry.metadata.source) {
            .luarocks => if (std.mem.startsWith(u8, prefix, "rocks:") or prefix.len == 0 or std.mem.startsWith(u8, "rocks:", prefix)) appendLuaRocksCompletions(allocator, payload, list, prefix) catch {},
            .registry => if (!std.mem.startsWith(u8, prefix, "rocks:")) appendRegistryCompletions(allocator, payload, list, prefix) catch {},
        }
    }
}

fn appendLuaRocksCompletions(allocator: std.mem.Allocator, payload: []const u8, list: *std.ArrayList([]const u8), prefix: []const u8) !void {
    const repo_key = std.mem.indexOf(u8, payload, "\"repository\"") orelse return;
    const open_rel = std.mem.indexOfScalar(u8, payload[repo_key..], '{') orelse return;
    var index = repo_key + open_rel + 1;
    var depth: usize = 1;
    while (index < payload.len and depth > 0) {
        const byte = payload[index];
        if (byte == '"' and depth == 1) {
            const start = index + 1;
            var end = start;
            var escaped = false;
            while (end < payload.len) : (end += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (payload[end] == '\\') {
                    escaped = true;
                    continue;
                }
                if (payload[end] == '"') break;
            }
            if (end >= payload.len) return;
            var colon = end + 1;
            while (colon < payload.len and std.ascii.isWhitespace(payload[colon])) : (colon += 1) {}
            if (colon < payload.len and payload[colon] == ':') {
                const package_name = payload[start..end];
                const suggestion = try std.fmt.allocPrint(allocator, "rocks:{s}", .{package_name});
                defer allocator.free(suggestion);
                try appendCompletionIfMatches(allocator, list, suggestion, prefix);
            }
            index = end + 1;
            continue;
        }
        if (byte == '"') {
            index += 1;
            var escaped = false;
            while (index < payload.len) : (index += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (payload[index] == '\\') {
                    escaped = true;
                    continue;
                }
                if (payload[index] == '"') break;
            }
        } else if (byte == '{') {
            depth += 1;
        } else if (byte == '}') {
            depth -= 1;
        }
        index += 1;
    }
}

fn appendRegistryCompletions(allocator: std.mem.Allocator, payload: []const u8, list: *std.ArrayList([]const u8), prefix: []const u8) !void {
    var idx = moonstone.domain.manifest.RemotePackageStoreIndex.parse(allocator, payload) catch return;
    defer idx.deinit(allocator);

    const is_moonstone_scheme = std.mem.startsWith(u8, prefix, "moonstone:");
    const query = if (is_moonstone_scheme) prefix["moonstone:".len..] else prefix;

    for (idx.package) |pkg| {
        if (is_moonstone_scheme) {
            if (query.len == 0 or std.mem.startsWith(u8, pkg.name, query)) {
                const suggestion = try std.fmt.allocPrint(allocator, "moonstone:{s}", .{pkg.name});
                defer allocator.free(suggestion);
                try appendCompletionUnique(allocator, list, suggestion);
            }
        } else {
            if (query.len == 0 or std.mem.startsWith(u8, pkg.name, query)) {
                try appendCompletionUnique(allocator, list, pkg.name);
            }
        }
    }
}

/// Command-specific data passed through WorkerContext.cmd_data.
const AddWorkData = struct {
    cmd: add_command,
    ctx: *router.Context,
    error_detail: ?@import("command.zig").CliErrorDetail = null,
};

/// Worker entry point: runs the add logic on a background thread,
/// sending progress events through the queue.
fn addWorker(wctx: *progress_runtime.WorkerContext) anyerror!void {
    const data: *AddWorkData = @ptrCast(@alignCast(wctx.cmd_data orelse return error.WorkerMissingData));
    data.cmd.runImpl(data.ctx, .{ .queue = wctx }) catch |err| {
        if (data.ctx.error_detail) |detail| {
            data.error_detail = detail;
            data.ctx.error_detail = null;
        }
        return err;
    };
}

pub const add_command = struct {
    pub const name = "add";
    pub const description = "Add a dependency to the project";

    save_exact: bool = false,
    save_caret: bool = false,
    save_tilde: bool = false,
    dry_run: bool = false,
    json: bool = false,
    role: ?[]const u8 = null,
    dev: bool = false,
    tool: bool = false,
    helper: bool = false,
    external: bool = false,
    optional: bool = false,
    bin: bool = false,
    lib: bool = false,
    offline: bool = false,
    prefer_local: bool = false,
    no_sync: bool = false,
    update: bool = false,
    global: bool = false,
    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon add [flags] <pkg>...
            \\
            \\Add a dependency to the project.
            \\
            \\Flags:
            \\  --role <role>    Set dependency role (dev, tool, runtime, helper, external, optional)
            \\  --external       Mark as host-provided external dependency
            \\  --dev            Alias for --role dev
            \\  --tool           Alias for --role tool
            \\  --helper         Alias for --role helper
            \\  --optional       Mark dependency as optional
            \\  --bin            Treat as a binary dependency
            \\  --lib            Treat as a library dependency
            \\  --save-exact     Save exact version (e.g. 1.2.3)
            \\  --save-caret     Save caret range (e.g. ^1.2.3, default)
            \\  --save-tilde     Save tilde range (e.g. ~1.2.3)
            \\  --dry-run        Show what would be added without modifying files
            \\  --offline        Do not access network
            \\  --prefer-local   Prefer local candidates over remote
            \\  --no-sync        Do not run sync after adding
            \\  --update         Re-resolve during the follow-up sync
            \\  --global         Add tool dependency to the global tools environment
            \\  --json           Output results as JSON
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const env = ctx.env;
        const prefix = if (args.len > 0) args[args.len - 1] else "";

        var list = std.ArrayList([]const u8).empty;

        // 1. Suggest scheme prefixes (moonstone:, rocks:, path:, link:) if prefix is empty or matches prefix start
        const scheme_prefixes = [_][]const u8{ "moonstone:", "rocks:", "path:", "link:" };
        for (scheme_prefixes) |scheme| {
            if (prefix.len == 0 or (prefix.len < scheme.len and std.mem.startsWith(u8, scheme, prefix))) {
                try appendCompletionUnique(allocator, &list, scheme);
            }
        }

        if (std.mem.startsWith(u8, prefix, "rocks:") or std.mem.startsWith(u8, prefix, "moonstone:")) {
            appendCachedManifestCompletions(allocator, io, env, &list, prefix);
            return list.toOwnedSlice(allocator);
        }

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        try std.Io.Dir.cwd().createDirPath(io, paths.index);

        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer idx.deinit();

        // 2. Suggest links
        const lr = moonstone.store.links.LinkStore.init(&idx);
        const entries = try lr.list();
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (entries) |entry| {
            const suggestion = try std.fmt.allocPrint(allocator, "link:{s}", .{entry.name});
            defer allocator.free(suggestion);
            try appendCompletionIfMatches(allocator, &list, suggestion, prefix);
        }

        // 3. Suggest known packages in artifacts
        const c = moonstone.store.driver.c;
        const sql = "SELECT DISTINCT name FROM artifacts;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const name_val = std.mem.span(c.sqlite3_column_text(stmt, 0));
                try appendCompletionIfMatches(allocator, &list, name_val, prefix);
            }
        }

        // 4. Suggest cached remote metadata.
        appendCachedManifestCompletions(allocator, io, env, &list, prefix);

        return list.toOwnedSlice(allocator);
    }

    pub fn run(self: add_command, ctx: *router.Context) !void {
        if (self.json) {
            return self.runImpl(ctx, .{ .direct = ctx.stdout });
        }

        if (ctx.env.get("CI") != null or ctx.env.get("MOONSTONE_NO_PROGRESS") != null) {
            return self.runImpl(ctx, .{ .direct = ctx.stderr });
        }

        var data = AddWorkData{ .cmd = self, .ctx = ctx };
        progress_runtime.runWithProgress(ctx.io, ctx.stderr, std.posix.STDERR_FILENO, ctx.allocator, ctx.env, addWorker, &data) catch |err| {
            if (data.error_detail) |detail| {
                ctx.error_detail = detail;
            }
            return err;
        };
    }

    pub fn runImpl(self: add_command, ctx: *router.Context, backend: progress_runtime.ProgressBackend) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;
        profiler.mark("add.begin");

        if (self.global) {
            var global_self = self;
            global_self.global = false;
            global_self.tool = true;
            global_self.role = "tool";

            const global_project = try @import("global_tools.zig").enterProject(allocator, env, io);
            defer @import("global_tools.zig").leaveProject(allocator, io, global_project);

            if (!self.json) try stdout.print("Using global tools environment: {s}\n", .{global_project.path});
            return try global_self.runImpl(ctx, backend);
        }

        const project_root = try moonstone.project.discovery.enterRoot(allocator, io, ".");
        defer project_root.deinit(allocator);

        var emitter_obj = if (self.json) @import("ndjson.zig").Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        const toml_path = "moonstone.toml";
        const lock_path = "moonstone.lock";

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{ .positionals = self.positionals, .dev = self.dev });
        }

        const toml_content = std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                return error.FileNotFound;
            }
            return err;
        };
        defer allocator.free(toml_content);

        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(allocator, toml_content);
        defer mt.deinit(allocator);

        if (mt.runtimeName().len == 0) {
            ctx.error_detail = .{ .message = .{ .msg = "moonstone.toml is missing [interpreter]. Run `moon interpreter set lua@5.4` or `moon interpreter set luajit@2.1` to select one." } };
            return error.MissingRuntime;
        }

        var lf = blk: {
            const lock_content = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
                if (err == error.FileNotFound) break :blk moonstone.domain.lockfile.LockFile.init(allocator);
                return err;
            };
            defer allocator.free(lock_content);
            break :blk try moonstone.domain.lockfile.LockFile.parse(allocator, lock_content);
        };
        defer lf.deinit();

        var mat = moonstone.materialization.materializer.Materializer{
            .allocator = allocator,
            .io = io,
            .environ_map = env,
        };

        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer {
            var p = paths;
            p.deinit(allocator);
        }

        const abs_index_dir = try std.fs.path.resolve(allocator, &.{paths.index});
        defer allocator.free(abs_index_dir);
        try std.Io.Dir.cwd().createDirPath(io, abs_index_dir);

        const index_db_path = try std.fs.path.join(allocator, &.{ abs_index_dir, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        const idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer {
            var i = idx;
            i.deinit();
        }

        if (!self.json) backend.phase("Reading registry configuration...", .{});
        var profile_span = profiler.now();
        const resolved_registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        profiler.span("add.registry.resolve", profile_span);
        defer moonstone.registry.core.deinitResolved(resolved_registries, allocator);

        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
            .emitter = emitter,
        };

        const on_resolve_cb: ?moonstone.resolution.options.ResolveCallback = switch (backend) {
            .direct => @import("command.zig").onResolveEvent,
            .queue => progress_runtime.onResolveEventProgress,
        };
        const on_resolve_ctx: ?*anyopaque = switch (backend) {
            .direct => @ptrCast(&resolve_cb_ctx),
            .queue => @ptrCast(backend.queue),
        };
        const on_solver_cb: ?moonstone.resolution.solver.report.SolverCallback = switch (backend) {
            .direct => @import("command.zig").onSolverEvent,
            .queue => progress_runtime.onSolverEventProgress,
        };
        const on_solver_ctx: ?*anyopaque = switch (backend) {
            .direct => @ptrCast(&resolve_cb_ctx),
            .queue => @ptrCast(backend.queue),
        };

        var resolver = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };

        const build_env = try mt.resolveBuildEnv(allocator, env);
        defer {
            for (build_env) |be| {
                allocator.free(be.key);
                allocator.free(be.value);
            }
            allocator.free(build_env);
        }

        if (!self.json) backend.phase("Resolving active runtime...", .{});
        profile_span = profiler.now();
        const rt_res = resolver.resolve(moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName()), mt.runtimeConstraint(), idx, resolved_registries, .{
            .offline = self.offline,
            .prefer_local = true,
            .on_event = on_resolve_cb,
            .on_event_context = on_resolve_ctx,
            .build_env = build_env,
        }, env) catch |err| {
            if (err == error.NoCompatibleCandidateFound or err == error.PackageNotFound or err == error.FileNotFound) {
                ctx.error_detail = .{ .message = .{ .msg = "Moonstone requires an active Lua runtime for this command.\nPlease run `moon interpreter set lua@5.4` or `moon interpreter set luajit@2.1` to select one." } };
                return error.MissingRuntime;
            }
            return err;
        };
        profiler.span("add.runtime.resolve", profile_span);
        var mut_rt_res = rt_res;
        defer mut_rt_res.deinit(allocator);

        const runtime_abi = mt.runtimeAbi();

        profile_span = profiler.now();
        if (mut_rt_res.local_path) |lp| {
            mat.runtime_path = lp;
        } else {
            const rt_res_mat = try mat.materialize_remote(
                mut_rt_res.registry_url.?,
                mut_rt_res.registry_token,
                mut_rt_res.descriptor_path.?,
                mut_rt_res.remote_desc.?,
                mut_rt_res.artifact_idx.?,
            );
            mat.runtime_path = rt_res_mat.path;
        }
        profiler.span("add.runtime.materialize", profile_span);

        // Find a proper Lua interpreter for rockspec parsing.
        // LÖVE and other engine runtimes do not provide bin/lua.
        profile_span = profiler.now();
        var tool_lua_prov = try moonstone.project.tool_lua.findToolLua(allocator, io, idx, runtime_abi, "rockspec-parse", ctx.env);
        defer tool_lua_prov.deinit(allocator);
        const lua_exe = try allocator.dupe(u8, tool_lua_prov.executable);
        profiler.span("add.tool_lua.find", profile_span);

        profile_span = profiler.now();
        var targets = std.ArrayList(moonstone.resolution.solver.term.Term).empty;
        defer {
            for (targets.items) |t| {
                var mut_t = t;
                mut_t.deinit(allocator);
            }
            targets.deinit(allocator);
        }

        const target_role: moonstone.domain.manifest.DependencyRole = blk: {
            if (self.role) |r| {
                if (std.mem.eql(u8, r, "dependency")) {
                    ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, "Role 'dependency' is no longer supported; use 'runtime'.") } };
                    return error.InvalidArgument;
                }
                break :blk moonstone.domain.manifest.DependencyRole.fromString(r) orelse {
                    ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "Unknown role '{s}'. Valid roles: dev, tool, runtime, helper, external, optional.", .{r}) } };
                    return error.InvalidArgument;
                };
            }
            if (self.dev) break :blk .dev;
            if (self.tool) break :blk .tool;
            if (self.helper) break :blk .helper;
            if (self.external) break :blk .external;
            if (self.optional) break :blk .optional;
            break :blk .runtime;
        };

        var missing_explicit = false;
        for (self.positionals) |pkg_spec| {
            const parsed = try moonstone.domain.package_spec.parsePackageSpec(allocator, pkg_spec);
            defer parsed.deinit(allocator);

            var path_candidate = if (parsed.resolver == .path)
                try moonstone.resolution.sources.path.resolve(allocator, io, parsed.name, "*", .{})
            else
                null;
            defer if (path_candidate) |*candidate| candidate.deinit(allocator);

            const range = try moonstone.domain.semver.VersionRange.parse(allocator, parsed.constraint orelse "*");
            errdefer range.deinit(allocator);

            try targets.append(allocator, .{
                .name = try allocator.dupe(u8, if (path_candidate) |candidate| candidate.name else parsed.name),
                .range = range,
                .registry = if (parsed.registry) |r| try allocator.dupe(u8, r) else if (parsed.resolver == .path) try allocator.dupe(u8, parsed.name) else null,
                .resolver = parsed.resolver,
                .role = target_role,
            });
        }
        profiler.spanCount("add.targets.build", profile_span, "targets", targets.items.len);

        // Pass targets to provider for explicit registry filtering during resolution
        var provider_targets = std.ArrayList(moonstone.resolution.solver.term.Term).empty;
        for (targets.items) |t| {
            try provider_targets.append(allocator, .{
                .name = try allocator.dupe(u8, t.name),
                .range = try t.range.clone(allocator),
                .registry = if (t.registry) |r| try allocator.dupe(u8, r) else null,
                .resolver = t.resolver,
                .role = t.role,
            });
        }
        const provider_targets_slice = try provider_targets.toOwnedSlice(allocator);

        // 1. Solve dependencies
        profile_span = profiler.now();
        var provider_impl = try allocator.create(moonstone.resolution.provider.graph_provider.RegistryProvider);
        provider_impl.init(
            allocator,
            io,
            idx,
            resolved_registries,
            .{
                .offline = self.offline,
                .prefer_local = self.prefer_local or !self.update,
                .runtime = runtime_abi,
                .runtime_path = mat.runtime_path,
                .on_event = on_resolve_cb,
                .on_event_context = on_resolve_ctx,
                .build_env = build_env,
            },
            env,
            lua_exe,
            provider_targets_slice,
        );
        profiler.spanCount("add.provider.plan", profile_span, "targets", targets.items.len);
        // Deinit moved to end of function

        if (!self.json) backend.phase("Solving requested dependencies...", .{});
        var solver = moonstone.resolution.solver.pubgrub.Solver.init(allocator, provider_impl.get_provider(), .{
            .on_event = on_solver_cb,
            .on_event_context = on_solver_ctx,
        });

        var solution = std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).empty;
        profile_span = profiler.now();
        solution = solver.solve(targets.items) catch |err| blk: {
            if (err == error.ArtifactNotFound) break :blk std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).empty;
            if (err == error.NoSolution) {
                if (solver.last_conflict) |inc| {
                    var aw = std.Io.Writer.Allocating.init(allocator);
                    defer aw.deinit();
                    try moonstone.resolution.solver.report.explain(&aw.writer, inc, allocator);
                    ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]) } };
                } else {
                    ctx.error_detail = .{ .message = .{ .msg = try allocator.dupe(u8, "No compatible resolution could be found.") } };
                }
                return err;
            }
            if (err == error.LinkedRuntimeAbiMismatch) {
                if (provider_impl.linked_runtime_diagnostic) |diag| {
                    if (diag.suggested_role) |sr| {
                        ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}\nIf this is a development CLI tool, add it with --{s} instead.", .{ diag.package_name, diag.package_version, diag.required_abi, diag.active_abi, diag.manifest_path, sr }) } };
                    } else {
                        ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}", .{ diag.package_name, diag.package_version, diag.required_abi, diag.active_abi, diag.manifest_path }) } };
                    }
                }
            }
            return err;
        };
        profiler.spanCount("add.pubgrub.solve", profile_span, "packages", solution.count());
        defer {
            var sit = solution.iterator();
            while (sit.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit(allocator);
            }
            solution.deinit(allocator);
            solver.deinit();
            provider_impl.deinit();
            allocator.destroy(provider_impl);
        }

        for (self.positionals) |pkg_spec| {
            const parsed = try moonstone.domain.package_spec.parsePackageSpec(allocator, pkg_spec);
            defer parsed.deinit(allocator);

            if (solutionContainsPackage(&solution, parsed.name)) continue;
            var direct_kinds_buf: [4]moonstone.resolution.coordinator.CoordinatorKind = undefined;
            var direct_kinds_len: usize = 0;
            if (parsed.resolver) |resolver_kind| {
                direct_kinds_buf[direct_kinds_len] = resolver_kind;
                direct_kinds_len += 1;
            } else {
                const default_order = if (mt.resolution) |r| r.default_order else @as([]const []const u8, &[_][]const u8{ "moonstone", "rocks" });
                for (default_order) |r_name| {
                    if (moonstone.resolution.coordinator.CoordinatorKind.fromString(r_name)) |kind| {
                        direct_kinds_buf[direct_kinds_len] = kind;
                        direct_kinds_len += 1;
                    } else |_| continue;
                }
            }

            var resolved_direct_opt: ?moonstone.resolution.candidate.ResolvedArtifact = null;
            for (direct_kinds_buf[0..direct_kinds_len]) |kind| {
                resolved_direct_opt = resolver.resolveWithKind(parsed.name, parsed.constraint orelse "*", idx, resolved_registries, .{
                    .prefer_local = self.prefer_local,
                    .offline = self.offline,
                    .runtime = runtime_abi,
                    .runtime_artifact_hash = mut_rt_res.artifact_hash,
                    .runtime_path = mat.runtime_path,
                    .on_event = on_resolve_cb,
                    .on_event_context = on_resolve_ctx,
                    .build_env = build_env,
                }, kind, env) catch |err| {
                    if (err == error.RocksVersionDiscoveryFailed and parsed.resolver == null) continue;
                    if (err == error.PackageNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
                    return err;
                };
                if (resolved_direct_opt != null) break;
            }
            if (resolved_direct_opt == null) {
                if (parsed.registry) |registry_name| {
                    for (resolved_registries) |reg| {
                        if (!std.mem.eql(u8, reg.name, registry_name)) continue;
                        const remote = resolver.resolve_remote(parsed.name, parsed.constraint orelse "*", reg.url, reg.token, .{
                            .prefer_local = self.prefer_local,
                            .offline = self.offline,
                            .runtime = runtime_abi,
                            .runtime_path = mat.runtime_path,
                            .on_event = on_resolve_cb,
                            .on_event_context = on_resolve_ctx,
                            .build_env = build_env,
                        }, env) catch continue;
                        resolved_direct_opt = .{
                            .name = try allocator.dupe(u8, parsed.name),
                            .version = try allocator.dupe(u8, remote.desc.package.version),
                            .kind = remote.desc.package.kind,
                            .artifact_hash = try allocator.dupe(u8, remote.desc.artifact[remote.artifact_idx].hash),
                            .lua_abi = try allocator.dupe(u8, remote.desc.artifact[remote.artifact_idx].lua_abi),
                            .remote_desc = remote.desc,
                            .registry_url = try allocator.dupe(u8, reg.url),
                            .registry_token = if (reg.token) |t| try allocator.dupe(u8, t) else null,
                            .descriptor_path = remote.descriptor_path,
                            .artifact_idx = remote.artifact_idx,
                            .origin = .{ .moonstone_registry = .{
                                .url = try allocator.dupe(u8, reg.url),
                                .token = if (reg.token) |t| try allocator.dupe(u8, t) else null,
                                .descriptor_path = try allocator.dupe(u8, remote.descriptor_path),
                                .artifact_idx = remote.artifact_idx,
                            } },
                        };
                        break;
                    }
                }
            }
            var resolved_direct = resolved_direct_opt orelse {
                missing_explicit = true;
                continue;
            };
            errdefer resolved_direct.deinit(allocator);

            if (solution.contains(resolved_direct.name)) {
                resolved_direct.deinit(allocator);
                continue;
            }
            try solution.put(allocator, try allocator.dupe(u8, resolved_direct.name), resolved_direct);
        }
        if (missing_explicit) return error.PackageNotFound;
        if (self.positionals.len > 0 and solution.count() == 0) return error.PackageNotFound;
        if (!self.json) backend.phaseDone("Resolved {d} dependencies.", .{solution.count()});
        var added_list = std.ArrayList([]const u8).empty;
        defer {
            for (added_list.items) |a| allocator.free(a);
            added_list.deinit(allocator);
        }

        // 2. Resolve and materialize all packages in the solution
        profile_span = profiler.now();
        var sit = solution.iterator();
        var materialize_index: usize = 0;
        const materialize_total = solution.count();
        while (sit.next()) |entry| {
            materialize_index += 1;
            const pkg_name = entry.key_ptr.*;
            const resolved_art = entry.value_ptr.*;
            const v_str = resolved_art.version;

            if (!self.json) backend.status("add-materialize", "Materializing [{d}/{d}] {s}@{s}...", .{
                materialize_index,
                materialize_total,
                pkg_name,
                v_str,
            });

            // Find if this was an explicit positional
            var is_explicit = false;
            var explicit_prefix: ?[]const u8 = null;
            var explicit_spec: ?[]const u8 = null;
            for (self.positionals) |pkg_spec| {
                const parsed = try moonstone.domain.package_spec.parsePackageSpec(allocator, pkg_spec);
                defer parsed.deinit(allocator);
                var path_candidate = if (parsed.resolver == .path)
                    try moonstone.resolution.sources.path.resolve(allocator, io, parsed.name, "*", .{})
                else
                    null;
                defer if (path_candidate) |*candidate| candidate.deinit(allocator);
                const parsed_name = if (path_candidate) |candidate| candidate.name else parsed.name;
                if (packageNamesMatch(parsed_name, pkg_name)) {
                    is_explicit = true;
                    explicit_spec = try allocator.dupe(u8, pkg_spec);
                    if (parsed.registry) |r| {
                        explicit_prefix = try allocator.dupe(u8, r);
                    } else if (parsed.resolver) |r| {
                        explicit_prefix = try allocator.dupe(u8, r.asString());
                    }
                    break;
                }
            }
            defer if (explicit_prefix) |r| allocator.free(r);
            defer if (explicit_spec) |spec| allocator.free(spec);

            // Determine resolver order
            var kinds_buf: [4]moonstone.resolution.coordinator.CoordinatorKind = undefined;
            var kinds_len: usize = 0;

            if (explicit_prefix) |ep| {
                if (moonstone.resolution.coordinator.CoordinatorKind.fromString(ep)) |kind| {
                    kinds_buf[kinds_len] = kind;
                    kinds_len += 1;
                } else |_| {}
            }

            if (kinds_len == 0) {
                switch (resolved_art.origin) {
                    .moonstone_registry => {
                        kinds_buf[kinds_len] = .moonstone;
                        kinds_len += 1;
                    },
                    .luarocks => {
                        kinds_buf[kinds_len] = .rocks;
                        kinds_len += 1;
                    },
                    .path => {
                        kinds_buf[kinds_len] = .path;
                        kinds_len += 1;
                    },
                    .link => {
                        kinds_buf[kinds_len] = .link;
                        kinds_len += 1;
                    },
                    .artifact_hash => {},
                }
            }

            if (kinds_len == 0) {
                const default_order = if (mt.resolution) |r| r.default_order else @as([]const []const u8, &[_][]const u8{ "moonstone", "rocks" });
                for (default_order) |r_name| {
                    if (moonstone.resolution.coordinator.CoordinatorKind.fromString(r_name)) |kind| {
                        kinds_buf[kinds_len] = kind;
                        kinds_len += 1;
                    } else |_| continue;
                }
            }
            const order = kinds_buf[0..kinds_len];

            var resolved_opt: ?moonstone.resolution.candidate.ResolvedArtifact = null;
            for (order) |kind| {
                const resolve_name = if (kind == .path) switch (resolved_art.origin) {
                    .path => |p| p,
                    else => pkg_name,
                } else pkg_name;
                resolved_opt = resolver.resolveWithKind(resolve_name, v_str, idx, resolved_registries, .{
                    .prefer_local = self.prefer_local,
                    .offline = self.offline,
                    .runtime = runtime_abi,
                    .runtime_path = mat.runtime_path,
                    .on_event = on_resolve_cb,
                    .on_event_context = on_resolve_ctx,
                }, kind, env) catch |err| {
                    if (err == error.PackageNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
                    return err;
                };
                if (resolved_opt != null) break;
            }

            if (resolved_opt == null) {
                if (!std.mem.eql(u8, pkg_name, "lua")) {
                    if (emitter) |e| {
                        try e.emit(io, .WARN, pkg_name, "warn.could-not-resolve", .{ .version = v_str });
                    } else {
                        try stdout.print("Warning: could not resolve details for {s}@{s}", .{ pkg_name, v_str });
                    }
                }
                continue;
            }
            var resolved = resolved_opt.?;
            defer resolved.deinit(allocator);

            // Materialize only if needed
            const mat_res = if (resolved.local_path) |p| moonstone.materialization.materializer.MaterializeResult{
                .path = try allocator.dupe(u8, p),
                .artifact_hash = try allocator.dupe(u8, resolved.artifact_hash),
            } else try mat.materialize_remote(
                resolved.registry_url.?,
                resolved.registry_token,
                resolved.descriptor_path.?,
                resolved.remote_desc.?,
                resolved.artifact_idx.?,
            );
            defer mat_res.deinit(allocator);

            // Update manifest for explicit dependencies
            if (is_explicit) {
                const range_prefix = blk: {
                    if (self.save_exact) break :blk "";
                    if (self.save_tilde) break :blk "~";
                    break :blk "^";
                };
                // Store the dependency as a [[dependencies]] entry with explicit
                // resolver and constraint fields.  The constraint is always just
                // the version (e.g. "^1.3.2-1"), never the full spec.
                const final_ver = try std.fmt.allocPrint(allocator, "{s}{s}", .{ range_prefix, resolved.version });
                defer allocator.free(final_ver);
                const effective_kind = blk: {
                    if (self.bin) break :blk moonstone.domain.manifest.Kind.bin;
                    if (self.lib) break :blk moonstone.domain.manifest.Kind.lib;
                    break :blk resolved.kind;
                };
                _ = effective_kind;
                // For path dependencies, the "version" is the original spec
                // (e.g. "path:../my-lib") since path deps don't have semver.
                const dep_resolver: ?[]const u8 = explicit_prefix;
                const dep_constraint = if (explicit_prefix) |reg|
                    if (std.mem.eql(u8, reg, "path")) (explicit_spec orelse final_ver) else final_ver
                else if (resolved.version.len == 0 or std.mem.eql(u8, resolved.version, "0.0.0")) blk: {
                    if (explicit_spec) |spec| break :blk spec;
                    break :blk "*";
                } else final_ver;
                try mt.add_dependency_with_resolver(allocator, pkg_name, dep_constraint, target_role, self.optional, dep_resolver);
                _ = effective_kind;
                try added_list.append(allocator, try allocator.dupe(u8, pkg_name));
            }

            // Update moonstone.lock
            var j: usize = 0;
            while (j < lf.packages.items.len) {
                if (std.mem.eql(u8, lf.packages.items[j].name, resolved.name)) {
                    const old = lf.packages.swapRemove(j);
                    old.deinit(allocator);
                } else {
                    j += 1;
                }
            }

            var store_prov_opt = @import("lock_provenance.zig").read(allocator, io, mat_res.path) catch null;
            defer if (store_prov_opt) |*store_prov| store_prov.deinit(allocator);
            const store_source_hash = if (store_prov_opt) |store_prov| store_prov.source_hash else "";
            const store_recipe_hash = if (store_prov_opt) |store_prov| store_prov.recipe_hash else "";
            const store_source = if (store_prov_opt) |store_prov| store_prov.source else "";
            const store_source_kind = if (store_prov_opt) |store_prov| store_prov.source_kind else "";
            const store_source_payload = if (store_prov_opt) |store_prov| store_prov.source_payload else "";
            const store_rockspec = if (store_prov_opt) |store_prov| store_prov.rockspec else "";
            const store_rockspec_hash = if (store_prov_opt) |store_prov| store_prov.rockspec_hash else "";
            const store_rockspec_payload = if (store_prov_opt) |store_prov| store_prov.rockspec_payload else "";

            try lf.packages.append(allocator, .{
                .name = try allocator.dupe(u8, resolved.name),
                .version = try allocator.dupe(u8, resolved.version),
                .kind = resolved.kind,
                .source_hash = if (store_source_hash.len > 0) try allocator.dupe(u8, store_source_hash) else if (resolved.source_hash.len > 0) try allocator.dupe(u8, resolved.source_hash) else &.{},
                .recipe_hash = if (store_recipe_hash.len > 0) try allocator.dupe(u8, store_recipe_hash) else if (resolved.recipe_hash.len > 0) try allocator.dupe(u8, resolved.recipe_hash) else if (resolved.remote_desc) |rd| (if (rd.artifact[resolved.artifact_idx.?].recipe_hash.len > 0)
                    try allocator.dupe(u8, rd.artifact[resolved.artifact_idx.?].recipe_hash)
                else
                    try moonstone.store.facade.computeRecipeHash(allocator, .{
                        .kind = "prebuilt",
                        .name = resolved.name,
                        .version = resolved.version,
                        .strategy = "registry",
                        .target = "native",
                        .lua_abi = runtime_abi,
                    })) else try moonstone.store.facade.computeRecipeHash(allocator, .{
                    .kind = "prebuilt",
                    .name = resolved.name,
                    .version = resolved.version,
                    .strategy = "registry",
                    .target = "native",
                    .lua_abi = runtime_abi,
                }),
                .artifact_hash = try allocator.dupe(u8, mat_res.artifact_hash),
                .runtime = try allocator.dupe(u8, runtime_abi),
                .lua_abi = try allocator.dupe(u8, runtime_abi),
                .target = try allocator.dupe(u8, "native"),
                .constellation = try allocator.dupe(u8, "default"),
                .resolver = try allocator.dupe(u8, switch (resolved.origin) {
                    .moonstone_registry => "moonstone",
                    .luarocks => "rocks",
                    .link => "link",
                    .path => "path",
                    .artifact_hash => "store",
                }),
                .source = if (store_source.len > 0) try allocator.dupe(u8, store_source) else switch (resolved.origin) {
                    .moonstone_registry => if (resolved.source.len > 0) try allocator.dupe(u8, resolved.source) else if (resolved.registry_url) |url| try allocator.dupe(u8, url) else &.{},
                    .luarocks => |r| try allocator.dupe(u8, r.url),
                    .link => |p| try allocator.dupe(u8, p),
                    .path => |p| try allocator.dupe(u8, p),
                    .artifact_hash => &.{},
                },
                .source_kind = if (store_source_kind.len > 0) try allocator.dupe(u8, store_source_kind) else &.{},
                .source_payload = if (store_source_payload.len > 0) try allocator.dupe(u8, store_source_payload) else &.{},
                .rockspec = if (store_rockspec.len > 0) try allocator.dupe(u8, store_rockspec) else if (resolved.rockspec.len > 0) try allocator.dupe(u8, resolved.rockspec) else &.{},
                .rockspec_hash = if (store_rockspec_hash.len > 0) try allocator.dupe(u8, store_rockspec_hash) else if (resolved.rockspec_hash.len > 0) try allocator.dupe(u8, resolved.rockspec_hash) else &.{},
                .rockspec_payload = if (store_rockspec_payload.len > 0) try allocator.dupe(u8, store_rockspec_payload) else &.{},
                .replay_mode = blk: {
                    const sk = if (store_source_kind.len > 0) store_source_kind else "";
                    if (std.mem.eql(u8, sk, "zig_cc") or std.mem.eql(u8, sk, "cmake") or std.mem.eql(u8, sk, "native_cmodule")) {
                        break :blk moonstone.domain.replay_contract.ReplayMode.declared_host;
                    }
                    if (moonstone.resolution.locked_realizer.assessMaterializerCapability(sk) == .source_replay_supported) {
                        break :blk moonstone.domain.replay_contract.ReplayMode.portable_source;
                    }
                    break :blk moonstone.domain.replay_contract.ReplayMode.artifact_only;
                },
            });
        }
        profiler.spanCount("add.materialize", profile_span, "packages", solution.count());

        // Write moonstone.toml
        if (!self.dry_run) {
            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try mt.serialize(allocator, &aw.writer);

            const toml_file = try std.Io.Dir.cwd().createFile(io, toml_path, .{});
            defer toml_file.close(io);
            try toml_file.writeStreamingAll(io, aw.written());
        }

        // Write moonstone.lock
        if (!self.dry_run) {
            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try lf.serialize(allocator, &aw.writer);

            const lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{});
            defer lock_file.close(io);
            try lock_file.writeStreamingAll(io, aw.written());
        }

        if (added_list.items.len > 0) {
            if (emitter) |e| {
                try e.terminate(io, name, "ok", .{ .added = added_list.items, .dry_run = self.dry_run });
            } else {
                if (self.dry_run) {
                    try stdout.print("Dry-run: would have added {d} packages and updated moonstone.lock.\n", .{added_list.items.len});
                } else {
                    try stdout.print("Added {d} packages and updated moonstone.lock.\n", .{added_list.items.len});
                }
            }
        } else if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .added = added_list.items, .dry_run = self.dry_run });
        }

        if (!self.no_sync and !self.dry_run) {
            if (!self.json) backend.phase("Running sync...", .{});

            const sync = @import("sync.zig").sync_command{
                .json = self.json,
                .update = self.update,
            };

            try sync.runImpl(ctx, backend);
        }
    }
};
