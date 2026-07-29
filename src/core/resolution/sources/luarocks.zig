const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const fs = @import("../../platform/fs.zig");
const http = @import("../../platform/http.zig");
const store = @import("../../store.zig");
const hash = @import("../../identity/hash.zig");
const luarocks = @import("../../luarocks/rockspec.zig");
const luarocks_compat = @import("../../luarocks/compat.zig");
const manifest_cache_mod = @import("../../cache/manifest_cache.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

const profiler = @import("../../diagnostics/profiler.zig");

var manifest_cache: std.StringHashMapUnmanaged([]u8) = .empty;

fn get_luarocks_base(env_map: *std.process.Environ.Map) []const u8 {
    return env_map.get("MOONSTONE_LUAROCKS_URL") orelse "https://luarocks.org";
}

// ---------------------------------------------------------------------------
// Phase 1 — Candidate discovery
// ---------------------------------------------------------------------------

const ProgressAdapterCtx = struct {
    url: []const u8,
    label: ?[]const u8 = null,
    on_event: options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
};

fn progress_adapter(ctx_ptr: ?*anyopaque, downloaded: usize, total: ?usize) void {
    const ctx: *ProgressAdapterCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
    ctx.on_event(ctx.on_event_context, .{ .download_progress = .{
        .url = ctx.url,
        .pkg_name = ctx.label,
        .downloaded_bytes = downloaded,
        .total_bytes = total,
    } });
}

fn http_get_single(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    timeout_ms: u32,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
    progress_label: ?[]const u8,
) ![]u8 {
    var pctx: ?ProgressAdapterCtx = null;
    var pcb: ?http.ProgressCallback = null;
    if (on_event) |cb| {
        pctx = .{
            .url = url,
            .label = progress_label,
            .on_event = cb,
            .on_event_context = on_event_context,
        };
        pcb = progress_adapter;
    }

    const resp = try http.fetchGetWithProgress(allocator, io, url, null, timeout_ms, pcb, if (pctx) |*p| p else null);
    if (resp.status == .not_found) {
        allocator.free(resp.body);
        return error.FileNotFound;
    }
    if (resp.status != .ok) {
        allocator.free(resp.body);
        return error.HttpError;
    }
    return resp.body;
}

fn http_get(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
    progress_label: ?[]const u8,
) ![]u8 {
    const net_cfg = fs.get_network_config(allocator, env_map, io);
    const http_cfg = http.get_http_config(allocator, env_map, io);

    const max_retries = net_cfg.retries;
    const delay_seconds = net_cfg.retry_delay;

    var attempt: u32 = 0;
    while (true) {
        if (http_get_single(allocator, io, url, http_cfg.timeout_ms, on_event, on_event_context, progress_label)) |data| {
            return data;
        } else |err| {
            if (err == error.FileNotFound) return err;

            attempt += 1;
            if (attempt > max_retries) {
                return err;
            }

            if (on_event) |cb| {
                cb(on_event_context, .{
                    .retry = .{
                        .url = url,
                        .err_name = @errorName(err),
                        .attempt = attempt,
                        .max_retries = max_retries,
                        .delay_seconds = delay_seconds,
                    },
                });
            }

            std.Io.sleep(io, std.Io.Duration.fromSeconds(delay_seconds), .awake) catch {};
        }
    }
}

fn blake3_prefixed(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const raw = try hash.blake3_hex(allocator, data);
    defer allocator.free(raw);
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{raw});
}

const FetchedRockspec = struct {
    content: []const u8,
    url: []const u8,
    hash: []const u8,

    fn deinit(self: FetchedRockspec, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.url);
        allocator.free(self.hash);
    }
};

const FetchedSource = struct {
    path: []const u8,
    url: []const u8,
    hash: []const u8,
    kind: []const u8,
    payload_path: []const u8,

    fn deinit(self: FetchedSource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.url);
        allocator.free(self.hash);
        allocator.free(self.kind);
        allocator.free(self.payload_path);
    }
};

const SourceFetch = struct {
    url: []const u8,
    data: []u8,
};

fn runtime_to_manifest_url(allocator: std.mem.Allocator, base: []const u8, runtime: ?[]const u8) ![]const u8 {
    const version = blk: {
        if (runtime) |rt| {
            if (std.mem.eql(u8, rt, "luajit")) break :blk try allocator.dupe(u8, "5.1");

            // Remove 'lua' prefix if present
            var clean_rt = rt;
            if (std.mem.startsWith(u8, clean_rt, "lua")) {
                clean_rt = clean_rt[3..];
            }
            // Remove leading caret/tilde/equal
            while (clean_rt.len > 0 and (clean_rt[0] == '^' or clean_rt[0] == '~' or clean_rt[0] == '=')) {
                clean_rt = clean_rt[1..];
            }

            if (clean_rt.len >= 3 and clean_rt[1] == '.') {
                break :blk try allocator.dupe(u8, clean_rt[0..3]);
            }
        }
        break :blk try allocator.dupe(u8, "5.4");
    };
    defer allocator.free(version);
    return try std.fmt.allocPrint(allocator, "{s}/manifest-{s}.json", .{ base, version });
}

fn manifest_cache_key(url: []const u8) manifest_cache_mod.CacheKey {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse url.len;
    return .{
        .source = .luarocks,
        .scope = url[0..slash],
        .name = if (slash < url.len) url[slash + 1 ..] else url,
        .extension = "json",
    };
}

fn read_persistent_manifest_cache(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    url: []const u8,
    allow_stale: bool,
) !?[]u8 {
    const paths = try fs.resolve_moonstone(allocator, env_map, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }
    const cfg = manifest_cache_mod.getConfig(allocator, env_map, io);
    var cache = try manifest_cache_mod.ManifestCache.init(allocator, io, paths, cfg);
    defer cache.deinit();
    const key = manifest_cache_key(url);
    if (allow_stale) return try cache.readAny(key);
    return try cache.readFresh(key);
}

fn write_persistent_manifest_cache(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    url: []const u8,
    body: []const u8,
) void {
    const paths = fs.resolve_moonstone(allocator, env_map, io) catch return;
    defer {
        var p = paths;
        p.deinit(allocator);
    }
    const cfg = manifest_cache_mod.getConfig(allocator, env_map, io);
    var cache = manifest_cache_mod.ManifestCache.init(allocator, io, paths, cfg) catch return;
    defer cache.deinit();
    cache.write(manifest_cache_key(url), url, body) catch {};
}

/// Fetch the LuaRocks manifest and return the parsed JSON value.
/// Caller must call .deinit() on the result.
fn fetch_manifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    runtime: ?[]const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
    allow_stale_cache: bool,
) !std.json.Parsed(std.json.Value) {
    const url = try runtime_to_manifest_url(allocator, base, runtime);
    defer allocator.free(url);
    const body = blk: {
        if (manifest_cache.get(url)) |cached| {
            profiler.mark("luarocks.manifest.cache_hit");
            break :blk cached;
        }
        if (try read_persistent_manifest_cache(allocator, io, env_map, url, allow_stale_cache)) |cached| {
            profiler.mark("luarocks.manifest.disk_cache_hit");
            errdefer allocator.free(cached);
            try manifest_cache.put(allocator, try allocator.dupe(u8, url), cached);
            break :blk cached;
        }
        const span = profiler.now();
        if (on_event) |cb| cb(on_event_context, .{ .metadata_sync_started = "Syncing LuaRocks manifest" });
        const fetched = http_get(allocator, io, url, env_map, on_event, on_event_context, "Syncing LuaRocks manifest") catch |err| {
            // TODO: handle err
            std.debug.print("luarocks source error: {s}\n", .{@errorName(err)});
            return error.RocksVersionDiscoveryFailed;
        };
        if (on_event) |cb| cb(on_event_context, .{ .metadata_sync_done = "LuaRocks manifest synced" });
        profiler.span("luarocks.manifest.fetch", span);
        errdefer allocator.free(fetched);
        write_persistent_manifest_cache(allocator, io, env_map, url, fetched);
        try manifest_cache.put(allocator, try allocator.dupe(u8, url), fetched);
        break :blk fetched;
    };
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        // TODO: handle err
        std.debug.print("luarocks source error: {s}\n", .{@errorName(err)});
        return error.RocksVersionDiscoveryFailed;
    };
}

/// Map host platform to LuaRocks arch string. Returns null if unsupported.
fn host_to_luarocks_arch(allocator: std.mem.Allocator) !?[]const u8 {
    const builtin = @import("builtin");
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => return null,
    };
    const os_tag = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macosx",
        .windows => "win32",
        else => return null,
    };
    return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_tag, arch });
}

fn has_luarocks_revision(version: []const u8) bool {
    const dash = std.mem.lastIndexOfScalar(u8, version, '-');
    if (dash) |d| {
        const suffix = version[d + 1 ..];
        if (suffix.len == 0) return false;
        for (suffix) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }
    return false;
}

fn normalize_luarocks_version(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, version, '+')) |plus| {
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ version[0..plus], version[plus + 1 ..] });
    }
    return try allocator.dupe(u8, version);
}

fn rock_build_type(rock: *const luarocks.Rockspec) []const u8 {
    return rock.build.type orelse "builtin";
}

fn rock_source_url(rock: *const luarocks.Rockspec) []const u8 {
    return rock.source.url orelse "";
}

fn translateCommandBuild(
    allocator: std.mem.Allocator,
    rock: *const luarocks.Rockspec,
    lua_abi: []const u8,
) ![]const TranslatedModule {
    _ = lua_abi;
    const is_cmake = std.mem.eql(u8, rock_build_type(rock), "cmake");
    var list = std.ArrayList(TranslatedModule).empty;
    errdefer {
        for (list.items) |*m| {
            allocator.free(m.name);
            allocator.free(m.dest_path);
            if (m.config) |*c| c.deinit(allocator);
        }
        list.deinit(allocator);
    }

    var steps = std.ArrayList(manifest.CommandStep).empty;
    defer {
        for (steps.items) |s| {
            allocator.free(s.command);
            for (s.args) |a| allocator.free(a);
            allocator.free(s.args);
        }
        steps.deinit(allocator);
    }
    var env_pairs = std.ArrayList(manifest.EnvPair).empty;
    defer {
        for (env_pairs.items) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        env_pairs.deinit(allocator);
    }

    if (!is_cmake) {
        // Build command
        const build_cmd = "make"; // TODO: read build_command from rockspec if available
        var b_args = std.ArrayList([]const u8).empty;

        // Note: we can't easily parse build_variables from JSON yet as Rockspec doesn't have it defined fully,
        // but typically rockspecs have build_variables. We'll set up standard env vars.
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "PREFIX"), .value = try allocator.dupe(u8, "${out}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUADIR"), .value = try allocator.dupe(u8, "${out}/share/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LIBDIR"), .value = try allocator.dupe(u8, "${out}/lib/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "BINDIR"), .value = try allocator.dupe(u8, "${out}/bin") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUA_INCDIR"), .value = try allocator.dupe(u8, "${runtime.include}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUA_LIBDIR"), .value = try allocator.dupe(u8, "${runtime.lib}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUA_BINDIR"), .value = try allocator.dupe(u8, "${runtime.bin_dir}") });

        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "PREFIX"), .value = try allocator.dupe(u8, "${out}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "DESTDIR"), .value = try allocator.dupe(u8, "${out}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "prefix"), .value = try allocator.dupe(u8, "") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "INST_LIBDIR"), .value = try allocator.dupe(u8, "${out}/lib/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "INST_LUADIR"), .value = try allocator.dupe(u8, "${out}/share/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUADIR"), .value = try allocator.dupe(u8, "${out}/share/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LIBDIR"), .value = try allocator.dupe(u8, "${out}/lib/lua/${lua_abi}") });

        try steps.append(allocator, .{ .command = try allocator.dupe(u8, build_cmd), .args = try b_args.toOwnedSlice(allocator) });

        var i_args = std.ArrayList([]const u8).empty;
        try i_args.append(allocator, try allocator.dupe(u8, "install"));
        try steps.append(allocator, .{ .command = try allocator.dupe(u8, build_cmd), .args = try i_args.toOwnedSlice(allocator) });
    }

    const config = manifest.MaterializeConfig{
        .kind = if (is_cmake) "cmake" else "command",
        .steps = try steps.toOwnedSlice(allocator),
        .env = try env_pairs.toOwnedSlice(allocator),
    };

    try list.append(allocator, .{
        .name = try allocator.dupe(u8, "command_build"),
        .kind = .c,
        .dest_path = try allocator.dupe(u8, ""),
        .config = config,
    });

    return try list.toOwnedSlice(allocator);
}

const TranslatedModule = struct {
    name: []const u8,
    kind: enum { lua, c, data },
    dest_path: []const u8,
    source_path: ?[]const u8 = null,
    config: ?manifest.MaterializeConfig = null,
};

fn translateBuiltinBuild(
    allocator: std.mem.Allocator,
    rock: *const luarocks.Rockspec,
    lua_abi: []const u8,
) ![]const TranslatedModule {
    var list = std.ArrayList(TranslatedModule).empty;
    errdefer {
        for (list.items) |m| {
            allocator.free(m.name);
            allocator.free(m.dest_path);
            if (m.source_path) |source_path| allocator.free(source_path);
            if (m.config) |c| {
                if (c.input) |in| {
                    for (in.sources) |s| allocator.free(s);
                    allocator.free(in.sources);
                }
                if (c.output) |out| {
                    allocator.free(out.module);
                    allocator.free(out.path);
                }
                for (c.args) |a| allocator.free(a);
                allocator.free(c.args);
                for (c.ldflags) |a| allocator.free(a);
                allocator.free(c.ldflags);
            }
        }
        list.deinit(allocator);
    }

    const lua_ver_dot = if (std.mem.startsWith(u8, lua_abi, "lua") and lua_abi.len == 5)
        try std.fmt.allocPrint(allocator, "{c}.{c}", .{ lua_abi[3], lua_abi[4] })
    else
        try allocator.dupe(u8, lua_abi);
    defer allocator.free(lua_ver_dot);

    if (rock.build.modules) |modules| if (modules == .object) {
        var mod_it = modules.object.iterator();
        while (mod_it.next()) |entry| {
            const mod_name = entry.key_ptr.*;
            const mod_val = entry.value_ptr.*;

            const name_path = try std.mem.replaceOwned(u8, allocator, mod_name, ".", "/");
            defer allocator.free(name_path);

            if (mod_val == .string) {
                const val = mod_val.string;
                if (std.mem.endsWith(u8, val, ".lua")) {
                    const dest_path = try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}.lua", .{ lua_ver_dot, name_path });
                    try list.append(allocator, .{
                        .name = try allocator.dupe(u8, mod_name),
                        .kind = .lua,
                        .dest_path = dest_path,
                        .source_path = try allocator.dupe(u8, val),
                    });
                } else if (is_c_file(val)) {
                    // Single C file
                    const dest_path = try std.fmt.allocPrint(allocator, "lib/lua/{s}/{s}.so", .{ lua_ver_dot, name_path });
                    var srcs = try allocator.alloc([]const u8, 1);
                    srcs[0] = try allocator.dupe(u8, val);

                    const m_config = manifest.MaterializeConfig{
                        .kind = "native-cmodule",
                        .strategy = "rocks",
                        .input = .{ .sources = srcs },
                        .output = .{
                            .module = try allocator.dupe(u8, mod_name),
                            .path = try allocator.dupe(u8, dest_path),
                        },
                    };
                    try list.append(allocator, .{
                        .name = try allocator.dupe(u8, mod_name),
                        .kind = .c,
                        .dest_path = dest_path,
                        .config = m_config,
                    });
                }
            } else if (mod_val == .array) {
                // Bare array of source files — a common LuaRocks convention.
                // e.g. lpeg = { 'lpcap.c', 'lpcode.c', ... }
                // All entries must be C files; treat as a multi-source C module.
                const dest_path = try std.fmt.allocPrint(allocator, "lib/lua/{s}/{s}.so", .{ lua_ver_dot, name_path });

                var srcs_list = std.ArrayList([]const u8).empty;
                errdefer {
                    for (srcs_list.items) |s| allocator.free(s);
                    srcs_list.deinit(allocator);
                }

                for (mod_val.array.items) |item| {
                    if (item == .string) {
                        try srcs_list.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }

                const m_config = manifest.MaterializeConfig{
                    .kind = "native-cmodule",
                    .strategy = "rocks",
                    .input = .{ .sources = try srcs_list.toOwnedSlice(allocator) },
                    .output = .{
                        .module = try allocator.dupe(u8, mod_name),
                        .path = try allocator.dupe(u8, dest_path),
                    },
                };
                try list.append(allocator, .{
                    .name = try allocator.dupe(u8, mod_name),
                    .kind = .c,
                    .dest_path = dest_path,
                    .config = m_config,
                });
            } else if (mod_val == .object) {
                const m_obj = mod_val.object;
                const sources_val = m_obj.get("sources") orelse m_obj.get("source");
                if (sources_val) |sv| {
                    // C Module
                    const dest_path = try std.fmt.allocPrint(allocator, "lib/lua/{s}/{s}.so", .{ lua_ver_dot, name_path });

                    var srcs_list = std.ArrayList([]const u8).empty;
                    errdefer {
                        for (srcs_list.items) |s| allocator.free(s);
                        srcs_list.deinit(allocator);
                    }

                    if (sv == .array) {
                        for (sv.array.items) |s| try srcs_list.append(allocator, try allocator.dupe(u8, s.string));
                    } else if (sv == .string) {
                        try srcs_list.append(allocator, try allocator.dupe(u8, sv.string));
                    }

                    var cflags = std.ArrayList([]const u8).empty;
                    errdefer {
                        for (cflags.items) |f| allocator.free(f);
                        cflags.deinit(allocator);
                    }
                    if (m_obj.get("defines")) |dv| {
                        if (dv == .array) {
                            for (dv.array.items) |d| try cflags.append(allocator, try std.fmt.allocPrint(allocator, "-D{s}", .{d.string}));
                        }
                    }
                    if (m_obj.get("incdirs")) |iv| {
                        if (iv == .array) {
                            for (iv.array.items) |i| try cflags.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{std.mem.trim(u8, i.string, "/")}));
                        } else if (iv == .string) {
                            try cflags.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{std.mem.trim(u8, iv.string, "/")}));
                        }
                    }
                    if (m_obj.get("incdir")) |iv| {
                        if (iv == .string) {
                            try cflags.append(allocator, try std.fmt.allocPrint(allocator, "-I{s}", .{std.mem.trim(u8, iv.string, "/")}));
                        }
                    }

                    var ldflags = std.ArrayList([]const u8).empty;
                    errdefer {
                        for (ldflags.items) |f| allocator.free(f);
                        ldflags.deinit(allocator);
                    }
                    if (m_obj.get("libdirs")) |lv| {
                        if (lv == .array) {
                            for (lv.array.items) |l| try ldflags.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{l.string}));
                        }
                    }
                    if (m_obj.get("libraries")) |lv| {
                        if (lv == .array) {
                            for (lv.array.items) |l| try ldflags.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{l.string}));
                        }
                    }

                    const m_config = manifest.MaterializeConfig{
                        .kind = "native-cmodule",
                        .strategy = "rocks",
                        .input = .{ .sources = try srcs_list.toOwnedSlice(allocator) },
                        .output = .{
                            .module = try allocator.dupe(u8, mod_name),
                            .path = try allocator.dupe(u8, dest_path),
                        },
                        .args = try cflags.toOwnedSlice(allocator),
                        .ldflags = try ldflags.toOwnedSlice(allocator),
                    };
                    try list.append(allocator, .{
                        .name = try allocator.dupe(u8, mod_name),
                        .kind = .c,
                        .dest_path = dest_path,
                        .config = m_config,
                    });
                }
            }
        }
    };

    if (rock.build.install) |install| if (install.lua) |lua_files| {
        switch (lua_files) {
            .string => |source_path| try appendBuiltinInstalledLuaFile(allocator, &list, lua_ver_dot, source_path),
            .array => |paths| for (paths.items) |path| {
                if (path == .string) try appendBuiltinInstalledLuaFile(allocator, &list, lua_ver_dot, path.string);
            },
            else => {},
        }
    };

    return try list.toOwnedSlice(allocator);
}

fn appendBuiltinInstalledLuaFile(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(TranslatedModule),
    lua_ver_dot: []const u8,
    source_path: []const u8,
) !void {
    const dest_path = try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, source_path });
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, source_path),
        .kind = .data,
        .dest_path = dest_path,
        .source_path = try allocator.dupe(u8, source_path),
    });
}

fn find_manifest_package(repository: std.json.Value, pkg_name: []const u8) ?std.json.Value {
    if (repository.object.get(pkg_name)) |pkg_entry| return pkg_entry;
    var it = repository.object.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, pkg_name)) return entry.value_ptr.*;
    }
    return null;
}

fn manifest_version_has_installable_entry(version_entry: std.json.Value, host_arch: ?[]const u8) bool {
    if (version_entry != .array) return false;
    for (version_entry.array.items) |arch_entry| {
        if (arch_entry != .object) continue;
        const arch_val = arch_entry.object.get("arch") orelse continue;
        if (arch_val != .string) continue;
        if (std.mem.eql(u8, arch_val.string, "rockspec")) return true;
        if (std.mem.eql(u8, arch_val.string, "src")) return true;
        if (host_arch) |arch| {
            if (std.mem.eql(u8, arch_val.string, arch)) return true;
        }
    }
    return false;
}

pub fn discoverVersions(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    options: options_mod.ResolveOptions,
    env_map: *std.process.Environ.Map,
    base_override: ?[]const u8,
) ![]@import("../../domain/semver.zig").Version {
    const semver = @import("../../domain/semver.zig");
    const base = base_override orelse get_luarocks_base(env_map);
    const manifest_parsed = try fetch_manifest(allocator, io, base, options.runtime, env_map, options.on_event, options.on_event_context, options.offline);
    defer manifest_parsed.deinit();
    const repository = manifest_parsed.value.object.get("repository") orelse return error.RocksVersionDiscoveryFailed;
    const pkg_entry = find_manifest_package(repository, pkg_name) orelse return error.PackageNotFound;
    const host_arch = try host_to_luarocks_arch(allocator);
    defer if (host_arch) |arch| allocator.free(arch);

    var versions = std.ArrayList(semver.Version).empty;
    errdefer {
        for (versions.items) |version| version.deinit(allocator);
        versions.deinit(allocator);
    }

    var it = pkg_entry.object.iterator();
    while (it.next()) |entry| {
        if (!manifest_version_has_installable_entry(entry.value_ptr.*, host_arch)) continue;
        const version = semver.Version.parseCloned(allocator, entry.key_ptr.*) catch continue;
        var already_present = false;
        for (versions.items) |existing| {
            if (existing.compare(version) == 0 and std.mem.eql(u8, existing.build, version.build)) {
                already_present = true;
                break;
            }
        }
        if (already_present) {
            version.deinit(allocator);
            continue;
        }
        try versions.append(allocator, version);
    }

    return try versions.toOwnedSlice(allocator);
}

pub fn refreshManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: ?[]const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
) !void {
    const base = get_luarocks_base(env_map);
    const parsed = try fetch_manifest(allocator, io, base, runtime, env_map, on_event, on_event_context, false);
    parsed.deinit();
}

/// Pick the newest version that has an installable rock entry.
fn select_version(allocator: std.mem.Allocator, manifest_json: std.json.Value, pkg_name: []const u8, version_range: []const u8) ![]const u8 {
    // If user gave an exact version (or constraint prefix), strip it and trust it exists.
    if (!std.mem.eql(u8, version_range, "*") and !std.mem.eql(u8, version_range, "")) {
        const ver = if (version_range.len > 0 and (version_range[0] == '^' or version_range[0] == '~' or version_range[0] == '='))
            version_range[1..]
        else
            version_range;
        return try normalize_luarocks_version(allocator, ver);
    }

    const repository = manifest_json.object.get("repository") orelse {
        return error.RocksVersionDiscoveryFailed;
    };
    const pkg_entry = find_manifest_package(repository, pkg_name) orelse {
        return error.PackageNotFound;
    };
    const host_arch = try host_to_luarocks_arch(allocator);
    defer if (host_arch) |arch| allocator.free(arch);

    var best_version: ?[]const u8 = null;
    var it = pkg_entry.object.iterator();
    while (it.next()) |entry| {
        const version_key = entry.key_ptr.*;
        if (!manifest_version_has_installable_entry(entry.value_ptr.*, host_arch)) continue;

        if (best_version) |bv| {
            if (std.mem.order(u8, version_key, bv) == .gt) {
                best_version = version_key;
            }
        } else {
            best_version = version_key;
        }
    }

    const result = best_version orelse {
        return error.RocksVersionDiscoveryFailed;
    };
    return try allocator.dupe(u8, result);
}

/// Check if a binary rock matching the host arch is available for this version.
fn has_binary_rock(manifest_json: std.json.Value, pkg_name: []const u8, version: []const u8, arch_str: []const u8) bool {
    const repository = manifest_json.object.get("repository") orelse return false;
    const pkg_entry = repository.object.get(pkg_name) orelse return false;
    const version_entry = pkg_entry.object.get(version) orelse return false;
    const arch_list = version_entry.array;
    for (arch_list.items) |arch_entry| {
        const arch_val = arch_entry.object.get("arch") orelse continue;
        if (std.mem.eql(u8, arch_val.string, arch_str)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Phase 2 — Prefer binary rock if safe
// ---------------------------------------------------------------------------

const RockResult = struct { path: []const u8, hash: []const u8, recipe_hash: []const u8, source_hash: []const u8 = "", source_url: []const u8 = "" };

/// Download a binary .rock from LuaRocks, unpack it, and commit to store.
/// Returns the store path and artifact hash.
fn resolve_binary_rock(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version: []const u8,
    runtime_spec: []const u8,
    runtime_artifact_hash: []const u8,
    target: []const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
) !RockResult {
    const base = get_luarocks_base(env_map);
    const arch_str = (try host_to_luarocks_arch(allocator)) orelse return error.UnsupportedArchitecture;
    defer allocator.free(arch_str);

    const url = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.{s}.rock", .{ base, pkg_name, version, arch_str });
    defer allocator.free(url);

    const rock_data = try http_get(allocator, io, url, env_map, on_event, on_event_context, null);
    defer allocator.free(rock_data);
    const source_hash = try blake3_prefixed(allocator, rock_data);
    defer allocator.free(source_hash);

    const paths = try fs.resolve_moonstone(allocator, env_map, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    const tmp_dir_name = try std.fmt.allocPrint(allocator, "rocks-bin-{s}-{s}", .{ pkg_name, version });
    defer allocator.free(tmp_dir_name);
    const tmp_dir = try std.fs.path.join(allocator, &.{ paths.tmp, tmp_dir_name });
    defer allocator.free(tmp_dir);

    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir, "bin.rock" });
    defer allocator.free(archive_path);
    const f = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
    try f.writeStreamingAll(io, rock_data);
    f.close(io);

    const unpack_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "unpack" });
    defer allocator.free(unpack_dir);
    try std.Io.Dir.cwd().createDirPath(io, unpack_dir);

    try unpack_archive(allocator, io, pkg_name, version, url, archive_path, unpack_dir);

    const commit_res = try commit_synthetic_artifact(
        allocator,
        io,
        env_map,
        unpack_dir,
        pkg_name,
        version,
        .lib,
        runtime_spec,
        runtime_artifact_hash,
        target,
        source_hash,
        url,
        "luarocks_binary_rock",
        archive_path,
        "",
        "",
        null,
        "rocks-binary",
        &.{}, // lua_modules
        &.{}, // lua_cmodules
        &.{}, // bins
        &.{}, // dependencies
        &.{}, // build_env
    );
    return .{
        .path = commit_res.path,
        .hash = commit_res.hash,
        .recipe_hash = commit_res.recipe_hash,
        .source_hash = try allocator.dupe(u8, source_hash),
        .source_url = try allocator.dupe(u8, url),
    };
}

// ---------------------------------------------------------------------------
// Phase 3 — Fetch rockspec
// ---------------------------------------------------------------------------

fn fetch_rockspec(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    pkg_name: []const u8,
    version: []const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
) !FetchedRockspec {
    // If version already includes a LuaRocks revision (e.g. "3.1.3-1"), try exact rockspec first.
    if (has_luarocks_revision(version)) {
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.rockspec", .{
            base, pkg_name, version,
        });
        defer allocator.free(url);
        const content = http_get(allocator, io, url, env_map, on_event, on_event_context, null) catch |err| blk: {
            if (err == error.HttpError or err == error.FileNotFound) break :blk null;
            return err;
        };
        if (content) |c| {
            if (std.mem.indexOf(u8, c, "package =") != null) {
                return .{
                    .content = c,
                    .url = try allocator.dupe(u8, url),
                    .hash = try blake3_prefixed(allocator, c),
                };
            }
            allocator.free(c);
        }
    }

    // Probe revisions 1-3.
    var rev: u32 = 1;
    while (rev <= 3) : (rev += 1) {
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}-{d}.rockspec", .{
            base, pkg_name, version, rev,
        });
        defer allocator.free(url);
        const content = http_get(allocator, io, url, env_map, on_event, on_event_context, null) catch |err| {
            if (err == error.HttpError or err == error.FileNotFound) continue;
            return err;
        };
        if (std.mem.indexOf(u8, content, "package =") != null) {
            return .{
                .content = content,
                .url = try allocator.dupe(u8, url),
                .hash = try blake3_prefixed(allocator, content),
            };
        }
        allocator.free(content);
    }
    return error.RockspecNotFound;
}

// ---------------------------------------------------------------------------
// Phase 4 — Classify
// ---------------------------------------------------------------------------

const RockClass = enum {
    pure_lua, // A: auto-import
    builtin_cmodule, // B: translate to native-cmodule (future)
    binary_rock, // C: unpack prebuilt artifact
    command_build, // D: translate to command materializer (future)
    unsupported, // E: clear error
};

fn is_c_file(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".c") or
        std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".h");
}

fn classify_rock(rock: *const luarocks.Rockspec) RockClass {
    const btype = rock_build_type(rock);
    const is_builtin = btype.len == 0 or std.mem.eql(u8, btype, "builtin");
    const is_make = std.mem.eql(u8, btype, "make");
    const is_cmake = std.mem.eql(u8, btype, "cmake");
    const is_command = std.mem.eql(u8, btype, "command");

    if (is_make or is_cmake or is_command) {
        return .command_build;
    }

    if (!is_builtin) {
        return .unsupported;
    }

    // Check modules for C sources
    if (rock.build.modules) |modules| {
        if (modules == .object) {
            var it = modules.object.iterator();
            while (it.next()) |entry| {
                const mod_val = entry.value_ptr.*;
                if (mod_val == .string) {
                    if (is_c_file(mod_val.string)) return .builtin_cmodule;
                } else if (mod_val == .array) {
                    // Bare array of source files — check for C files.
                    for (mod_val.array.items) |item| {
                        if (item == .string and is_c_file(item.string)) return .builtin_cmodule;
                    }
                } else if (mod_val == .object) {
                    if (mod_val.object.get("sources")) |srcs| {
                        if (srcs == .array and srcs.array.items.len > 0) return .builtin_cmodule;
                    }
                }
            }
        }
    }

    return .pure_lua;
}

// ---------------------------------------------------------------------------
// Phase 5 — Source fetch
// ---------------------------------------------------------------------------

fn unpack_archive(allocator: std.mem.Allocator, io: std.Io, package_name: []const u8, package_version: []const u8, archive_url: []const u8, archive_path: []const u8, out_dir: []const u8) !void {
    const is_zip = std.mem.endsWith(u8, archive_path, ".zip") or
        std.mem.endsWith(u8, archive_path, ".src.rock") or
        std.mem.endsWith(u8, archive_path, ".rock");
    const is_tar_gz = std.mem.endsWith(u8, archive_path, ".tar.gz") or
        std.mem.endsWith(u8, archive_path, ".tgz") or
        std.mem.endsWith(u8, archive_path, ".gz");
    const is_tar_bz2 = std.mem.endsWith(u8, archive_path, ".tar.bz2") or
        std.mem.endsWith(u8, archive_path, ".tbz2") or
        std.mem.endsWith(u8, archive_path, ".tbz") or
        std.mem.endsWith(u8, archive_path, ".bz2");
    const is_tar_xz = std.mem.endsWith(u8, archive_path, ".tar.xz") or
        std.mem.endsWith(u8, archive_path, ".txz") or
        std.mem.endsWith(u8, archive_path, ".xz");
    const is_tar = std.mem.endsWith(u8, archive_path, ".tar");

    if (is_zip) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = std.process.run(allocator, io, .{
            .argv = &.{ "unzip", "-q", archive_path, "-d", out_dir },
        }) catch |err| {
            if (err == error.FileNotFound) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'unzip' is missing but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            return err;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            if (res.term == .exited and (res.term.exited == 127 or std.mem.indexOf(u8, res.stderr, "not found") != null)) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'unzip' is missing on system PATH but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            @import("../../diagnostics/error_context.zig").setFmt(allocator, "failed to unpack zip archive {s}\nstderr: {s}", .{ archive_url, res.stderr });
            return error.UnpackError;
        }
    } else if (is_tar_gz) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xzf", archive_path, "-C", out_dir },
        }) catch |err| {
            if (err == error.FileNotFound) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            return err;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            if (res.term == .exited and (res.term.exited == 127 or std.mem.indexOf(u8, res.stderr, "not found") != null)) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing on system PATH but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            @import("../../diagnostics/error_context.zig").setFmt(allocator, "failed to unpack tar.gz archive {s}\nstderr: {s}", .{ archive_url, res.stderr });
            return error.UnpackError;
        }
    } else if (is_tar_bz2) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xjf", archive_path, "-C", out_dir },
        }) catch |err| {
            if (err == error.FileNotFound) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            return err;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            if (res.term == .exited and (res.term.exited == 127 or std.mem.indexOf(u8, res.stderr, "not found") != null)) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing on system PATH but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            @import("../../diagnostics/error_context.zig").setFmt(allocator, "failed to unpack tar.bz2 archive {s}\nstderr: {s}", .{ archive_url, res.stderr });
            return error.UnpackError;
        }
    } else if (is_tar_xz) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xJf", archive_path, "-C", out_dir },
        }) catch |err| {
            if (err == error.FileNotFound) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            return err;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            if (res.term == .exited and (res.term.exited == 127 or std.mem.indexOf(u8, res.stderr, "not found") != null)) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing on system PATH but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            @import("../../diagnostics/error_context.zig").setFmt(allocator, "failed to unpack tar.xz archive {s}\nstderr: {s}", .{ archive_url, res.stderr });
            return error.UnpackError;
        }
    } else if (is_tar) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xf", archive_path, "-C", out_dir },
        }) catch |err| {
            if (err == error.FileNotFound) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            return err;
        };
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            if (res.term == .exited and (res.term.exited == 127 or std.mem.indexOf(u8, res.stderr, "not found") != null)) {
                @import("../../diagnostics/error_context.zig").setFmt(allocator, "system utility 'tar' is missing on system PATH but required to unpack LuaRocks archive: {s}", .{archive_url});
                return error.SystemUtilityMissing;
            }
            @import("../../diagnostics/error_context.zig").setFmt(allocator, "failed to unpack tar archive {s}\nstderr: {s}", .{ archive_url, res.stderr });
            return error.UnpackError;
        }
    } else {
        const ext = std.fs.path.extension(archive_url);
        @import("../../diagnostics/error_context.zig").setFmt(allocator, "unsupported archive format while unpacking LuaRocks package {s}@{s}\narchive: {s}\ndetected extension: {s}", .{ package_name, package_version, archive_url, if (ext.len > 0) ext else "<none>" });
        return error.UnsupportedArchiveFormat;
    }
}

fn archive_suffix(url: []const u8) []const u8 {
    inline for (.{ ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz", ".zip", ".tar", ".gz", ".bz2", ".xz" }) |suffix| {
        if (std.mem.endsWith(u8, url, suffix)) return suffix;
    }
    return std.fs.path.extension(url);
}

fn compute_dir_hash(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const raw = try hash.artifact_hash(allocator, io, dir);
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{raw});
}

pub fn find_runtime_lua_executable(allocator: std.mem.Allocator, io: std.Io, runtime_path: []const u8, env_map: ?*std.process.Environ.Map) ![]const u8 {
    const binaries = [_][]const u8{ "lua", "luajit" };
    for (binaries) |binary| {
        const executable = try std.fs.path.join(allocator, &.{ runtime_path, "files", "bin", binary });
        std.Io.Dir.cwd().access(io, executable, .{}) catch |err| {
            allocator.free(executable);
            if (err == error.FileNotFound) continue;
            return err;
        };
        return executable;
    }
    // Fallback: search PATH for a system lua/luajit (needed when project runtime
    // is LÖVE or another engine that does not ship a CLI lua binary).
    if (env_map) |em| {
        if (em.get("PATH")) |paths| {
            var path_it = std.mem.splitScalar(u8, paths, std.fs.path.delimiter);
            while (path_it.next()) |dir| {
                if (dir.len == 0) continue;
                for (binaries) |binary| {
                    const candidate = try std.fs.path.join(allocator, &.{ dir, binary });
                    std.Io.Dir.cwd().access(io, candidate, .{}) catch |err| {
                        allocator.free(candidate);
                        if (err == error.FileNotFound) continue;
                        return err;
                    };
                    return candidate;
                }
            }
        }
    }
    return error.RuntimeRequiredForParsing;
}

fn find_source_root(allocator: std.mem.Allocator, io: std.Io, source_dir: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    var nested: ?[]const u8 = null;
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (count == 0) nested = try std.fs.path.join(allocator, &.{ source_dir, entry.name });
            count += 1;
        }
    }
    if (count == 1) return nested.?;
    if (nested) |n| allocator.free(n);
    return try allocator.dupe(u8, source_dir);
}

/// Fetch and unpack source. Tries .src.rock first, then falls back to rockspec source.url.
fn fetch_and_unpack_source(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    pkg_name: []const u8,
    version: []const u8,
    rock: *const luarocks.Rockspec,
    tmp_dir: []const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
) !FetchedSource {
    // 5a. Prefer the LuaRocks source rock when available. Many modern
    // rockspecs point source.url at git+https repositories, while LuaRocks
    // also publishes a .src.rock archive that Moonstone can fetch over HTTPS.
    const guessed_src_rock = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.src.rock", .{ base, pkg_name, version });
    defer allocator.free(guessed_src_rock);

    const source_fetch: SourceFetch = blk: {
        const src_rock_data = http_get(allocator, io, guessed_src_rock, env_map, on_event, on_event_context, null) catch |err| {
            if (err != error.HttpError and err != error.FileNotFound and err != error.UnsupportedUriScheme) return err;
            const src_url = rock_source_url(rock);
            if (src_url.len == 0) return error.SourceRockNotFound;
            var fallback_url: []const u8 = undefined;
            if (std.mem.startsWith(u8, src_url, "git://github.com/")) {
                var it = std.mem.splitSequence(u8, src_url[17..], "/");
                const user = it.next() orelse "";
                var repo = it.next() orelse "";
                if (std.mem.endsWith(u8, repo, ".git")) {
                    repo = repo[0 .. repo.len - 4];
                }
                const ref = if (rock.source.tag) |t| t else if (rock.source.branch) |b| b else "master";
                fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/archive/refs/tags/{s}.tar.gz", .{ user, repo, ref });
                if (rock.source.tag == null) {
                    allocator.free(fallback_url);
                    fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/archive/refs/heads/{s}.tar.gz", .{ user, repo, ref });
                }
            } else if (std.mem.startsWith(u8, src_url, "git+https://github.com/")) {
                var it = std.mem.splitSequence(u8, src_url[23..], "/");
                const user = it.next() orelse "";
                var repo = it.next() orelse "";
                if (std.mem.endsWith(u8, repo, ".git")) {
                    repo = repo[0 .. repo.len - 4];
                }
                const ref = if (rock.source.tag) |t| t else if (rock.source.branch) |b| b else "master";
                fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/archive/refs/tags/{s}.tar.gz", .{ user, repo, ref });
                if (rock.source.tag == null) {
                    allocator.free(fallback_url);
                    fallback_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/archive/refs/heads/{s}.tar.gz", .{ user, repo, ref });
                }
            } else {
                fallback_url = try allocator.dupe(u8, src_url);
            }
            errdefer allocator.free(fallback_url);
            const fallback_data = http_get(allocator, io, fallback_url, env_map, on_event, on_event_context, null) catch |fallback_err| {
                if (fallback_err == error.HttpError) return error.SourceRockNotFound;
                return fallback_err;
            };
            break :blk SourceFetch{ .url = fallback_url, .data = fallback_data };
        };
        break :blk SourceFetch{ .url = try allocator.dupe(u8, guessed_src_rock), .data = src_rock_data };
    };
    const url = source_fetch.url;
    defer allocator.free(url);
    const source_data = source_fetch.data;
    defer allocator.free(source_data);
    const source_hash = try blake3_prefixed(allocator, source_data);
    errdefer allocator.free(source_hash);
    const source_url = try allocator.dupe(u8, url);
    errdefer allocator.free(source_url);
    const source_kind = try allocator.dupe(u8, if (std.mem.endsWith(u8, url, ".src.rock")) "luarocks_src_rock" else "upstream_archive");
    errdefer allocator.free(source_kind);
    const source_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "source" });
    defer allocator.free(source_dir);

    // If it ends in .src.rock, it's a zip archive.
    if (std.mem.endsWith(u8, url, ".src.rock")) {
        const archive_name = try std.fmt.allocPrint(allocator, "{s}-{s}.src.rock", .{ pkg_name, version });
        defer allocator.free(archive_name);
        const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir, archive_name });
        defer allocator.free(archive_path);
        const f = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        try f.writeStreamingAll(io, source_data);
        f.close(io);

        const unpack_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "unpack" });
        defer allocator.free(unpack_dir);
        try std.Io.Dir.cwd().createDirPath(io, unpack_dir);

        try unpack_archive(allocator, io, pkg_name, version, url, archive_path, unpack_dir);

        // Find the actual source tarball inside the src.rock
        var up_dir = try std.Io.Dir.cwd().openDir(io, unpack_dir, .{ .iterate = true });
        defer up_dir.close(io);
        var up_it = up_dir.iterate();
        var source_tarball_path: ?[]const u8 = null;
        while (try up_it.next(io)) |entry| {
            if (entry.kind == .file) {
                const name = entry.name;
                if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz") or std.mem.endsWith(u8, name, ".tar.bz2") or std.mem.endsWith(u8, name, ".tbz2") or std.mem.endsWith(u8, name, ".tbz") or std.mem.endsWith(u8, name, ".tar.xz") or std.mem.endsWith(u8, name, ".txz") or std.mem.endsWith(u8, name, ".zip") or std.mem.endsWith(u8, name, ".tar")) {
                    source_tarball_path = try std.fs.path.join(allocator, &.{ unpack_dir, name });
                    break;
                }
            }
        }
        const payload_path = try allocator.dupe(u8, archive_path);
        errdefer allocator.free(payload_path);
        const tarball = source_tarball_path orelse return .{
            .path = try find_source_root(allocator, io, unpack_dir),
            .url = source_url,
            .hash = source_hash,
            .kind = source_kind,
            .payload_path = payload_path,
        };

        try std.Io.Dir.cwd().createDirPath(io, source_dir);
        try unpack_archive(allocator, io, pkg_name, version, tarball, tarball, source_dir);
        return .{
            .path = try find_source_root(allocator, io, source_dir),
            .url = source_url,
            .hash = source_hash,
            .kind = source_kind,
            .payload_path = payload_path,
        };
    } else {
        // Direct archive download
        const suffix = archive_suffix(url);
        const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}{s}", .{ tmp_dir, pkg_name, version, suffix });
        defer allocator.free(archive_path);
        const f = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        try f.writeStreamingAll(io, source_data);
        f.close(io);

        try std.Io.Dir.cwd().createDirPath(io, source_dir);
        try unpack_archive(allocator, io, pkg_name, version, url, archive_path, source_dir);
        return .{
            .path = try find_source_root(allocator, io, source_dir),
            .url = source_url,
            .hash = source_hash,
            .kind = source_kind,
            .payload_path = try allocator.dupe(u8, archive_path),
        };
    }
}

// ---------------------------------------------------------------------------
// Phase 6 — Translate to Moonstone recipe
// ---------------------------------------------------------------------------

fn build_c_module_list(
    allocator: std.mem.Allocator,
    translated: []const TranslatedModule,
) ![]manifest.FeatureProvision {
    var list = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (list.items) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        list.deinit(allocator);
    }
    for (translated) |mod| {
        if (mod.kind != .c) continue;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, mod.name),
            .path = try allocator.dupe(u8, mod.dest_path),
        });
    }
    return try list.toOwnedSlice(allocator);
}

fn discover_modules_from_dir(allocator: std.mem.Allocator, io: std.Io, root_dir: []const u8, prefix: []const u8, ext: []const u8) ![]manifest.FeatureProvision {
    var list = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (list.items) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        list.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, root_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return try list.toOwnedSlice(allocator);
        return err;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ext)) continue;

        var name_buf = std.ArrayList(u8).empty;
        defer name_buf.deinit(allocator);
        const without_ext = entry.path[0 .. entry.path.len - ext.len];
        for (without_ext) |c| {
            if (c == '/') try name_buf.append(allocator, '.') else try name_buf.append(allocator, c);
        }

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, name_buf.items),
            .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.path }),
        });
    }

    return try list.toOwnedSlice(allocator);
}

fn build_lua_module_list_from_translated(
    allocator: std.mem.Allocator,
    translated: []const TranslatedModule,
) ![]manifest.FeatureProvision {
    var list = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (list.items) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        list.deinit(allocator);
    }
    for (translated) |mod| {
        if (mod.kind != .lua) continue;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, mod.name),
            .path = try allocator.dupe(u8, mod.dest_path),
        });
    }
    return try list.toOwnedSlice(allocator);
}

fn copy_bins(
    allocator: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
    files_bin_dir: []const u8,
    bins_val: ?std.json.Value,
) !void {
    const bins = bins_val orelse return;

    if (bins == .object) {
        var it = bins.object.iterator();
        while (it.next()) |entry| {
            const bin_name = entry.key_ptr.*;
            const src_rel = entry.value_ptr.string;
            try copy_single_bin(allocator, io, work_dir, files_bin_dir, bin_name, src_rel);
        }
    } else if (bins == .array) {
        for (bins.array.items) |v| {
            const src_rel = v.string;
            const bin_name = std.fs.path.basename(src_rel);
            try copy_single_bin(allocator, io, work_dir, files_bin_dir, bin_name, src_rel);
        }
    }
}

fn copy_single_bin(
    allocator: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
    files_bin_dir: []const u8,
    bin_name: []const u8,
    src_rel: []const u8,
) !void {
    const src_abs = try std.fs.path.join(allocator, &.{ work_dir, src_rel });
    defer allocator.free(src_abs);

    const dest_abs = try std.fs.path.join(allocator, &.{ files_bin_dir, bin_name });
    defer allocator.free(dest_abs);

    const cp_res = try std.process.run(allocator, io, .{
        .argv = &.{ "cp", src_abs, dest_abs },
    });
    if (cp_res.term != .exited or cp_res.term.exited != 0) return error.CopyFailed;

    // Ensure it's executable
    const chmod_res = try std.process.run(allocator, io, .{
        .argv = &.{ "chmod", "+x", dest_abs },
    });
    if (chmod_res.term != .exited or chmod_res.term.exited != 0) return error.ChmodFailed;
}

fn build_bin_list(
    allocator: std.mem.Allocator,
    bins_val: ?std.json.Value,
) ![]manifest.FeatureProvision {
    var list = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (list.items) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        list.deinit(allocator);
    }
    const bins = bins_val orelse return try list.toOwnedSlice(allocator);

    if (bins == .object) {
        var it = bins.object.iterator();
        while (it.next()) |entry| {
            const bin_name = entry.key_ptr.*;
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, bin_name),
                .path = try std.fmt.allocPrint(allocator, "bin/{s}", .{bin_name}),
            });
        }
    } else if (bins == .array) {
        for (bins.array.items) |v| {
            const src_rel = v.string;
            const bin_name = std.fs.path.basename(src_rel);
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, bin_name),
                .path = try std.fmt.allocPrint(allocator, "bin/{s}", .{bin_name}),
            });
        }
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Phase 7 — Commit
// ---------------------------------------------------------------------------

fn commit_synthetic_artifact(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    build_out_dir: []const u8,
    pkg_name: []const u8,
    pkg_version: []const u8,
    pkg_kind: manifest.Kind,
    runtime_spec: []const u8,
    runtime_artifact_hash: []const u8,
    target: []const u8,
    source_hash: []const u8,
    source_url: []const u8,
    source_kind: []const u8,
    source_payload_path: ?[]const u8,
    rockspec_url: []const u8,
    rockspec_hash: []const u8,
    rockspec_payload_path: ?[]const u8,
    materializer: []const u8,
    lua_modules: []manifest.FeatureProvision,
    lua_cmodules: []manifest.FeatureProvision,
    bins: []manifest.FeatureProvision,
    dependencies: []const manifest.StoreDependency,
    build_env: []const manifest.EnvPair,
) !RockResult {
    var build_env_strings = std.ArrayList([]const u8).empty;
    defer {
        for (build_env_strings.items) |s| allocator.free(s);
        build_env_strings.deinit(allocator);
    }
    for (build_env) |be| {
        const str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ be.key, be.value });
        try build_env_strings.append(allocator, str);
    }

    const recipe_hash = try store.computeRecipeHash(allocator, .{
        .kind = if (pkg_kind == .bin) "bin" else "lib",
        .name = pkg_name,
        .version = pkg_version,
        .source_hash = source_hash,
        .materializer = materializer,
        .strategy = "rocks",
        .runtime_hash = runtime_artifact_hash,
        .lua_abi = runtime_spec,
        .target = target,
        .build_env = build_env_strings.items,
        .collect = .{
            .lua_modules = lua_modules,
            .lua_cmodules = lua_cmodules,
            .bins = bins,
        },
    });
    const art_hash = try compute_dir_hash(allocator, io, build_out_dir);
    defer allocator.free(art_hash);

    const pkg_name_dup = try allocator.dupe(u8, pkg_name);
    errdefer allocator.free(pkg_name_dup);
    const pkg_ver_dup = try allocator.dupe(u8, pkg_version);
    errdefer allocator.free(pkg_ver_dup);
    const art_hash_dup = try allocator.dupe(u8, art_hash);
    errdefer allocator.free(art_hash_dup);
    const recipe_hash_dup = try allocator.dupe(u8, recipe_hash);
    errdefer allocator.free(recipe_hash_dup);
    const runtime_dup = try allocator.dupe(u8, runtime_spec);
    errdefer allocator.free(runtime_dup);

    var runtimes = try allocator.alloc([]const u8, 1);
    runtimes[0] = runtime_dup;

    // Build store dependencies copy
    var deps_copy = try allocator.alloc(manifest.StoreDependency, dependencies.len);
    for (dependencies, 0..) |dep, i| {
        deps_copy[i] = .{
            .name = try allocator.dupe(u8, dep.name),
            .constraint = try allocator.dupe(u8, dep.constraint),
            .resolver = if (dep.resolver) |r| try allocator.dupe(u8, r) else null,
            .role = dep.role,
            .optional = dep.optional,
        };
    }

    const synthetic_desc = manifest.RemotePackageDescriptor{
        .package = .{
            .name = pkg_name_dup,
            .version = pkg_ver_dup,
            .kind = pkg_kind,
            .description = null,
        },
        .compat = .{
            .runtimes = runtimes,
        },
        .artifact = &[_]manifest.RemoteArtifact{
            .{
                .target = target,
                .lua_abi = runtime_spec,
                .runtime_artifact_hash = runtime_artifact_hash,
                .url = "",
                .hash = art_hash_dup,
                .source_hash = source_hash,
                .format = "directory",
                .recipe_hash = recipe_hash_dup,
                .provides = .{
                    .runtime = &.{},
                    .bin = bins,
                    .headers = &.{},
                    .native_lib = &.{},
                    .lua_module = lua_modules,
                    .lua_cmodule = lua_cmodules,
                },
            },
        },
        .source = null,
    };
    defer {
        allocator.free(synthetic_desc.package.name);
        allocator.free(synthetic_desc.package.version);
        for (synthetic_desc.compat.runtimes) |r| allocator.free(r);
        allocator.free(synthetic_desc.compat.runtimes);
        allocator.free(synthetic_desc.artifact[0].hash);
        allocator.free(synthetic_desc.artifact[0].recipe_hash);
        for (deps_copy) |*d| d.deinit(allocator);
        allocator.free(deps_copy);
    }

    const source_str = try allocator.dupe(u8, source_url);
    defer allocator.free(source_str);

    const store_path = try store.commit_to_store_with_sources(allocator, io, env_map, build_out_dir, synthetic_desc, synthetic_desc.artifact[0], "rocks", source_str, deps_copy, .{
        .source_kind = source_kind,
        .source_payload_path = source_payload_path,
        .rockspec = rockspec_url,
        .rockspec_hash = rockspec_hash,
        .rockspec_payload_path = rockspec_payload_path,
    });

    return RockResult{ .path = store_path, .hash = try allocator.dupe(u8, art_hash), .recipe_hash = try allocator.dupe(u8, recipe_hash) };
}

// ---------------------------------------------------------------------------
// Public resolve entrypoint
// ---------------------------------------------------------------------------

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version_range: []const u8,
    options: options_mod.ResolveOptions,
    env_map: *std.process.Environ.Map,
    base_override: ?[]const u8,
    registry_name: ?[]const u8,
) !candidate_mod.Candidate {
    if (options.offline) return error.PackageNotFound;

    const runtime_spec = options.runtime orelse "lua54";

    const base = base_override orelse get_luarocks_base(env_map);

    // Phase 1: Candidate discovery
    const manifest_parsed = try fetch_manifest(allocator, io, base, options.runtime, env_map, options.on_event, options.on_event_context, options.offline);
    defer manifest_parsed.deinit();
    const manifest_json = manifest_parsed.value;

    const version = try select_version(allocator, manifest_json, pkg_name, version_range);
    defer allocator.free(version);

    // Phase 2: Prefer binary rock if safe
    if (try host_to_luarocks_arch(allocator)) |arch_str| {
        defer allocator.free(arch_str);
        if (has_binary_rock(manifest_json, pkg_name, version, arch_str)) {
            const bin_res = blk: {
                break :blk resolve_binary_rock(allocator, io, pkg_name, version, runtime_spec, options.runtime_artifact_hash orelse "", options.target orelse "native", env_map, options.on_event, options.on_event_context) catch |err| {
                    if (err == error.FileNotFound or err == error.HttpError) break :blk null;
                    if (err != error.BinaryRockNotImplemented) return err;
                    break :blk null;
                };
            };
            if (bin_res) |res| {
                defer allocator.free(res.path);
                defer allocator.free(res.recipe_hash);
                defer allocator.free(res.source_hash);
                defer allocator.free(res.source_url);
                return candidate_mod.Candidate{
                    .name = try allocator.dupe(u8, pkg_name),
                    .version = try allocator.dupe(u8, version),
                    .kind = .lib,
                    .artifact_hash = res.hash,
                    .source = try allocator.dupe(u8, res.source_url),
                    .source_hash = try allocator.dupe(u8, res.source_hash),
                    .recipe_hash = try allocator.dupe(u8, res.recipe_hash),
                    .runtime_artifact_hash = if (options.runtime_artifact_hash) |rah| try allocator.dupe(u8, rah) else try allocator.dupe(u8, ""),
                    .registry_name = try allocator.dupe(u8, registry_name orelse "rocks"),
                    .local_path = try allocator.dupe(u8, res.path),
                    .origin = .{ .luarocks = .{ .url = try allocator.dupe(u8, base), .rockspec_path = try allocator.dupe(u8, "") } },
                };
            }
        }
    }

    // Phase 3: Fetch rockspec
    const fetched_rockspec = try fetch_rockspec(allocator, io, base, pkg_name, version, env_map, options.on_event, options.on_event_context);
    defer fetched_rockspec.deinit(allocator);

    // Phase 4: Classify
    const lua_exe = blk: {
        if (options.lua_exe) |exe| {
            break :blk try allocator.dupe(u8, exe);
        }
        const rt_path = options.runtime_path orelse return error.RuntimeRequiredForParsing;
        break :blk try find_runtime_lua_executable(allocator, io, rt_path, env_map);
    };
    defer allocator.free(lua_exe);

    var rock_parsed = try luarocks.parse_rockspec(allocator, io, fetched_rockspec.content, lua_exe);
    defer rock_parsed.deinit();
    const rock = rock_parsed.value;

    const rock_class = classify_rock(&rock);
    switch (rock_class) {
        .pure_lua, .builtin_cmodule, .command_build => {}, // Continue below
        .unsupported => {
            return error.UnsupportedLuaRocksBuildType;
        },
        .binary_rock => unreachable, // Should have been handled in Phase 2
    }

    // Phase 5: Source fetch
    const paths = try fs.resolve_moonstone(allocator, env_map, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    const tmp_dir_name = try std.fmt.allocPrint(allocator, "rocks-{s}-{s}", .{ pkg_name, version });
    defer allocator.free(tmp_dir_name);
    const tmp_dir = try std.fs.path.join(allocator, &.{ paths.tmp, tmp_dir_name });
    defer allocator.free(tmp_dir);

    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    const rockspec_payload_name = try std.fmt.allocPrint(allocator, "{s}-{s}.rockspec", .{ pkg_name, version });
    defer allocator.free(rockspec_payload_name);
    const rockspec_payload_path = try std.fs.path.join(allocator, &.{ tmp_dir, rockspec_payload_name });
    defer allocator.free(rockspec_payload_path);
    const rockspec_file = try std.Io.Dir.cwd().createFile(io, rockspec_payload_path, .{});
    try rockspec_file.writeStreamingAll(io, fetched_rockspec.content);
    rockspec_file.close(io);

    const fetched_source = fetch_and_unpack_source(allocator, io, base, pkg_name, version, &rock, tmp_dir, env_map, options.on_event, options.on_event_context) catch |err| {
        return err;
    };
    defer fetched_source.deinit(allocator);
    const work_dir = fetched_source.path;
    const compatibility_recipe = try luarocks_compat.apply(allocator, io, pkg_name, options.runtime_c_api, work_dir);

    // Phase 6: Translate to Moonstone recipe
    const build_out_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "out" });
    defer allocator.free(build_out_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_out_dir);

    var translated = if (rock_class == .command_build)
        try translateCommandBuild(allocator, &rock, runtime_spec)
    else
        try translateBuiltinBuild(allocator, &rock, runtime_spec);

    if (options.build_env.len > 0) {
        // translated is []TranslatedModule
        // we need to inject the build env into each module's config
        var updated_translated = std.ArrayList(TranslatedModule).empty;
        for (translated) |m| {
            var mut_m = m;
            if (mut_m.config) |*c| {
                var new_env = std.ArrayList(manifest.EnvPair).empty;
                for (c.env) |e| try new_env.append(allocator, .{ .key = try allocator.dupe(u8, e.key), .value = try allocator.dupe(u8, e.value) });
                for (options.build_env) |be| try new_env.append(allocator, .{ .key = try allocator.dupe(u8, be.key), .value = try allocator.dupe(u8, be.value) });
                c.env = try new_env.toOwnedSlice(allocator);
            }
            try updated_translated.append(allocator, mut_m);
        }
        allocator.free(translated);
        translated = try updated_translated.toOwnedSlice(allocator);
    }
    defer {
        for (translated) |m| {
            allocator.free(m.name);
            allocator.free(m.dest_path);
            if (m.source_path) |source_path| allocator.free(source_path);
            if (m.config) |c| {
                if (c.input) |in| {
                    for (in.sources) |s| allocator.free(s);
                    allocator.free(in.sources);
                }
                if (c.output) |out| {
                    allocator.free(out.module);
                    allocator.free(out.path);
                }
                for (c.args) |a| allocator.free(a);
                allocator.free(c.args);
                for (c.ldflags) |a| allocator.free(a);
                allocator.free(c.ldflags);
            }
        }
        allocator.free(translated);
    }

    const native_cmodule = @import("../../materialization/materializers/native_cmodule.zig");
    const runtime_path = options.runtime_path orelse return error.RuntimePathRequired;

    var hash_part = fetched_source.hash;
    if (std.mem.startsWith(u8, hash_part, "b3:")) {
        hash_part = hash_part[3..];
    }
    const hash_short_len = @min(8, hash_part.len);
    const hash_short = hash_part[0..hash_short_len];

    for (translated) |mod| {
        if (mod.kind == .c) {
            const config = mod.config.?;
            if (std.mem.eql(u8, config.kind, "command")) {
                const command_mat = @import("../../materialization/materializers/command.zig");
                const log_file_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}.log", .{ pkg_name, version, hash_short });
                defer allocator.free(log_file_name);
                command_mat.build(allocator, io, env_map, work_dir, build_out_dir, runtime_path, runtime_spec, config, log_file_name, options.on_event, options.on_event_context) catch |err| {
                    @import("../../diagnostics/error_context.zig").setFmt(allocator, "command compilation failed for LuaRocks package {s}@{s}\nmodule: {s}\nsource: {s}\nreason: {s}", .{ pkg_name, version, mod.name, fetched_source.url, @errorName(err) });
                    return err;
                };
            } else if (std.mem.eql(u8, config.kind, "cmake")) {
                const cmake_mat = @import("../../materialization/materializers/cmake.zig");
                const log_file_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}.log", .{ pkg_name, version, hash_short });
                defer allocator.free(log_file_name);
                cmake_mat.build(allocator, io, env_map, work_dir, build_out_dir, runtime_path, runtime_spec, config, log_file_name, options.on_event, options.on_event_context) catch |err| {
                    @import("../../diagnostics/error_context.zig").setFmt(allocator, "cmake compilation failed for LuaRocks package {s}@{s}\nmodule: {s}\nsource: {s}\nreason: {s}", .{ pkg_name, version, mod.name, fetched_source.url, @errorName(err) });
                    return err;
                };
            } else {
                const log_file_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}.log", .{ pkg_name, version, hash_short });
                defer allocator.free(log_file_name);
                native_cmodule.build(allocator, io, env_map, work_dir, build_out_dir, runtime_path, options.runtime_c_api, config, options.target orelse "native", log_file_name, options.on_event, options.on_event_context) catch |err| {
                    @import("../../diagnostics/error_context.zig").setFmt(allocator, "native module compilation failed for LuaRocks package {s}@{s}\nmodule: {s}\nsource: {s}\nreason: {s}", .{ pkg_name, version, mod.name, fetched_source.url, @errorName(err) });
                    return err;
                };
            }
        } else {
            // Copy pure Lua file
            const fallback_src_rel = if (mod.source_path == null) try std.fmt.allocPrint(allocator, "{s}.lua", .{mod.name}) else null;
            defer if (fallback_src_rel) |src_rel| allocator.free(src_rel);
            const src_rel = mod.source_path orelse fallback_src_rel.?;

            const src_abs = try std.fs.path.join(allocator, &.{ work_dir, src_rel });
            defer allocator.free(src_abs);

            const dest_abs = try std.fs.path.join(allocator, &.{ build_out_dir, mod.dest_path });
            defer allocator.free(dest_abs);

            if (std.fs.path.dirname(dest_abs)) |parent| {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }

            const cp_res = try std.process.run(allocator, io, .{
                .argv = &.{ "cp", src_abs, dest_abs },
            });
            if (cp_res.term != .exited or cp_res.term.exited != 0) return error.CopyFailed;

            // Ensure it's executable
            const chmod_res = try std.process.run(allocator, io, .{
                .argv = &.{ "chmod", "+x", dest_abs },
            });
            if (chmod_res.term != .exited or chmod_res.term.exited != 0) return error.ChmodFailed;
        }
    }

    // Determine bins (copy them if they exist in rockspec)
    const files_bin_dir = try std.fs.path.join(allocator, &.{ build_out_dir, "bin" });
    defer allocator.free(files_bin_dir);
    try std.Io.Dir.cwd().createDirPath(io, files_bin_dir);

    const bin_val = if (rock.build.install) |inst| inst.bin else null;
    try copy_bins(allocator, io, work_dir, files_bin_dir, bin_val);

    var lua_modules: []manifest.FeatureProvision = &.{};
    var lua_cmodules: []manifest.FeatureProvision = &.{};

    if (rock_class == .command_build) {
        const lua_ver_dot = if (std.mem.startsWith(u8, runtime_spec, "lua") and runtime_spec.len == 5)
            try std.fmt.allocPrint(allocator, "{c}.{c}", .{ runtime_spec[3], runtime_spec[4] })
        else
            try allocator.dupe(u8, runtime_spec);
        defer allocator.free(lua_ver_dot);

        // Discover installed files dynamically
        const share_dir = try std.fs.path.join(allocator, &.{ build_out_dir, "share", "lua", lua_ver_dot });
        defer allocator.free(share_dir);
        const lib_dir = try std.fs.path.join(allocator, &.{ build_out_dir, "lib", "lua", lua_ver_dot });
        defer allocator.free(lib_dir);

        const share_prefix = try std.fmt.allocPrint(allocator, "share/lua/{s}", .{lua_ver_dot});
        defer allocator.free(share_prefix);
        const discovered_lua = try discover_modules_from_dir(allocator, io, share_dir, share_prefix, ".lua");
        lua_modules = discovered_lua;

        const lib_prefix = try std.fmt.allocPrint(allocator, "lib/lua/{s}", .{lua_ver_dot});
        defer allocator.free(lib_prefix);
        const so_ext = ".so"; // assuming .so
        const discovered_c = try discover_modules_from_dir(allocator, io, lib_dir, lib_prefix, so_ext);
        lua_cmodules = discovered_c;
    } else {
        lua_modules = try build_lua_module_list_from_translated(allocator, translated);
        lua_cmodules = try build_c_module_list(allocator, translated);
    }
    defer {
        for (lua_modules) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        allocator.free(lua_modules);
        for (lua_cmodules) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        allocator.free(lua_cmodules);
    }

    const bins = try build_bin_list(allocator, bin_val);
    defer {
        for (bins) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        allocator.free(bins);
    }

    // Determine kind: if it provides bins, it might be a .bin package
    const pkg_kind: manifest.Kind = if (bins.len > 0) .bin else .lib;

    // Translate rockspec dependencies to store dependencies
    var store_deps = std.ArrayList(manifest.StoreDependency).empty;
    if (rock.dependencies) |deps| {
        for (deps) |dep_str| {
            const parsed = try luarocks.parse_dependency_string(allocator, dep_str);
            defer parsed.deinit(allocator);
            const name_lower = try std.ascii.allocLowerString(allocator, parsed.name);
            defer allocator.free(name_lower);
            // Skip "lua" runtime dependency; compat handles that
            if (std.mem.eql(u8, name_lower, "lua")) continue;
            try store_deps.append(allocator, .{
                .name = try allocator.dupe(u8, parsed.name),
                .constraint = try allocator.dupe(u8, parsed.constraint orelse "*"),
                .resolver = try allocator.dupe(u8, "rocks"),
                .role = .runtime,
            });
        }
    }
    const store_deps_slice = try store_deps.toOwnedSlice(allocator);
    defer {
        for (store_deps_slice) |*d| d.deinit(allocator);
        allocator.free(store_deps_slice);
    }

    // Phase 7: Commit
    var recipe_build_env = std.ArrayList(manifest.EnvPair).empty;
    defer {
        for (recipe_build_env.items) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        recipe_build_env.deinit(allocator);
    }
    for (options.build_env) |entry| {
        try recipe_build_env.append(allocator, .{
            .key = try allocator.dupe(u8, entry.key),
            .value = try allocator.dupe(u8, entry.value),
        });
    }
    if (compatibility_recipe) |recipe| {
        try recipe_build_env.append(allocator, .{
            .key = try allocator.dupe(u8, recipe.key),
            .value = try allocator.dupe(u8, recipe.value),
        });
    }

    const commit_res = try commit_synthetic_artifact(
        allocator,
        io,
        env_map,
        build_out_dir,
        rock.package,
        rock.version,
        pkg_kind,
        runtime_spec,
        options.runtime_artifact_hash orelse "",
        options.target orelse "native",
        fetched_source.hash,
        fetched_source.url,
        fetched_source.kind,
        fetched_source.payload_path,
        fetched_rockspec.url,
        fetched_rockspec.hash,
        rockspec_payload_path,
        "rocks-builtin",
        lua_modules,
        lua_cmodules,
        bins,
        store_deps_slice,
        recipe_build_env.items,
    );
    defer allocator.free(commit_res.path);
    defer allocator.free(commit_res.hash);
    defer allocator.free(commit_res.recipe_hash);

    return candidate_mod.Candidate{
        .name = try allocator.dupe(u8, rock.package),
        .version = try allocator.dupe(u8, rock.version),
        .kind = pkg_kind,
        .artifact_hash = try allocator.dupe(u8, commit_res.hash),
        .source = try allocator.dupe(u8, fetched_source.url),
        .source_hash = try allocator.dupe(u8, fetched_source.hash),
        .rockspec = try allocator.dupe(u8, fetched_rockspec.url),
        .rockspec_hash = try allocator.dupe(u8, fetched_rockspec.hash),
        .recipe_hash = try allocator.dupe(u8, commit_res.recipe_hash),
        .runtime_artifact_hash = if (options.runtime_artifact_hash) |rah| try allocator.dupe(u8, rah) else try allocator.dupe(u8, ""),
        .registry_name = try allocator.dupe(u8, "rocks"),
        .local_path = try allocator.dupe(u8, commit_res.path),
        .origin = .{ .luarocks = .{ .url = try allocator.dupe(u8, base), .rockspec_path = try allocator.dupe(u8, "") } },
    };
}
