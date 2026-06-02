const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

fn packageNamesMatch(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right) or std.ascii.eqlIgnoreCase(left, right);
}

fn solutionContainsPackage(solution: *const std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact), name: []const u8) bool {
    for (solution.keys()) |candidate_name| {
        if (packageNamesMatch(candidate_name, name)) return true;
    }
    return false;
}

pub const add_command = struct {
    pub const name = "add";
    pub const description = "Add a dependency to the project";

    save_exact: bool = false,
    save_caret: bool = false,
    save_tilde: bool = false,
    dry_run: bool = false,
    json: bool = false,
    dev: bool = false,
    bin: bool = false,
    lib: bool = false,
    offline: bool = false,
    prefer_local: bool = false,
    no_sync: bool = false,
    positionals: []const []const u8 = &.{},

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon add [flags] <pkg>...
            \\
            \\Add a dependency to the project.
            \\
            \\Flags:
            \\  --dev            Add as a development dependency
            \\  --bin            Treat as a binary dependency
            \\  --lib            Treat as a library dependency
            \\  --save-exact     Save exact version (e.g. 1.2.3)
            \\  --save-caret     Save caret range (e.g. ^1.2.3, default)
            \\  --save-tilde     Save tilde range (e.g. ~1.2.3)
            \\  --dry-run        Show what would be added without modifying files
            \\  --offline        Do not access network
            \\  --prefer-local   Prefer local candidates over remote
            \\  --no-sync     Do not run sync after adding
            \\  --json           Output results as JSON
            \\
        , .{});
    }

    pub fn complete(args: []const []const u8, ctx: *router.Context) anyerror![]const []const u8 {
        _ = args;
        const allocator = ctx.allocator;
        const io = ctx.io;
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

        var list = std.ArrayList([]const u8).empty;

        // 1. Suggest links
        const lr = moonstone.store.links.LinkStore.init(&idx);
        const entries = try lr.list();
        defer {
            for (entries) |*e| e.deinit(allocator);
            allocator.free(entries);
        }
        for (entries) |entry| {
            try list.append(allocator, try std.fmt.allocPrint(allocator, "link:{s}", .{entry.name}));
        }

        // 2. Suggest known packages in artifacts
        const c = moonstone.store.driver.c;
        const sql = "SELECT DISTINCT name FROM artifacts;";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const name_val = std.mem.span(c.sqlite3_column_text(stmt, 0));
                try list.append(allocator, try allocator.dupe(u8, name_val));
            }
        }

        return list.toOwnedSlice(allocator);
    }

    pub fn run(self: add_command, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

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
            ctx.error_detail = .{ .message = .{ .msg = "moonstone.toml is missing [runtime]. Run `moon use lua@5.4` or `moon use luajit@2.1` to select one." } };
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
        defer { var p = paths; p.deinit(allocator); }

        const abs_index_dir = try std.fs.path.resolve(allocator, &.{paths.index});
        defer allocator.free(abs_index_dir);
        try std.Io.Dir.cwd().createDirPath(io, abs_index_dir);

        const index_db_path = try std.fs.path.join(allocator, &.{ abs_index_dir, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        const idx = try moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z);
        defer { var i = idx; i.deinit(); }

        const resolved_registries = try moonstone.registry.resolver.resolve(allocator, io, env);
        defer moonstone.registry.core.deinitResolved(resolved_registries, allocator);

        var resolve_cb_ctx = @import("command.zig").ResolveCallbackContext{
            .io = io,
            .stdout = stdout,
        };

        var resolver = moonstone.resolution.coordinator.Coordinator{ .allocator = allocator, .io = io };

        const rt_res = resolver.resolve(moonstone.domain.package_spec.canonicalOfficialRuntime(mt.runtimeName()), mt.runtimeConstraint(), idx, resolved_registries, .{
            .offline = self.offline,
            .prefer_local = true,
            .on_event = @import("command.zig").onResolveEvent,
            .on_event_context = &resolve_cb_ctx,
        }, env) catch |err| {
            if (err == error.NoCompatibleCandidateFound or err == error.PackageNotFound or err == error.FileNotFound) {
                ctx.error_detail = .{ .message = .{ .msg = "Moonstone requires an active Lua runtime for this command.\nPlease run `moon use lua@5.4` or `moon runtime install` first." } };
                return error.MissingRuntime;
            }
            return err;
        };
        var mut_rt_res = rt_res;
        defer mut_rt_res.deinit(allocator);

        const runtime_abi = mt.runtimeAbi();

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

        const lua_exe = try moonstone.resolution.sources.luarocks.find_runtime_lua_executable(allocator, io, mat.runtime_path.?);
        defer allocator.free(lua_exe);

        var targets = std.ArrayList(moonstone.resolution.solver.term.Term).empty;
        defer {
            for (targets.items) |t| {
                var mut_t = t;
                mut_t.deinit(allocator);
            }
            targets.deinit(allocator);
        }

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
            });
        }

        // Pass targets to provider for explicit registry filtering during resolution
        var provider_targets = std.ArrayList(moonstone.resolution.solver.term.Term).empty;
        for (targets.items) |t| {
            try provider_targets.append(allocator, .{
                .name = try allocator.dupe(u8, t.name),
                .range = try t.range.clone(allocator),
                .registry = if (t.registry) |r| try allocator.dupe(u8, r) else null,
                .resolver = t.resolver,
            });
        }
        const provider_targets_slice = try provider_targets.toOwnedSlice(allocator);

        // 1. Solve dependencies
        var provider_impl = try allocator.create(moonstone.resolution.provider.graph_provider.RegistryProvider);
        provider_impl.init(
            allocator, io, idx, resolved_registries, .{
                .offline = self.offline,
                .prefer_local = self.prefer_local,
                .runtime = runtime_abi,
                .runtime_path = mat.runtime_path,
            }, env, lua_exe, provider_targets_slice,
        );
        // Deinit moved to end of function

        var solver = moonstone.resolution.solver.pubgrub.Solver.init(allocator, provider_impl.get_provider(), .{});

        var solution = std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).empty;
        solution = solver.solve(targets.items) catch |err| blk: {
            if (err == error.ArtifactNotFound) break :blk std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).empty;
            if (err == error.NoSolution) break :blk std.StringArrayHashMapUnmanaged(moonstone.resolution.candidate.ResolvedArtifact).empty;
            if (err == error.LinkedRuntimeAbiMismatch) {
                if (provider_impl.linked_runtime_diagnostic) |diag| {
                    ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(allocator, "linked package {s}@{s} requires Lua ABI {s}, but the root project selected ABI {s}. Linked manifest: {s}", .{ diag.package_name, diag.package_version, diag.required_abi, diag.active_abi, diag.manifest_path }) } };
                }
            }
            return err;
        };
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
                    .on_event = @import("command.zig").onResolveEvent,
                    .on_event_context = &resolve_cb_ctx,
                }, kind, env) catch |err| {
                    if (err == error.RocksVersionDiscoveryFailed and parsed.resolver == null) continue;
                    if (err == error.PackageNotFound or err == error.FileNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
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
                            .on_event = @import("command.zig").onResolveEvent,
                            .on_event_context = &resolve_cb_ctx,
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
        var added_list = std.ArrayList([]const u8).empty;
        defer {
            for (added_list.items) |a| allocator.free(a);
            added_list.deinit(allocator);
        }

        // 2. Resolve and materialize all packages in the solution
        var sit = solution.iterator();
        while (sit.next()) |entry| {
            const pkg_name = entry.key_ptr.*;
            const resolved_art = entry.value_ptr.*;
            const v_str = resolved_art.version;

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
                resolved_opt = resolver.resolveWithKind(pkg_name, v_str, idx, resolved_registries, .{
                    .prefer_local = self.prefer_local,
                    .offline = self.offline,
                    .runtime = runtime_abi,
                    .runtime_path = mat.runtime_path,
                    .on_event = @import("command.zig").onResolveEvent,
                    .on_event_context = &resolve_cb_ctx,
                }, kind, env) catch |err| {
                    if (err == error.PackageNotFound or err == error.FileNotFound or err == error.ArtifactNotFound or err == error.RockspecNotFound or err == error.UnsupportedLuaRocksBuildType) continue;
                    return err;
                };
                if (resolved_opt != null) break;
            }

            if (resolved_opt == null) {
                if (!std.mem.eql(u8, pkg_name, "lua")) { 
                    if (emitter) |e| {
                        try e.emit(io, .WARN, pkg_name, "warn.could-not-resolve", .{ .version = v_str });
                    } else {
                        try stdout.print("Warning: could not resolve details for {s}@{s}\n", .{ pkg_name, v_str });
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
                const final_ver = if (explicit_prefix) |reg|
                    if (std.mem.eql(u8, reg, "path")) try allocator.dupe(u8, explicit_spec.?) else try std.fmt.allocPrint(allocator, "{s}:{s}@{s}{s}", .{ reg, pkg_name, range_prefix, resolved.version })
                else
                    try std.fmt.allocPrint(allocator, "{s}{s}", .{ range_prefix, resolved.version });
                defer allocator.free(final_ver);
                const effective_kind = blk: {
                    if (self.bin) break :blk moonstone.domain.manifest.Kind.bin;
                    if (self.lib) break :blk moonstone.domain.manifest.Kind.lib;
                    break :blk resolved.kind;
                };
                try mt.add_dependency(allocator, pkg_name, final_ver, self.dev, effective_kind);
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

            try lf.packages.append(allocator, .{
                .name = try allocator.dupe(u8, resolved.name),
                .version = try allocator.dupe(u8, resolved.version),
                .kind = resolved.kind,
                .source_hash = &.{},
                .recipe_hash = if (resolved.remote_desc) |rd| (
                    if (rd.artifact[resolved.artifact_idx.?].recipe_hash.len > 0) 
                        try allocator.dupe(u8, rd.artifact[resolved.artifact_idx.?].recipe_hash)
                    else 
                        try moonstone.store.facade.computeRecipeHash(allocator, .{
                            .kind = "prebuilt",
                            .name = resolved.name,
                            .version = resolved.version,
                            .strategy = "registry",
                            .target = "native",
                            .lua_abi = runtime_abi,
                        })
                ) else try moonstone.store.facade.computeRecipeHash(allocator, .{
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
                .resolver = try allocator.dupe(u8, if (resolved.registry_url != null) "moonstone" else "rocks"),
                .source = if (resolved.registry_url) |url| try allocator.dupe(u8, url) else &.{},
            });
        }

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
                    try stdout.print("Dry-run: would have added {d} packages and updated moonstone.lock.\n", .{ added_list.items.len });
                } else {
                    try stdout.print("Added {d} packages and updated moonstone.lock.\n", .{ added_list.items.len });
                }
            }
        } else if (emitter) |e| {
            try e.terminate(io, name, "ok", .{ .added = added_list.items, .dry_run = self.dry_run });
        }

        if (!self.no_sync and !self.dry_run) {
            if (!self.json) try stdout.print("Running sync...\n", .{});
            const sync = @import("sync.zig").sync_command{ .json = self.json };
            try sync.run(ctx);
        }
    }
};
