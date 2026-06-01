const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const DoctorCommand = struct {
    pub const name = "doctor";
    pub const description = "Check the health of your Moonstone installation";

    json: bool = false,
    fix: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon doctor [flags]
            \\
            \\Check the health of your Moonstone installation and project.
            \\
            \\Flags:
            \\  --json    Output results as JSON (bloated protocol per docs/generic_message_types.md)
            \\  --fix     Attempt to fix common issues automatically
            \\
        , .{});
    }

    const CheckName = enum {
        store_directory,
        sqlite_index,
        link_registry,
        global_shims,
        network_connectivity,
        default_runtime,
        env_vars,
        project_root,
        manifest,
        lockfile_artifacts,
        lockfile_sync,
        env_symlinks,
        link_targets,
        system_tools,
    };

    const CheckResult = struct {
        passed: bool,
        name: CheckName,
        message: []const u8,
        fixed: bool = false,
    };

    pub fn run(self: DoctorCommand, ctx: *router.Context) !void {
        const allocator = ctx.allocator;
        const io = ctx.io;
        const stdout = ctx.stdout;
        const env = ctx.env;

        var emitter_obj = if (self.json) ndjson.Emitter.init(allocator, stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        var results = std.ArrayList(CheckResult).empty;
        defer {
            for (results.items) |r| allocator.free(r.message);
            results.deinit(allocator);
        }

        if (emitter) |e| {
            try e.emit(io, .START, name, "begin", .{});
        } else {
            try stdout.print(
                \\Moonstone Doctor - Health Check
                \\-------------------------------
                \\
            , .{});
        }

        // ── 1. Store directory ────────────────────────────────────────────
        const paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
        defer { var p = paths; p.deinit(allocator); }

        var store_ok = true;
        var store_msg: []const u8 = "";
        std.Io.Dir.cwd().access(io, paths.store, .{ .read = true, .write = true }) catch |err| {
            store_ok = false;
            store_msg = try std.fmt.allocPrint(allocator, "FAIL: {s} (at {s})", .{ @errorName(err), paths.store });

            if (self.fix) {
                std.Io.Dir.cwd().createDirPath(io, paths.store) catch {};
                // Re-check
                if (std.Io.Dir.cwd().access(io, paths.store, .{ .read = true, .write = true })) |_| {
                    store_ok = true;
                    allocator.free(store_msg);
                    store_msg = try std.fmt.allocPrint(allocator, "FIXED: recreated store directory at {s}", .{paths.store});
                } else |_| {}
            }
        };
        if (store_ok and store_msg.len == 0) {
            store_msg = try std.fmt.allocPrint(allocator, "OK", .{});
        }
        try results.append(allocator, .{ .passed = store_ok, .name = .store_directory, .message = store_msg, .fixed = store_ok and self.fix });
        try self.reportCheck(emitter, io, stdout, "store_directory", store_ok, store_msg);

        // ── 2. SQLite index ─────────────────────────────────────────────
        const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(index_db_path);
        const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
        defer allocator.free(index_db_path_z);

        var idx_res: ?moonstone.store.driver.StoreDriver = moonstone.store.driver.StoreDriver.init(allocator, index_db_path_z) catch null;
        const idx_ok = (idx_res != null);
        const idx_msg = if (idx_ok) try std.fmt.allocPrint(allocator, "OK", .{}) else try std.fmt.allocPrint(allocator, "FAIL: could not open index", .{});
        try results.append(allocator, .{ .passed = idx_ok, .name = .sqlite_index, .message = idx_msg, .fixed = false });
        try self.reportCheck(emitter, io, stdout, "sqlite_index", idx_ok, idx_msg);

        // ── 3. Link registry ─────────────────────────────────────────────
        var links_ok = true;
        var links_msg: []const u8 = "";
        if (idx_res) |idx| {
            const lr = moonstone.store.links.LinkStore.init(@constCast(&idx));
            if (lr.list()) |entries| {
                defer {
                    for (entries) |*e| e.deinit(allocator);
                    allocator.free(entries);
                }
                var missing_targets: usize = 0;
                for (entries) |entry| {
                    std.Io.Dir.cwd().access(io, entry.path, .{}) catch {
                        missing_targets += 1;
                    };
                }
                if (missing_targets > 0) {
                    links_ok = false;
                    const ci = env.get("CI") orelse "";
                    const prefix = if (std.mem.eql(u8, ci, "true") or std.mem.eql(u8, ci, "1")) "FAIL" else "WARN";
                    links_msg = try std.fmt.allocPrint(allocator, "{s}: {d} registered link target(s) are missing.", .{ prefix, missing_targets });
                } else {
                    links_msg = try std.fmt.allocPrint(allocator, "OK ({d} links registered)", .{entries.len});
                }
            } else |err| {
                links_ok = false;
                links_msg = try std.fmt.allocPrint(allocator, "FAIL: could not list links: {s}", .{@errorName(err)});
            }
        } else {
            links_ok = false;
            links_msg = try std.fmt.allocPrint(allocator, "FAIL: index not available", .{});
        }
        try results.append(allocator, .{ .passed = links_ok, .name = .link_registry, .message = links_msg, .fixed = false });
        try self.reportCheck(emitter, io, stdout, "link_registry", links_ok, links_msg);

        // ── 4. Global shims ──────────────────────────────────────────────
        var shims_ok = true;
        var shims_msg: []const u8 = "";
        const shim_dir = paths.shims;
        const tools = [_][]const u8{ "lua", "luac" };
        var missing_shims = std.ArrayList([]const u8).empty;
        defer missing_shims.deinit(allocator);

        for (tools) |tool| {
            var s_dir = std.Io.Dir.cwd().openDir(io, shim_dir, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    try missing_shims.append(allocator, tool);
                    continue;
                }
                return err;
            };
            defer s_dir.close(io);

            s_dir.access(io, tool, .{}) catch {
                try missing_shims.append(allocator, tool);
            };
        }

        if (missing_shims.items.len > 0) {
            shims_ok = false;
            var list_buf = std.ArrayList(u8).empty;
            defer list_buf.deinit(allocator);
            for (missing_shims.items, 0..) |s, i| {
                if (i > 0) try list_buf.appendSlice(allocator, ", ");
                try list_buf.appendSlice(allocator, s);
            }
            shims_msg = try std.fmt.allocPrint(allocator, "WARN: Missing shims for: {s}. Run 'moon setup'.", .{list_buf.items});

            if (self.fix) {
                const setup = @import("setup.zig").SetupCommand{ .json = self.json };
                setup.run(ctx) catch {};
                // Re-check (simple check for directory existence for now)
                if (std.Io.Dir.cwd().access(io, shim_dir, .{})) |_| {
                    shims_ok = true;
                    allocator.free(shims_msg);
                    shims_msg = try std.fmt.allocPrint(allocator, "FIXED: shims created at {s}", .{shim_dir});
                } else |_| {}
            }
        } else {
            // Check if shim_dir is in PATH
            const path_env = env.get("PATH") orelse "";
            if (std.mem.indexOf(u8, path_env, shim_dir) == null) {
                shims_msg = try std.fmt.allocPrint(allocator, "WARN: Shim directory {s} not in PATH.", .{shim_dir});
            } else {
                shims_msg = try std.fmt.allocPrint(allocator, "OK", .{});
            }
        }
        try results.append(allocator, .{ .passed = shims_ok, .name = .global_shims, .message = shims_msg, .fixed = self.fix and shims_ok and missing_shims.items.len > 0 });
        try self.reportCheck(emitter, io, stdout, "global_shims", shims_ok, shims_msg);

        // ── 5. Network connectivity ───────────────────────────────────────
        var net_ok = true;
        var net_msg: []const u8 = "";
        const test_url = "https://luarocks.org";
        const http_cfg = moonstone.platform.http.get_http_config(allocator, env, io);

        if (moonstone.platform.http.fetchGet(allocator, io, test_url, null, http_cfg.timeout_ms)) |resp| {
            defer allocator.free(resp.body);
            if (resp.status == .ok) {
                net_msg = try std.fmt.allocPrint(allocator, "OK", .{});
            } else {
                net_ok = false;
                const status_num = @intFromEnum(resp.status);
                if (status_num >= 400 and status_num < 500) {
                    net_msg = try std.fmt.allocPrint(allocator, "WARN: Network reachable but registry returned {d}", .{status_num});
                } else if (status_num >= 500 and status_num < 600) {
                    net_msg = try std.fmt.allocPrint(allocator, "WARN: Network reachable but server returned {d}", .{status_num});
                } else {
                    net_msg = try std.fmt.allocPrint(allocator, "WARN: Network reachable but got unexpected status {d}", .{status_num});
                }
            }
        } else |err| {
            net_ok = false;
            net_msg = try std.fmt.allocPrint(allocator, "WARN: Network failed before HTTP response: {s}", .{@errorName(err)});
        }
        try results.append(allocator, .{ .passed = net_ok, .name = .network_connectivity, .message = net_msg, .fixed = false });
        try self.reportCheck(emitter, io, stdout, "network_connectivity", net_ok, net_msg);

        // ── 6. Default runtime ───────────────────────────────────────────
        var rt_ok = true;
        var rt_msg: []const u8 = "";
        const config_toml_path = try std.fs.path.join(allocator, &.{ paths.config, "config.toml" });
        defer allocator.free(config_toml_path);

        if (std.Io.Dir.cwd().readFileAlloc(io, config_toml_path, allocator, std.Io.Limit.limited(1024 * 1024))) |cfg_content| {
            defer allocator.free(cfg_content);
            var parser = moonstone.domain.manifest.toml.Parser(moonstone.domain.manifest.toml.Table).init(allocator);
            defer parser.deinit();
            if (parser.parseString(cfg_content)) |cfg_res| {
                defer cfg_res.deinit();
                const moonstone_table = cfg_res.value.get("moonstone");
                if (moonstone_table) |mt| {
                    const default_rt = mt.table.get("default_runtime");
                    if (default_rt) |dr| {
                        const rt_spec = dr.string;
                        if (idx_res) |idx| {
                            const sql = "SELECT artifact_hash FROM artifacts WHERE kind = 'runtime' AND (name || '-' || version = ? OR version = ?) LIMIT 1;";
                            var stmt: ?*moonstone.store.driver.c.sqlite3_stmt = null;
                            if (moonstone.store.driver.c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) == moonstone.store.driver.c.SQLITE_OK) {
                                defer _ = moonstone.store.driver.c.sqlite3_finalize(stmt);
                                const transient = moonstone.store.driver.moonstone_sqlite_transient_ptr;
                                _ = moonstone.store.driver.c.sqlite3_bind_text(stmt, 1, rt_spec.ptr, @intCast(rt_spec.len), transient);
                                _ = moonstone.store.driver.c.sqlite3_bind_text(stmt, 2, rt_spec.ptr, @intCast(rt_spec.len), transient);

                                if (moonstone.store.driver.c.sqlite3_step(stmt) == moonstone.store.driver.c.SQLITE_ROW) {
                                    rt_msg = try std.fmt.allocPrint(allocator, "OK ({s})", .{rt_spec});
                                } else {
                                    rt_ok = false;
                                    rt_msg = try std.fmt.allocPrint(allocator, "WARN: Default runtime {s} not found in store. Run 'moon use --global <spec>'", .{rt_spec});
                                }
                            } else {
                                rt_ok = false;
                                rt_msg = try std.fmt.allocPrint(allocator, "FAIL: SQL error during runtime check", .{});
                            }
                        }
                    } else {
                        rt_ok = false;
                        rt_msg = try std.fmt.allocPrint(allocator, "WARN: default_runtime not set in config.toml", .{});
                    }
                }
            } else |_| {
                rt_ok = false;
                rt_msg = try std.fmt.allocPrint(allocator, "FAIL: config.toml is invalid", .{});
            }
        } else |_| {
            rt_ok = false;
            rt_msg = try std.fmt.allocPrint(allocator, "FAIL: could not read config.toml", .{});
        }
        try results.append(allocator, .{ .passed = rt_ok, .name = .default_runtime, .message = rt_msg, .fixed = false });
        try self.reportCheck(emitter, io, stdout, "default_runtime", rt_ok, rt_msg);

        // ── 7. Environment variables ─────────────────────────────────────
        const ev_ok = true;
        var ev_msg: []const u8 = "";
        if (env.get("MOONSTONE_HOME")) |h| {
            ev_msg = try std.fmt.allocPrint(allocator, "MOONSTONE_HOME={s}", .{h});
        } else {
            ev_msg = try std.fmt.allocPrint(allocator, "OK (using defaults)", .{});
        }
        try results.append(allocator, .{ .passed = ev_ok, .name = .env_vars, .message = ev_msg, .fixed = false });
        try self.reportCheck(emitter, io, stdout, "env_vars", ev_ok, ev_msg);

        // ── 8–11. Project checks (only if inside a project) ──────────────
        var project_root = moonstone.project.discovery.enterRoot(allocator, io, ".") catch |err| blk: {
            if (err == error.NotInsideMoonstoneProject) break :blk null;
            return err;
        };
        defer if (project_root) |*root| root.deinit(allocator);

        if (project_root == null) {
            if (emitter) |e| {
                try e.emit(io, .INFO, "project", "not-in-project", .{});
            } else {
                try stdout.print("[-] Not in a Moonstone project (skipping project checks).\n", .{});
            }
        } else {
            const project_msg = try std.fmt.allocPrint(allocator, "OK ({s})", .{project_root.?.path});
            try results.append(allocator, .{ .passed = true, .name = .project_root, .message = project_msg, .fixed = false });
            try self.reportCheck(emitter, io, stdout, "project_root", true, project_msg);

            // 3. Manifest
            var manifest_ok = true;
            var manifest_msg: []const u8 = "";
            if (std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024))) |content| {
                defer allocator.free(content);
                if (moonstone.domain.manifest.MoonstoneToml.parse(allocator, content)) |parsed_mt| {
                    var mt = parsed_mt;
                    mt.deinit(allocator);
                } else |err| {
                    manifest_ok = false;
                    manifest_msg = try std.fmt.allocPrint(allocator, "FAIL: moonstone.toml is invalid: {s}", .{@errorName(err)});
                }
                if (manifest_ok and manifest_msg.len == 0) {
                    manifest_msg = try std.fmt.allocPrint(allocator, "OK", .{});
                }
            } else |err| {
                manifest_ok = false;
                manifest_msg = try std.fmt.allocPrint(allocator, "FAIL: could not read moonstone.toml: {s}", .{@errorName(err)});
            }
            try results.append(allocator, .{ .passed = manifest_ok, .name = .manifest, .message = manifest_msg, .fixed = false });
            try self.reportCheck(emitter, io, stdout, "manifest", manifest_ok, manifest_msg);

            // 4. Lockfile artifacts in index
            var lockfile_ok = true;
            var lockfile_msg: []const u8 = "";
            var lockfile_sync_ok = true;
            var lockfile_sync_msg: []const u8 = "";
            if (std.Io.Dir.cwd().readFileAlloc(io, "moonstone.lock", allocator, std.Io.Limit.limited(1024 * 1024))) |lock_content| {
                defer allocator.free(lock_content);
                if (moonstone.domain.lockfile.LockFile.parse(allocator, lock_content)) |parsed_lf| {
                    var lf = parsed_lf;
                    defer lf.deinit();
                    var missing_artifacts: usize = 0;
                    if (idx_res) |idx| {
                        var mutable_idx = idx;
                        for (lf.packages.items) |pkg| {
                            if (pkg.artifact_hash.len > 0) {
                                const exists = (mutable_idx.has_artifact(pkg.artifact_hash) catch false);
                                if (!exists) {
                                    missing_artifacts += 1;
                                }
                            }
                        }
                    }

                    if (missing_artifacts > 0) {
                        lockfile_ok = false;
                        lockfile_msg = try std.fmt.allocPrint(allocator, "FAIL: {d} lockfile artifacts missing from store index.", .{missing_artifacts});
                    } else {
                        lockfile_msg = try std.fmt.allocPrint(allocator, "OK", .{});
                    }

                    const manifest_content = std.Io.Dir.cwd().readFileAlloc(io, "moonstone.toml", allocator, std.Io.Limit.limited(1024 * 1024)) catch null;
                    if (manifest_content) |mc| {
                        defer allocator.free(mc);
                        if (moonstone.domain.manifest.MoonstoneToml.parse(allocator, mc)) |parsed_mt| {
                            var mt = parsed_mt;
                            defer mt.deinit(allocator);
                            const missing_deps = try countMissingLockedDeps(allocator, &mt, &lf);
                            if (missing_deps > 0) {
                                lockfile_sync_ok = false;
                                const suffix = if (missing_deps == 1) "y" else "ies";
                                lockfile_sync_msg = try std.fmt.allocPrint(allocator, "WARN: moonstone.lock is missing {d} manifest dependenc{s}. Run 'moon sync'.", .{ missing_deps, suffix });
                            } else {
                                lockfile_sync_msg = try std.fmt.allocPrint(allocator, "OK", .{});
                            }
                        } else |_| {
                            lockfile_sync_ok = false;
                            lockfile_sync_msg = try std.fmt.allocPrint(allocator, "WARN: could not compare lockfile with invalid moonstone.toml.", .{});
                        }
                    } else {
                        lockfile_sync_ok = false;
                        lockfile_sync_msg = try std.fmt.allocPrint(allocator, "WARN: could not read moonstone.toml for lockfile sync check.", .{});
                    }
                } else |err| {
                    lockfile_ok = false;
                    lockfile_msg = try std.fmt.allocPrint(allocator, "FAIL: moonstone.lock is invalid: {s}", .{@errorName(err)});
                    lockfile_sync_ok = false;
                    lockfile_sync_msg = try std.fmt.allocPrint(allocator, "WARN: skipped sync check because moonstone.lock is invalid.", .{});
                }
            } else |_| {
                lockfile_msg = try std.fmt.allocPrint(allocator, "WARN: No lockfile found.", .{});
                lockfile_sync_ok = false;
                lockfile_sync_msg = try std.fmt.allocPrint(allocator, "WARN: No lockfile found. Run 'moon sync'.", .{});
            }
            try results.append(allocator, .{ .passed = lockfile_ok, .name = .lockfile_artifacts, .message = lockfile_msg, .fixed = false });
            try self.reportCheck(emitter, io, stdout, "lockfile_artifacts", lockfile_ok, lockfile_msg);
            try results.append(allocator, .{ .passed = lockfile_sync_ok, .name = .lockfile_sync, .message = lockfile_sync_msg, .fixed = false });
            try self.reportCheck(emitter, io, stdout, "lockfile_sync", lockfile_sync_ok, lockfile_sync_msg);

            // 5. Environment symlinks
            var env_ok = true;
            var env_msg: []const u8 = "";
            if (std.Io.Dir.cwd().openDir(io, ".moonstone/env", .{})) |env_dir| {
                defer env_dir.close(io);
                const env_abs = std.Io.Dir.cwd().realPathFileAlloc(io, ".moonstone/env", allocator) catch try allocator.dupe(u8, ".moonstone/env");
                defer allocator.free(env_abs);
                const broken_links = try countBrokenSymlinks(allocator, io, env_dir, env_abs);
                if (broken_links > 0) {
                    env_ok = false;
                    env_msg = try std.fmt.allocPrint(allocator, "WARN: {d} broken symlink(s) in .moonstone/env. Run 'moon sync'.", .{broken_links});
                } else if (env_dir.access(io, "bin/lua", .{})) |_| {
                    env_msg = try std.fmt.allocPrint(allocator, "OK", .{});
                } else |_| {
                    env_ok = false;
                    env_msg = try std.fmt.allocPrint(allocator, "WARN: Lua binary symlink broken or missing.", .{});
                    if (self.fix) {
                        const lua_link = ".moonstone/env/bin/lua";
                        _ = std.Io.Dir.cwd().deleteFile(io, lua_link) catch {};
                        env_msg = try std.fmt.allocPrint(allocator, "FIXED: Removed dangling Lua symlink.", .{});
                    }
                }
            } else |_| {
                env_ok = false;
                env_msg = try std.fmt.allocPrint(allocator, "WARN: No runtime linked. Run 'moon sync'.", .{});
            }
            try results.append(allocator, .{ .passed = env_ok, .name = .env_symlinks, .message = env_msg, .fixed = self.fix and !env_ok });
            try self.reportCheck(emitter, io, stdout, "env_symlinks", env_ok, env_msg);
        }


        if (idx_res) |*i| {
            i.deinit();
            idx_res = null;
        }

        // ── 9. System tools ───────────────────────────────────────────────
        var tools_ok = true;
        var tools_msg: []const u8 = "";
        const sys_tools = [_][]const u8{ "gcc", "make", "tar", "zig", "python3", "zstd" };
        var missing_tools = std.ArrayList([]const u8).empty;
        defer missing_tools.deinit(allocator);

        for (sys_tools) |tool| {
            const res = std.process.run(allocator, io, .{
                .argv = &.{ "which", tool },
            }) catch |err| {
                if (err == error.FileNotFound) {
                    try missing_tools.append(allocator, tool);
                    continue;
                }
                return err;
            };
            if (res.term != .exited or res.term.exited != 0) {
                try missing_tools.append(allocator, tool);
            }
        }

        if (missing_tools.items.len > 0) {
            tools_ok = false;
            var msg_buf = std.ArrayList(u8).empty;
            defer msg_buf.deinit(allocator);
            try msg_buf.appendSlice(allocator, "WARN: Missing tools:");
            for (missing_tools.items) |t| {
                try msg_buf.appendSlice(allocator, " ");
                try msg_buf.appendSlice(allocator, t);
            }
            tools_msg = try allocator.dupe(u8, msg_buf.items);
        } else {
            tools_msg = try std.fmt.allocPrint(allocator, "OK", .{});
        }
        try results.append(allocator, .{ .passed = tools_ok, .name = .system_tools, .message = tools_msg, .fixed = false });
        try self.reportCheck(emitter, io, stdout, "system_tools", tools_ok, tools_msg);

        // ── Summary ───────────────────────────────────────────────────────
        var failed_count: usize = 0;
        var warn_count: usize = 0;
        for (results.items) |r| {
            if (!r.passed) {
                if (std.mem.startsWith(u8, r.message, "WARN:")) {
                    warn_count += 1;
                } else {
                    failed_count += 1;
                }
            }
        }

        if (emitter) |e| {
            try e.terminate(io, name, if (failed_count == 0) "ok" else "partial", .{
                .issues = failed_count,
                .warnings = warn_count,
                .checks_passed = results.items.len - failed_count - warn_count,
                .checks_failed = failed_count + warn_count,
            });
        } else {
            if (failed_count == 0) {
                try stdout.print("\nAll systems nominal.", .{});
                if (warn_count > 0) {
                    try stdout.print(" ({d} warning(s)).\n", .{warn_count});
                } else {
                    try stdout.print("\n", .{});
                }
            } else {
                try stdout.print("\nFound {d} health issue(s), {d} warning(s).\n", .{ failed_count, warn_count });
            }
        }

        if (failed_count > 0) {
            return error.HealthCheckFailed;
        }
    }

    fn countMissingLockedDeps(allocator: std.mem.Allocator, mt: *moonstone.domain.manifest.MoonstoneToml, lf: *moonstone.domain.lockfile.LockFile) !usize {
        var missing: usize = 0;
        missing += try countMissingLockedDepsInMap(allocator, &mt.dependencies.libs, lf);
        missing += try countMissingLockedDepsInMap(allocator, &mt.dependencies.bins, lf);
        missing += try countMissingLockedDepsInMap(allocator, &mt.dependencies.dev_libs, lf);
        missing += try countMissingLockedDepsInMap(allocator, &mt.dependencies.dev_bins, lf);
        return missing;
    }

    fn countMissingLockedDepsInMap(
        allocator: std.mem.Allocator,
        deps: *std.StringArrayHashMapUnmanaged([]const u8),
        lf: *moonstone.domain.lockfile.LockFile,
    ) !usize {
        var missing: usize = 0;
        var it = deps.iterator();
        while (it.next()) |entry| {
            const spec = try moonstone.domain.package_spec.parsePackageSpec(allocator, entry.value_ptr.*);
            defer spec.deinit(allocator);
            if (spec.resolver) |resolver| {
                if (resolver == .link or resolver == .path or resolver == .artifact) continue;
            }
            if (lf.find(entry.key_ptr.*) == null) missing += 1;
        }
        return missing;
    }

    fn countBrokenSymlinks(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, abs_dir_path: []const u8) !usize {
        var broken: usize = 0;
        var iterable_dir = dir;
        var it = iterable_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory) {
                var child_dir = try iterable_dir.openDir(io, entry.name, .{ .iterate = true });
                defer child_dir.close(io);
                const child_abs = try std.fs.path.join(allocator, &.{ abs_dir_path, entry.name });
                defer allocator.free(child_abs);
                broken += try countBrokenSymlinks(allocator, io, child_dir, child_abs);
            } else if (entry.kind == .sym_link) {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = iterable_dir.readLink(io, entry.name, &buf) catch {
                    broken += 1;
                    continue;
                };
                const target = buf[0..len];
                const target_path = if (std.fs.path.isAbsolute(target))
                    try allocator.dupe(u8, target)
                else
                    try std.fs.path.join(allocator, &.{ abs_dir_path, target });
                defer allocator.free(target_path);
                std.Io.Dir.cwd().access(io, target_path, .{}) catch {
                    broken += 1;
                };
            }
        }
        return broken;
    }

    fn reportCheck(self: DoctorCommand, emitter: ?*ndjson.Emitter, io: std.Io, stdout: *std.Io.Writer, about: []const u8, ok: bool, msg: []const u8) !void {
        _ = self;
        if (emitter) |e| {
            const severity: ndjson.MessageKind = if (std.mem.startsWith(u8, msg, "WARN:")) .WARN else if (!ok) .ERROR else .STATUS;
            const value = if (std.mem.startsWith(u8, msg, "WARN:")) msg[6..] else if (!ok) (if (msg.len > 6) msg[6..] else "fail") else "ok";
            var actual_value: []const u8 = value;
            if (std.mem.startsWith(u8, msg, "OK")) actual_value = "ok";
            if (std.mem.startsWith(u8, msg, "FIXED:")) actual_value = "fixed";

            try e.emit(io, severity, about, actual_value, .{ .message = msg });
        } else {
            try stdout.print("[ ] Checking {s}... ", .{about});
            try stdout.print("{s}\n", .{msg});
        }
    }
};
