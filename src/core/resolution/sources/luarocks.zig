const std = @import("std");
const target_builtin = @import("builtin");
const manifest = @import("../../domain/manifest.zig");
const fs = @import("../../platform/fs.zig");
const http = @import("../../platform/http.zig");
const platform_target = @import("../../platform/target.zig");
const store = @import("../../store.zig");
const driver_mod = @import("../../store/driver.zig");
const hash = @import("../../identity/hash.zig");
const luarocks = @import("../../luarocks/rockspec.zig");
const luarocks_compat = @import("../../luarocks/compat.zig");
const luarocks_patch = @import("../../luarocks/patch.zig");
const manifest_cache_mod = @import("../../cache/manifest_cache.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");
const cmake_mat = @import("../../materialization/materializers/cmake.zig");

const profiler = @import("../../diagnostics/profiler.zig");

var manifest_cache: std.StringHashMapUnmanaged([]u8) = .empty;
var manifest_cache_mutex: std.Io.Mutex = .init;
var materialization_workspace_counter: std.atomic.Value(u64) = .init(0);

fn getCachedManifest(io: std.Io, url: []const u8) ?[]u8 {
    manifest_cache_mutex.lockUncancelable(io);
    defer manifest_cache_mutex.unlock(io);
    return manifest_cache.get(url);
}

fn adoptCachedManifest(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []u8) ![]u8 {
    manifest_cache_mutex.lockUncancelable(io);
    defer manifest_cache_mutex.unlock(io);

    if (manifest_cache.get(url)) |cached| {
        allocator.free(body);
        return cached;
    }

    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);
    try manifest_cache.put(allocator, owned_url, body);
    return body;
}

test "LuaRocks manifest cache serializes concurrent inserts" {
    const Worker = struct {
        const Context = struct {
            url: []const u8,
            completed: *std.atomic.Value(usize),
        };

        fn run(context: *Context) void {
            const body = std.heap.page_allocator.dupe(u8, "concurrent manifest body") catch @panic("out of memory");
            _ = adoptCachedManifest(std.heap.page_allocator, std.testing.io, context.url, body) catch @panic("manifest cache insert failed");
            _ = context.completed.fetchAdd(1, .monotonic);
        }
    };

    const url = "https://moonstone.invalid/tests/manifest-cache-concurrent-insert";
    var completed = std.atomic.Value(usize).init(0);
    var context = Worker.Context{ .url = url, .completed = &completed };
    var threads: [16]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&context});
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, threads.len), completed.load(.monotonic));
    try std.testing.expectEqualStrings("concurrent manifest body", getCachedManifest(std.testing.io, url).?);
}

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
    cancellation_flag: ?*const std.atomic.Value(bool),
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

    const resp = try http.fetchGetWithProgress(allocator, io, url, null, timeout_ms, pcb, if (pctx) |*p| p else null, cancellation_flag);
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
    cancellation_flag: ?*const std.atomic.Value(bool),
) ![]u8 {
    const net_cfg = fs.get_network_config(allocator, env_map, io);
    const http_cfg = http.get_http_config(allocator, env_map, io);

    const max_retries = net_cfg.retries;
    const delay_seconds = net_cfg.retry_delay;

    var attempt: u32 = 0;
    while (true) {
        if (if (cancellation_flag) |flag| flag.load(.acquire) else false) return error.Cancelled;
        if (http_get_single(allocator, io, url, http_cfg.timeout_ms, on_event, on_event_context, progress_label, cancellation_flag)) |data| {
            return data;
        } else |err| {
            if (err == error.Cancelled) return err;
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
            if (if (cancellation_flag) |flag| flag.load(.acquire) else false) return error.Cancelled;
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

/// Platform-normalized dependency declarations from one selected rockspec.
/// This is intentionally metadata-only: it fetches and validates the rockspec
/// but never fetches sources, invokes a materializer, writes the CAS, or
/// registers an artifact. Build dependencies remain role-distinct so PubGrub
/// can construct their closure without promoting them into runtime edges.
pub const RockspecDependencies = struct {
    runtime: []const []const u8,
    build: []const []const u8,

    pub fn deinit(self: *RockspecDependencies, allocator: std.mem.Allocator) void {
        for (self.runtime) |dependency| allocator.free(dependency);
        allocator.free(self.runtime);
        for (self.build) |dependency| allocator.free(dependency);
        allocator.free(self.build);
        self.* = undefined;
    }
};

pub fn query_dependencies(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version: []const u8,
    options: options_mod.ResolveOptions,
    env_map: *std.process.Environ.Map,
    base_override: ?[]const u8,
) !RockspecDependencies {
    if (options.offline) return error.PackageNotFound;

    const base = base_override orelse get_luarocks_base(env_map);
    const fetched_rockspec = try fetch_rockspec(allocator, io, base, pkg_name, version, env_map, options.on_event, options.on_event_context, options.cancellation_flag);
    defer fetched_rockspec.deinit(allocator);

    const lua_exe = blk: {
        if (options.lua_exe) |exe| break :blk try allocator.dupe(u8, exe);
        const runtime_path = options.runtime_path orelse return error.RuntimeRequiredForParsing;
        break :blk try find_runtime_lua_executable(allocator, io, runtime_path, env_map);
    };
    defer allocator.free(lua_exe);

    const paths = try fs.resolve_moonstone(allocator, env_map, io);
    defer {
        var mutable_paths = paths;
        mutable_paths.deinit(allocator);
    }

    var rock_parsed = try luarocks.parse_rockspec_for_target(allocator, io, fetched_rockspec.content, lua_exe, paths.tmp, options.target);
    defer rock_parsed.deinit();

    const runtime = try duplicateDependencyList(allocator, rock_parsed.value.intent.dependencies);
    errdefer freeDependencyList(allocator, runtime);
    const build = try duplicateDependencyList(allocator, rock_parsed.value.intent.build_dependencies);
    return .{ .runtime = runtime, .build = build };
}

fn duplicateDependencyList(allocator: std.mem.Allocator, dependencies: []const []const u8) ![]const []const u8 {
    var result = try allocator.alloc([]const u8, dependencies.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |dependency| allocator.free(dependency);
        allocator.free(result);
    }
    for (dependencies, 0..) |dependency, index| {
        result[index] = try allocator.dupe(u8, dependency);
        initialized += 1;
    }
    return result;
}

fn freeDependencyList(allocator: std.mem.Allocator, dependencies: []const []const u8) void {
    for (dependencies) |dependency| allocator.free(dependency);
    allocator.free(dependencies);
}

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
    /// `source.md5` in a rockspec describes the bytes at `source.url`. A
    /// preferred LuaRocks `.src.rock` is normally a separate distribution
    /// artifact, unless the rockspec declared that exact URL itself.
    is_declared_source: bool,
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
    cancellation_flag: ?*const std.atomic.Value(bool),
) !std.json.Parsed(std.json.Value) {
    const url = try runtime_to_manifest_url(allocator, base, runtime);
    defer allocator.free(url);
    const body = blk: {
        if (getCachedManifest(io, url)) |cached| {
            profiler.mark("luarocks.manifest.cache_hit");
            break :blk cached;
        }
        if (try read_persistent_manifest_cache(allocator, io, env_map, url, allow_stale_cache)) |cached| {
            profiler.mark("luarocks.manifest.disk_cache_hit");
            errdefer allocator.free(cached);
            break :blk try adoptCachedManifest(allocator, io, url, cached);
        }
        const span = profiler.now();
        if (on_event) |cb| cb(on_event_context, .{ .metadata_sync_started = "Syncing LuaRocks manifest" });
        const fetched = http_get(allocator, io, url, env_map, on_event, on_event_context, "Syncing LuaRocks manifest", cancellation_flag) catch |err| {
            if (err == error.Cancelled) return err;
            // TODO: handle err
            std.debug.print("luarocks source error: {s}\n", .{@errorName(err)});
            return error.RocksVersionDiscoveryFailed;
        };
        if (on_event) |cb| cb(on_event_context, .{ .metadata_sync_done = "LuaRocks manifest synced" });
        profiler.span("luarocks.manifest.fetch", span);
        errdefer allocator.free(fetched);
        write_persistent_manifest_cache(allocator, io, env_map, url, fetched);
        break :blk try adoptCachedManifest(allocator, io, url, fetched);
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

fn rock_build_type(rock: *const luarocks.RockspecIntent) []const u8 {
    return rock.build.type orelse "builtin";
}

/// LuaRocks installs modules below a `major.minor` directory, while Moonstone's
/// runtime identity also accepts ABI-oriented spellings such as `lua54` and
/// `lua-5.4`. Keep command-backend installation and output discovery on the
/// same filesystem spelling.
fn lua_module_directory_version(allocator: std.mem.Allocator, runtime: []const u8) ![]const u8 {
    if (runtime.len == 3 and runtime[1] == '.') return try allocator.dupe(u8, runtime);
    if (runtime.len == 5 and std.mem.startsWith(u8, runtime, "lua") and std.ascii.isDigit(runtime[3]) and std.ascii.isDigit(runtime[4])) {
        return try std.fmt.allocPrint(allocator, "{c}.{c}", .{ runtime[3], runtime[4] });
    }
    if (runtime.len == 7 and std.mem.startsWith(u8, runtime, "lua-") and runtime[4] == '.' and std.ascii.isDigit(runtime[3]) and std.ascii.isDigit(runtime[5])) {
        return try allocator.dupe(u8, runtime[3..]);
    }
    return try allocator.dupe(u8, runtime);
}

test "LuaRocks module directories use major.minor Lua version spelling" {
    const allocator = std.testing.allocator;

    const lua54 = try lua_module_directory_version(allocator, "lua54");
    defer allocator.free(lua54);
    try std.testing.expectEqualStrings("5.4", lua54);

    const dashed = try lua_module_directory_version(allocator, "lua-5.3");
    defer allocator.free(dashed);
    try std.testing.expectEqualStrings("5.3", dashed);

    const dotted = try lua_module_directory_version(allocator, "5.2");
    defer allocator.free(dotted);
    try std.testing.expectEqualStrings("5.2", dotted);
}

fn rock_source_url(rock: *const luarocks.RockspecIntent) []const u8 {
    return rock.source.url orelse "";
}

fn stable_source_build_workspace_name(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    version: []const u8,
    source_hash: []const u8,
    rockspec_hash: []const u8,
    runtime: []const u8,
    target: []const u8,
    build_env: []const manifest.EnvPair,
) ![]const u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    const fields = [_][]const u8{ pkg_name, version, source_hash, rockspec_hash, runtime, target };
    for (fields) |field| {
        hasher.update(field);
        hasher.update("\x00");
    }
    for (build_env) |entry| {
        hasher.update(entry.key);
        hasher.update("=");
        hasher.update(entry.value);
        hasher.update("\x00");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(allocator, "rocks-build-{s}", .{hex[0..20]});
}

fn source_fallback_url(
    allocator: std.mem.Allocator,
    source_url: []const u8,
    tag: ?[]const u8,
    branch: ?[]const u8,
) ![]u8 {
    const repository_path = blk: {
        if (std.mem.startsWith(u8, source_url, "git://github.com/")) {
            break :blk source_url[17..];
        }
        if (std.mem.startsWith(u8, source_url, "git+https://github.com/")) {
            break :blk source_url[23..];
        }
        return allocator.dupe(u8, source_url);
    };

    var segments = std.mem.splitSequence(u8, repository_path, "/");
    const owner = segments.next() orelse "";
    var repository = segments.next() orelse "";
    if (std.mem.endsWith(u8, repository, ".git")) {
        repository = repository[0 .. repository.len - 4];
    }

    const ref = tag orelse branch orelse "master";
    const ref_kind = if (tag != null) "tags" else "heads";
    return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/archive/refs/{s}/{s}.tar.gz", .{
        owner,
        repository,
        ref_kind,
        ref,
    });
}

test "LuaRocks source fallback maps GitHub VCS tags to archive URLs" {
    const url = try source_fallback_url(std.testing.allocator, "git://github.com/moonstone/example.git", "v1.2.3", "main");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://github.com/moonstone/example/archive/refs/tags/v1.2.3.tar.gz", url);
}

test "LuaRocks source fallback maps GitHub VCS branches to archive URLs" {
    const url = try source_fallback_url(std.testing.allocator, "git+https://github.com/moonstone/example.git", null, "main");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://github.com/moonstone/example/archive/refs/heads/main.tar.gz", url);
}

test "LuaRocks source fallback leaves non-GitHub sources unchanged" {
    const source_url = "https://example.test/example-1.2.3.tar.gz";
    const url = try source_fallback_url(std.testing.allocator, source_url, null, null);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(source_url, url);
}

fn supports_selected_platform(rock: *const luarocks.RockspecIntent) bool {
    if (rock.supported_platforms.len == 0) return true;
    for (rock.supported_platforms) |platform| {
        if (std.mem.eql(u8, platform, rock.platform)) return true;
        if (std.mem.eql(u8, platform, "unix") and !std.mem.eql(u8, rock.platform, "win32")) return true;
    }
    return false;
}

fn verify_source_md5(expected: ?[]const u8, source_data: []const u8) !void {
    const value = expected orelse return;
    if (value.len != 32) return error.InvalidLuaRocksSourceMd5;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidLuaRocksSourceMd5;

    const digest = std.crypto.hash.Md5.hashResult(source_data);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(value, &actual)) return error.LuaRocksSourceMd5Mismatch;
}

fn verify_declared_source_md5(source_fetch: SourceFetch, expected: ?[]const u8) !void {
    if (!source_fetch.is_declared_source) return;
    try verify_source_md5(expected, source_fetch.data);
}

test "LuaRocks source md5 validates only the declared source payload" {
    var bytes = [_]u8{ 'a', 'b', 'c' };
    const matching_md5 = "900150983cd24fb0d6963f7d28e17f72";
    const mismatching_md5 = "00000000000000000000000000000000";

    try verify_declared_source_md5(.{
        .url = "https://example.test/source.tar.gz",
        .data = &bytes,
        .is_declared_source = true,
    }, matching_md5);
    try std.testing.expectError(error.LuaRocksSourceMd5Mismatch, verify_declared_source_md5(.{
        .url = "https://example.test/source.tar.gz",
        .data = &bytes,
        .is_declared_source = true,
    }, mismatching_md5));
    try verify_declared_source_md5(.{
        .url = "https://example.test/package-1.0-1.src.rock",
        .data = &bytes,
        .is_declared_source = false,
    }, mismatching_md5);
    try std.testing.expectError(error.LuaRocksSourceMd5Mismatch, verify_declared_source_md5(.{
        .url = "https://example.test/package-1.0-1.src.rock",
        .data = &bytes,
        .is_declared_source = true,
    }, mismatching_md5));
}

fn translateCommandBuild(
    allocator: std.mem.Allocator,
    rock: *const luarocks.RockspecIntent,
    env_map: *const std.process.Environ.Map,
) ![]const TranslatedModule {
    const build_type = rock_build_type(rock);
    const is_cmake = std.mem.eql(u8, build_type, "cmake");
    const is_command = std.mem.eql(u8, build_type, "command");
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
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "PREFIX"), .value = try allocator.dupe(u8, "${out}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUADIR"), .value = try allocator.dupe(u8, "${out}/share/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LIBDIR"), .value = try allocator.dupe(u8, "${out}/lib/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "BINDIR"), .value = try allocator.dupe(u8, "${out}/bin") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUA_INCDIR"), .value = try allocator.dupe(u8, "${runtime.include}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUA_LIBDIR"), .value = try allocator.dupe(u8, "${runtime.lib}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUALIB"), .value = try allocator.dupe(u8, "${runtime.lualib}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUA_BINDIR"), .value = try allocator.dupe(u8, "${runtime.bin_dir}") });

        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "PREFIX"), .value = try allocator.dupe(u8, "${out}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "prefix"), .value = try allocator.dupe(u8, "") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "INST_LIBDIR"), .value = try allocator.dupe(u8, "${out}/lib/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "INST_LUADIR"), .value = try allocator.dupe(u8, "${out}/share/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LUADIR"), .value = try allocator.dupe(u8, "${out}/share/lua/${lua_abi}") });
        try env_pairs.append(allocator, .{ .key = try allocator.dupe(u8, "LIBDIR"), .value = try allocator.dupe(u8, "${out}/lib/lua/${lua_abi}") });

        if (is_command) {
            const build_command = rock.build.build_command orelse return error.MissingLuaRocksBuildCommand;
            const install_command = rock.build.install_command orelse return error.MissingLuaRocksInstallCommand;
            const expanded_build_command = try expand_luarocks_command_value(allocator, build_command, env_map);
            defer allocator.free(expanded_build_command);
            const expanded_install_command = try expand_luarocks_command_value(allocator, install_command, env_map);
            defer allocator.free(expanded_install_command);
            try append_host_shell_step(allocator, &steps, expanded_build_command);
            try append_host_shell_step(allocator, &steps, expanded_install_command);
        } else {
            const makefile = rock.build.makefile;
            const build_variables = try translate_make_variables(allocator, rock, rock.build.build_variables, env_map);
            defer {
                for (build_variables) |variable| allocator.free(variable);
                allocator.free(build_variables);
            }
            const install_variables = try translate_make_variables(allocator, rock, rock.build.install_variables, env_map);
            defer {
                for (install_variables) |variable| allocator.free(variable);
                allocator.free(install_variables);
            }

            const build_target = rock.build.build_target orelse "";
            const makefile_arg_count: usize = if (makefile != null) 2 else 0;
            const build_target_arg_count: usize = if (build_target.len > 0) 1 else 0;
            const build_arg_count = makefile_arg_count + build_variables.len + build_target_arg_count;
            const build_args = try allocator.alloc([]const u8, build_arg_count);
            var build_index: usize = 0;
            if (makefile) |value| {
                build_args[build_index] = try allocator.dupe(u8, "-f");
                build_index += 1;
                build_args[build_index] = try allocator.dupe(u8, value);
                build_index += 1;
            }
            for (build_variables) |variable| {
                build_args[build_index] = try allocator.dupe(u8, variable);
                build_index += 1;
            }
            if (build_target.len > 0) {
                build_args[build_index] = try allocator.dupe(u8, build_target);
            }
            try steps.append(allocator, .{
                .command = try allocator.dupe(u8, "make"),
                .args = build_args,
            });

            const install_target = rock.build.install_target orelse "install";
            const install_arg_count = makefile_arg_count + install_variables.len + 1;
            const install_args = try allocator.alloc([]const u8, install_arg_count);
            var install_index: usize = 0;
            if (makefile) |value| {
                install_args[install_index] = try allocator.dupe(u8, "-f");
                install_index += 1;
                install_args[install_index] = try allocator.dupe(u8, value);
                install_index += 1;
            }
            for (install_variables) |variable| {
                install_args[install_index] = try allocator.dupe(u8, variable);
                install_index += 1;
            }
            install_args[install_index] = try allocator.dupe(u8, install_target);
            try steps.append(allocator, .{
                .command = try allocator.dupe(u8, "make"),
                .args = install_args,
            });
        }
    }

    const cmake_definitions = if (is_cmake)
        try translate_cmake_variables(allocator, rock.build.variables, env_map)
    else
        &.{};

    const config = manifest.MaterializeConfig{
        .kind = if (is_cmake) "cmake" else "command",
        .steps = try steps.toOwnedSlice(allocator),
        .env = try env_pairs.toOwnedSlice(allocator),
        .ldflags = cmake_definitions,
    };

    try list.append(allocator, .{
        .name = try allocator.dupe(u8, "command_build"),
        .kind = .c,
        .dest_path = try allocator.dupe(u8, ""),
        .config = config,
    });

    return try list.toOwnedSlice(allocator);
}

fn expand_luarocks_command_value(
    allocator: std.mem.Allocator,
    raw_value: []const u8,
    env_map: *const std.process.Environ.Map,
) ![]const u8 {
    const builtin = @import("builtin");
    const default_libflag = switch (builtin.os.tag) {
        .macos => "-fPIC -bundle -undefined dynamic_lookup",
        .windows => "-shared",
        else => "-shared -fPIC",
    };
    var result = try allocator.dupe(u8, raw_value);
    errdefer allocator.free(result);
    const substitutions = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "BINDIR", .value = "${out}/bin" },
        .{ .key = "CC", .value = env_map.get("CC") orelse "cc" },
        // LuaRocks' command backend supplies -O2 when the caller has not
        // configured CFLAGS. Some upstream command builders distinguish an
        // omitted/default value from an explicit empty assignment.
        .{ .key = "CFLAGS", .value = env_map.get("CFLAGS") orelse "-O2" },
        .{ .key = "LD", .value = env_map.get("LD") orelse "cc" },
        .{ .key = "LDFLAGS", .value = env_map.get("LDFLAGS") orelse "" },
        .{ .key = "LIBDIR", .value = "${out}/lib/lua/${lua_abi}" },
        .{ .key = "LIBFLAG", .value = env_map.get("LIBFLAG") orelse default_libflag },
        .{ .key = "LIB_EXTENSION", .value = "so" },
        .{ .key = "LUA", .value = "${runtime.bin_dir}/lua" },
        .{ .key = "LUA_BINDIR", .value = "${runtime.bin_dir}" },
        .{ .key = "LUA_INCDIR", .value = "${runtime.include}" },
        .{ .key = "LUA_LIBDIR", .value = "${runtime.lib}" },
        .{ .key = "LUALIB", .value = "${runtime.lualib}" },
        .{ .key = "LUADIR", .value = "${out}/share/lua/${lua_abi}" },
        .{ .key = "OBJ_EXTENSION", .value = "o" },
        .{ .key = "PREFIX", .value = "${out}" },
    };
    for (substitutions) |substitution| {
        const placeholder = try std.fmt.allocPrint(allocator, "$({s})", .{substitution.key});
        defer allocator.free(placeholder);
        const next = try std.mem.replaceOwned(u8, allocator, result, placeholder, substitution.value);
        allocator.free(result);
        result = next;
    }
    if (std.mem.indexOf(u8, result, "$(") != null) return error.UnsupportedLuaRocksCommandVariable;
    return result;
}

fn translate_make_variables(
    allocator: std.mem.Allocator,
    rock: *const luarocks.RockspecIntent,
    variables: ?std.json.Value,
    env_map: *const std.process.Environ.Map,
) ![]const []const u8 {
    const value = variables orelse return &.{};
    if (value != .object) return error.InvalidLuaRocksMakeVariables;

    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidLuaRocksMakeVariables;
        try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    var assignments = std.ArrayList([]const u8).empty;
    errdefer {
        for (assignments.items) |assignment| allocator.free(assignment);
        assignments.deinit(allocator);
    }
    for (keys.items) |key| {
        const raw_value = value.object.get(key).?.string;
        const expanded = try expand_luarocks_make_value(allocator, rock, raw_value, env_map);
        defer allocator.free(expanded);
        try assignments.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, expanded }));
    }
    return try assignments.toOwnedSlice(allocator);
}

fn expand_luarocks_make_value(
    allocator: std.mem.Allocator,
    rock: *const luarocks.RockspecIntent,
    raw_value: []const u8,
    env_map: *const std.process.Environ.Map,
) ![]const u8 {
    var result = try allocator.dupe(u8, raw_value);
    errdefer allocator.free(result);
    const substitutions = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "BINDIR", .value = "${out}/bin" },
        .{ .key = "CFLAGS", .value = env_map.get("CFLAGS") orelse "" },
        .{ .key = "LDFLAGS", .value = env_map.get("LDFLAGS") orelse "" },
        .{ .key = "LIBDIR", .value = "${out}/lib/lua/${lua_abi}" },
        .{ .key = "LIBFLAG", .value = env_map.get("LIBFLAG") orelse "" },
        .{ .key = "LUADIR", .value = "${out}/share/lua/${lua_abi}" },
        .{ .key = "LUA_BINDIR", .value = "${runtime.bin_dir}" },
        .{ .key = "LUA_INCDIR", .value = "${runtime.include}" },
        .{ .key = "LUA_LIBDIR", .value = "${runtime.lib}" },
        .{ .key = "LUALIB", .value = "${runtime.lualib}" },
        .{ .key = "PREFIX", .value = "${out}" },
    };
    for (substitutions) |substitution| {
        const placeholder = try std.fmt.allocPrint(allocator, "$({s})", .{substitution.key});
        defer allocator.free(placeholder);
        const next = try std.mem.replaceOwned(u8, allocator, result, placeholder, substitution.value);
        allocator.free(result);
        result = next;
    }

    while (std.mem.indexOf(u8, result, "$(")) |start| {
        const suffix = result[start + 2 ..];
        const close_offset = std.mem.indexOfScalar(u8, suffix, ')') orelse return error.UnsupportedLuaRocksMakeVariable;
        const variable = suffix[0..close_offset];
        const external_value = try declared_external_path_value(rock, variable, env_map);
        const placeholder = result[start .. start + 3 + close_offset];
        const next = try std.mem.replaceOwned(u8, allocator, result, placeholder, external_value);
        allocator.free(result);
        result = next;
    }
    return result;
}

fn declared_external_path_value(
    rock: *const luarocks.RockspecIntent,
    variable: []const u8,
    env_map: *const std.process.Environ.Map,
) ![]const u8 {
    const suffix = if (std.mem.endsWith(u8, variable, "_INCDIR")) "_INCDIR" else if (std.mem.endsWith(u8, variable, "_LIBDIR")) "_LIBDIR" else return error.UnsupportedLuaRocksMakeVariable;
    const dependency_name = variable[0 .. variable.len - suffix.len];
    const dependencies = rock.external_dependencies orelse return error.UnsupportedLuaRocksMakeVariable;
    if (dependencies != .object or dependencies.object.get(dependency_name) == null) return error.UnsupportedLuaRocksMakeVariable;
    return env_map.get(variable) orelse return error.LuaRocksExternalDependencyPathRequired;
}

fn translate_cmake_variables(
    allocator: std.mem.Allocator,
    variables: ?std.json.Value,
    env_map: *const std.process.Environ.Map,
) ![]const []const u8 {
    const value = variables orelse return &.{};
    if (value != .object) return error.InvalidLuaRocksCMakeVariables;

    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidLuaRocksCMakeVariables;
        try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    var definitions = std.ArrayList([]const u8).empty;
    errdefer {
        for (definitions.items) |definition| allocator.free(definition);
        definitions.deinit(allocator);
    }
    for (keys.items) |key| {
        const raw_value = value.object.get(key).?.string;
        const expanded = try expand_luarocks_cmake_value(allocator, raw_value, env_map);
        defer allocator.free(expanded);
        try definitions.append(allocator, try std.fmt.allocPrint(allocator, "-D{s}={s}", .{ key, expanded }));
    }
    return try definitions.toOwnedSlice(allocator);
}

fn expand_luarocks_cmake_value(
    allocator: std.mem.Allocator,
    raw_value: []const u8,
    env_map: *const std.process.Environ.Map,
) ![]const u8 {
    var result = try allocator.dupe(u8, raw_value);
    errdefer allocator.free(result);
    const substitutions = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "CFLAGS", .value = env_map.get("CFLAGS") orelse "" },
        .{ .key = "LDFLAGS", .value = env_map.get("LDFLAGS") orelse "" },
        .{ .key = "LIBFLAG", .value = env_map.get("LIBFLAG") orelse "" },
        .{ .key = "LUA", .value = "${runtime.bin_dir}/lua" },
        .{ .key = "LUA_INCDIR", .value = "${runtime.include}" },
        .{ .key = "LUA_LIBDIR", .value = "${runtime.lib}" },
        .{ .key = "LUALIB", .value = "" },
        .{ .key = "LIBDIR", .value = "${cmake.install}/lib/lua/${lua_abi}" },
        .{ .key = "LUADIR", .value = "${cmake.install}/share/lua/${lua_abi}" },
    };
    for (substitutions) |substitution| {
        const placeholder = try std.fmt.allocPrint(allocator, "$({s})", .{substitution.key});
        defer allocator.free(placeholder);
        const next = try std.mem.replaceOwned(u8, allocator, result, placeholder, substitution.value);
        allocator.free(result);
        result = next;
    }
    if (std.mem.indexOf(u8, result, "$(") != null) return error.UnsupportedLuaRocksCMakeVariable;
    return result;
}

test "LuaRocks CMake variables resolve deterministically without shell expansion" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "LUA_INCDIR": "$(LUA_INCDIR)",
        \\  "LIBDIR": "$(LIBDIR)",
        \\  "CMAKE_C_FLAGS": "$(CFLAGS)",
        \\  "LUA": "$(LUA)"
        \\}
    , .{});
    defer parsed.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("CFLAGS", "-O2 -fPIC");

    const definitions = try translate_cmake_variables(allocator, parsed.value, &env);
    defer {
        for (definitions) |definition| allocator.free(definition);
        allocator.free(definitions);
    }
    try std.testing.expectEqualSlices([]const u8, &.{
        "-DCMAKE_C_FLAGS=-O2 -fPIC",
        "-DLIBDIR=${cmake.install}/lib/lua/${lua_abi}",
        "-DLUA=${runtime.bin_dir}/lua",
        "-DLUA_INCDIR=${runtime.include}",
    }, definitions);
}

test "LuaRocks CMake variables reject unknown placeholders" {
    const allocator = std.testing.allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try std.testing.expectError(
        error.UnsupportedLuaRocksCMakeVariable,
        expand_luarocks_cmake_value(allocator, "$(UNDECLARED_TOOLCHAIN_VALUE)", &env),
    );
}

test "LuaRocks command variables become projected command values" {
    const allocator = std.testing.allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("CC", "clang");

    const command = try expand_luarocks_command_value(
        allocator,
        "$(LUA) build.lua CC=\"$(CC)\" LUA_INCDIR=\"$(LUA_INCDIR)\" LIBDIR=\"$(LIBDIR)\"",
        &env,
    );
    defer allocator.free(command);
    try std.testing.expectEqualStrings(
        "${runtime.bin_dir}/lua build.lua CC=\"clang\" LUA_INCDIR=\"${runtime.include}\" LIBDIR=\"${out}/lib/lua/${lua_abi}\"",
        command,
    );
}

test "LuaRocks command variables reject unknown placeholders" {
    const allocator = std.testing.allocator;
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try std.testing.expectError(
        error.UnsupportedLuaRocksCommandVariable,
        expand_luarocks_command_value(allocator, "tool $(UNDECLARED)", &env),
    );
}

fn append_host_shell_step(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(manifest.CommandStep),
    command: []const u8,
) !void {
    const builtin = @import("builtin");
    const shell = switch (builtin.os.tag) {
        .windows => "cmd",
        else => "sh",
    };
    const shell_args = switch (builtin.os.tag) {
        .windows => [_][]const u8{ "/d", "/s", "/c", command },
        else => [_][]const u8{ "-c", command },
    };

    const args = try allocator.alloc([]const u8, shell_args.len);
    errdefer allocator.free(args);
    for (shell_args, 0..) |argument, index| args[index] = try allocator.dupe(u8, argument);
    try steps.append(allocator, .{
        .command = try allocator.dupe(u8, shell),
        .args = args,
    });
}

const TranslatedModule = struct {
    name: []const u8,
    kind: enum { lua, c, data },
    dest_path: []const u8,
    source_path: ?[]const u8 = null,
    config: ?manifest.MaterializeConfig = null,
};

fn deinit_translated_modules(allocator: std.mem.Allocator, translated: []const TranslatedModule) void {
    for (translated) |module| {
        allocator.free(module.name);
        allocator.free(module.dest_path);
        if (module.source_path) |source_path| allocator.free(source_path);
        if (module.config) |config| {
            if (config.input) |input| {
                for (input.sources) |source| allocator.free(source);
                allocator.free(input.sources);
            }
            if (config.output) |output| {
                allocator.free(output.module);
                allocator.free(output.path);
            }
            for (config.args) |arg| allocator.free(arg);
            allocator.free(config.args);
            for (config.ldflags) |flag| allocator.free(flag);
            allocator.free(config.ldflags);
        }
    }
    allocator.free(translated);
}

/// Owns the preparation-only state that must remain valid until a LuaRocks
/// source build is either reused from the CAS or materialized exactly once.
/// This deliberately excludes process state and display policy so sync can
/// schedule prepared rocks without sharing a resolver instance between workers.
pub const PreparedRock = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: fs.MOONSTONE_PATHS,
    workspace_path: []const u8,
    rockspec_payload_path: []const u8,
    build_out_path: []const u8,
    parsed_rockspec: std.json.Parsed(luarocks.Rockspec),
    fetched_rockspec: FetchedRockspec,
    fetched_source: FetchedSource,
    translated: []const TranslatedModule,
    class: RockClass,
    compatibility_recipe: ?luarocks_compat.AppliedRecipe,
    patch_transform_hash: ?[]const u8,
    recipe_hash: ?[]const u8,

    /// Only declarative builtin and pure-Lua rocks have a complete output
    /// contract before execution. Command builds intentionally return null.
    pub fn recipeKey(self: *const PreparedRock) ?[]const u8 {
        if (self.parsed_rockspec.value.intent.build_dependencies.len > 0) return null;
        return self.recipe_hash;
    }

    pub fn isCoalescible(self: *const PreparedRock) bool {
        return self.recipe_hash != null;
    }

    pub fn deinit(self: *PreparedRock) void {
        deinit_translated_modules(self.allocator, self.translated);
        if (self.patch_transform_hash) |patch_transform_hash| self.allocator.free(patch_transform_hash);
        if (self.recipe_hash) |recipe_hash| self.allocator.free(recipe_hash);
        self.fetched_source.deinit(self.allocator);
        self.fetched_rockspec.deinit(self.allocator);
        self.parsed_rockspec.deinit();
        std.Io.Dir.cwd().deleteTree(self.io, self.workspace_path) catch {};
        self.allocator.free(self.workspace_path);
        self.allocator.free(self.rockspec_payload_path);
        self.allocator.free(self.build_out_path);
        self.paths.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Candidate discovery can resolve directly to a binary rock or prepare a
/// source rock for later materialization. Keeping this distinction explicit
/// lets callers schedule source preparation independently without changing
/// binary-rock preference semantics.
pub const PreparedResolution = union(enum) {
    binary: candidate_mod.Candidate,
    source: PreparedRock,

    pub fn deinit(self: *PreparedResolution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .binary => |*candidate| candidate.deinit(allocator),
            .source => |*prepared| prepared.deinit(),
        }
        self.* = undefined;
    }
};

pub fn prepare_source_rock(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version: []const u8,
    runtime_spec: []const u8,
    options: options_mod.ResolveOptions,
    env_map: *std.process.Environ.Map,
    base: []const u8,
) !PreparedRock {
    const fetched_rockspec = if (options.locked_rockspec_url) |url|
        try fetch_locked_rockspec(allocator, io, url, options.locked_rockspec_hash, env_map, options.on_event, options.on_event_context, options.cancellation_flag)
    else
        try fetch_rockspec(allocator, io, base, pkg_name, version, env_map, options.on_event, options.on_event_context, options.cancellation_flag);
    errdefer fetched_rockspec.deinit(allocator);

    const lua_exe = blk: {
        if (options.lua_exe) |exe| break :blk try allocator.dupe(u8, exe);
        const runtime_path = options.runtime_path orelse return error.RuntimeRequiredForParsing;
        break :blk try find_runtime_lua_executable(allocator, io, runtime_path, env_map);
    };
    defer allocator.free(lua_exe);

    var paths = try fs.resolve_moonstone(allocator, env_map, io);
    errdefer paths.deinit(allocator);
    var parsed_rockspec = luarocks.parse_rockspec_for_target(allocator, io, fetched_rockspec.content, lua_exe, paths.tmp, options.target) catch |err| {
        @import("../../diagnostics/error_context.zig").setFmt(
            allocator,
            "failed to evaluate LuaRocks rockspec for {s}@{s}\nreason: {s}",
            .{ pkg_name, version, @errorName(err) },
        );
        return err;
    };
    errdefer parsed_rockspec.deinit();
    const intent = parsed_rockspec.value.intent;
    if (!supports_selected_platform(&intent)) return error.UnsupportedLuaRocksPlatform;
    try ensure_supported_artifact_contract(&intent);
    const class = classify_rock(&intent);
    switch (class) {
        .pure_lua, .builtin_cmodule, .command_build => {},
        .unsupported => return error.UnsupportedLuaRocksBuildType,
        .binary_rock => unreachable,
    }
    const selected_target = options.target orelse platform_target.hostTargetLiteral();
    if (!platform_target.isHost(selected_target) and class != .pure_lua) {
        @import("../../diagnostics/error_context.zig").setFmt(
            allocator,
            "LuaRocks package {s}@{s} declares a {s} build and cannot be materialized for foreign target `{s}`. Foreign profiles currently support pure-Lua rocks only; publish a target artifact or materialize this package on that target.",
            .{ pkg_name, version, rock_build_type(&intent), selected_target },
        );
        return error.ForeignTargetSourceUnsupported;
    }
    const workspace_name = try std.fmt.allocPrint(allocator, "rocks-{s}-{s}-{d}-{d}", .{ pkg_name, version, std.Thread.getCurrentId(), materialization_workspace_counter.fetchAdd(1, .monotonic) });
    defer allocator.free(workspace_name);
    const workspace_path = try std.fs.path.join(allocator, &.{ paths.tmp, workspace_name });
    errdefer allocator.free(workspace_path);
    std.Io.Dir.cwd().deleteTree(io, workspace_path) catch |err| if (err != error.FileNotFound) return err;
    try std.Io.Dir.cwd().createDirPath(io, workspace_path);
    errdefer std.Io.Dir.cwd().deleteTree(io, workspace_path) catch {};

    const rockspec_name = try std.fmt.allocPrint(allocator, "{s}-{s}.rockspec", .{ pkg_name, version });
    defer allocator.free(rockspec_name);
    const rockspec_payload_path = try std.fs.path.join(allocator, &.{ workspace_path, rockspec_name });
    errdefer allocator.free(rockspec_payload_path);
    const rockspec_file = try std.Io.Dir.cwd().createFile(io, rockspec_payload_path, .{});
    try rockspec_file.writeStreamingAll(io, fetched_rockspec.content);
    rockspec_file.close(io);

    const fetched_source = fetch_and_unpack_source(allocator, io, base, pkg_name, version, &intent, workspace_path, env_map, options.on_event, options.on_event_context, options.locked_source_url, options.locked_source_hash) catch |err| {
        @import("../../diagnostics/error_context.zig").setFmt(
            allocator,
            "failed to prepare LuaRocks source for {s}@{s}\nreason: {s}",
            .{ pkg_name, version, @errorName(err) },
        );
        return err;
    };
    errdefer fetched_source.deinit(allocator);
    const patch_transform_hash = try apply_declared_patches(allocator, io, fetched_source.path, intent.build_declaration, class);
    errdefer if (patch_transform_hash) |value| allocator.free(value);
    const compatibility_recipe = try luarocks_compat.apply(allocator, io, pkg_name, options.runtime_c_api, fetched_source.path);

    const build_out_path = try std.fs.path.join(allocator, &.{ workspace_path, "out" });
    errdefer allocator.free(build_out_path);
    try std.Io.Dir.cwd().createDirPath(io, build_out_path);

    var translated = if (class == .command_build) try translateCommandBuild(allocator, &intent, env_map) else try translateBuiltinBuild(allocator, &intent, runtime_spec);
    errdefer deinit_translated_modules(allocator, translated);
    if (options.build_env.len > 0) {
        var updated = std.ArrayList(TranslatedModule).empty;
        errdefer updated.deinit(allocator);
        for (translated) |module| {
            var mutable = module;
            if (mutable.config) |*config| {
                var env = std.ArrayList(manifest.EnvPair).empty;
                for (config.env) |entry| try env.append(allocator, .{ .key = try allocator.dupe(u8, entry.key), .value = try allocator.dupe(u8, entry.value) });
                for (options.build_env) |entry| try env.append(allocator, .{ .key = try allocator.dupe(u8, entry.key), .value = try allocator.dupe(u8, entry.value) });
                config.env = try env.toOwnedSlice(allocator);
            }
            try updated.append(allocator, mutable);
        }
        allocator.free(translated);
        translated = try updated.toOwnedSlice(allocator);
    }

    var recipe_hash: ?[]const u8 = null;
    errdefer if (recipe_hash) |value| allocator.free(value);
    if (class != .command_build) {
        const bin_value = if (intent.build.install) |install| install.bin else null;
        const bins = try build_bin_list(allocator, io, fetched_source.path, bin_value);
        defer deinit_provisions(allocator, bins);
        const lua_modules = try build_lua_module_list_from_translated(allocator, translated);
        defer deinit_provisions(allocator, lua_modules);
        const lua_cmodules = try build_c_module_list(allocator, translated);
        defer deinit_provisions(allocator, lua_cmodules);
        const copy_directories = if (intent.build_declaration == .object) intent.build_declaration.object.get("copy_directories") else null;
        const install_conf = if (intent.build.install) |install| install.conf else null;
        const install_lib = if (intent.build.install) |install| install.lib else null;
        const native_libs = try collect_luarocks_install_libraries(allocator, io, fetched_source.path, options.target orelse "native", install_lib);
        defer deinit_provisions(allocator, native_libs);
        const assets = try collect_luarocks_assets(allocator, io, fetched_source.path, copy_directories, install_conf);
        defer deinit_provisions(allocator, assets);

        var recipe_env = std.ArrayList(manifest.EnvPair).empty;
        defer {
            for (recipe_env.items) |entry| {
                allocator.free(entry.key);
                allocator.free(entry.value);
            }
            recipe_env.deinit(allocator);
        }
        for (options.build_env) |entry| try recipe_env.append(allocator, .{
            .key = try allocator.dupe(u8, entry.key),
            .value = try allocator.dupe(u8, entry.value),
        });
        if (compatibility_recipe) |recipe| try recipe_env.append(allocator, .{
            .key = try allocator.dupe(u8, recipe.key),
            .value = try allocator.dupe(u8, recipe.value),
        });
        try append_external_path_recipe_environment(allocator, &recipe_env, translated, env_map);

        recipe_hash = try compute_synthetic_recipe_hash(
            allocator,
            parsed_rockspec.value.package,
            parsed_rockspec.value.version,
            if (bins.len > 0) .bin else .lib,
            runtime_spec,
            options.runtime_artifact_hash orelse "",
            options.target orelse "native",
            fetched_source.hash,
            patch_transform_hash orelse "",
            "rocks-builtin",
            lua_modules,
            lua_cmodules,
            bins,
            native_libs,
            assets,
            recipe_env.items,
            &.{},
        );
    }

    return .{
        .allocator = allocator,
        .io = io,
        .paths = paths,
        .workspace_path = workspace_path,
        .rockspec_payload_path = rockspec_payload_path,
        .build_out_path = build_out_path,
        .parsed_rockspec = parsed_rockspec,
        .fetched_rockspec = fetched_rockspec,
        .fetched_source = fetched_source,
        .translated = translated,
        .class = class,
        .compatibility_recipe = compatibility_recipe,
        .patch_transform_hash = patch_transform_hash,
        .recipe_hash = recipe_hash,
    };
}

fn translateBuiltinBuild(
    allocator: std.mem.Allocator,
    rock: *const luarocks.RockspecIntent,
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
        try appendBuiltinInstalledLuaFiles(allocator, &list, lua_ver_dot, lua_files);
    };

    return try list.toOwnedSlice(allocator);
}

fn appendBuiltinInstalledLuaFiles(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(TranslatedModule),
    lua_ver_dot: []const u8,
    files: std.json.Value,
) !void {
    switch (files) {
        .string => |source_path| try appendBuiltinInstalledLuaFile(allocator, list, lua_ver_dot, null, source_path),
        .array => |paths| for (paths.items) |path| {
            if (path == .string) try appendBuiltinInstalledLuaFile(allocator, list, lua_ver_dot, null, path.string);
        },
        .object => |mappings| {
            var it = mappings.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string) continue;
                try appendBuiltinInstalledLuaFile(allocator, list, lua_ver_dot, entry.key_ptr.*, entry.value_ptr.*.string);
            }
        },
        else => {},
    }
}

fn appendBuiltinInstalledLuaFile(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(TranslatedModule),
    lua_ver_dot: []const u8,
    module_name_opt: ?[]const u8,
    source_path: []const u8,
) !void {
    const source_basename = std.fs.path.basename(source_path);
    const source_is_lua = std.mem.endsWith(u8, source_basename, ".lua");
    const inferred_name = if (source_is_lua) source_basename[0 .. source_basename.len - ".lua".len] else source_basename;
    const module_name = module_name_opt orelse inferred_name;

    const module_path = try std.mem.replaceOwned(u8, allocator, module_name, ".", "/");
    defer allocator.free(module_path);

    const destination_filename = if (source_is_lua)
        try std.fmt.allocPrint(allocator, "{s}.lua", .{std.fs.path.basename(module_path)})
    else
        try allocator.dupe(u8, source_basename);
    defer allocator.free(destination_filename);

    const last_dot = std.mem.lastIndexOfScalar(u8, module_name, '.');
    const module_dir = if (last_dot) |index| module_name[0..index] else "";
    const module_dir_path = try std.mem.replaceOwned(u8, allocator, module_dir, ".", "/");
    defer allocator.free(module_dir_path);

    const dest_path = if (module_dir_path.len > 0)
        try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}/{s}", .{ lua_ver_dot, module_dir_path, destination_filename })
    else
        try std.fmt.allocPrint(allocator, "share/lua/{s}/{s}", .{ lua_ver_dot, destination_filename });
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, module_name),
        .kind = .lua,
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
    const manifest_parsed = try fetch_manifest(allocator, io, base, options.runtime, env_map, options.on_event, options.on_event_context, options.offline, options.cancellation_flag);
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
    const parsed = try fetch_manifest(allocator, io, base, runtime, env_map, on_event, on_event_context, false, null);
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

    const rock_data = try http_get(allocator, io, url, env_map, on_event, on_event_context, null, null);
    defer allocator.free(rock_data);
    const source_hash = try blake3_prefixed(allocator, rock_data);
    defer allocator.free(source_hash);

    const paths = try fs.resolve_moonstone(allocator, env_map, io);
    defer {
        var p = paths;
        p.deinit(allocator);
    }

    const tmp_dir_name = try std.fmt.allocPrint(allocator, "rocks-bin-{s}-{s}-{d}-{d}", .{
        pkg_name,
        version,
        std.Thread.getCurrentId(),
        materialization_workspace_counter.fetchAdd(1, .monotonic),
    });
    defer allocator.free(tmp_dir_name);
    const tmp_dir = try std.fs.path.join(allocator, &.{ paths.tmp, tmp_dir_name });
    defer allocator.free(tmp_dir);

    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

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
        "",
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
        &.{}, // native_libs
        &.{}, // assets
        &.{}, // dependencies
        &.{}, // build_env
        &.{}, // build_artifacts
        null, // recipe_hash_override
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
    cancellation_flag: ?*const std.atomic.Value(bool),
) !FetchedRockspec {
    // If version already includes a LuaRocks revision (e.g. "3.1.3-1"), try exact rockspec first.
    if (has_luarocks_revision(version)) {
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.rockspec", .{
            base, pkg_name, version,
        });
        defer allocator.free(url);
        const content = http_get(allocator, io, url, env_map, on_event, on_event_context, null, cancellation_flag) catch |err| blk: {
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
        const content = http_get(allocator, io, url, env_map, on_event, on_event_context, null, cancellation_flag) catch |err| {
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

fn fetch_locked_rockspec(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    expected_hash: ?[]const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
    cancellation_flag: ?*const std.atomic.Value(bool),
) !FetchedRockspec {
    const content = try http_get(allocator, io, url, env_map, on_event, on_event_context, null, cancellation_flag);
    errdefer allocator.free(content);
    if (std.mem.indexOf(u8, content, "package =") == null) return error.RockspecNotFound;

    const content_hash = try blake3_prefixed(allocator, content);
    errdefer allocator.free(content_hash);
    if (expected_hash) |expected| if (!std.mem.eql(u8, expected, content_hash)) {
        @import("../../diagnostics/error_context.zig").setFmt(
            allocator,
            "locked LuaRocks rockspec hash mismatch\nurl: {s}\nexpected: {s}\nactual: {s}",
            .{ url, expected, content_hash },
        );
        return error.LockedRockspecHashMismatch;
    };

    return .{
        .content = content,
        .url = try allocator.dupe(u8, url),
        .hash = content_hash,
    };
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

fn classify_rock(rock: *const luarocks.RockspecIntent) RockClass {
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

fn has_declared_entries(value: ?std.json.Value) bool {
    const declared = value orelse return false;
    return switch (declared) {
        .null => false,
        .array => |items| items.items.len > 0,
        .object => |object| blk: {
            var it = object.iterator();
            break :blk it.next() != null;
        },
        else => true,
    };
}

fn ensure_supported_artifact_contract(intent: *const luarocks.RockspecIntent) !void {
    if (has_declared_entries(intent.hooks)) return error.UnsupportedLuaRocksHooks;
}

fn external_path_variable(flag: []const u8) ?[]const u8 {
    const prefix_len: usize = if (std.mem.startsWith(u8, flag, "-I") or std.mem.startsWith(u8, flag, "-L")) 2 else return null;
    const reference = flag[prefix_len..];
    if (!std.mem.startsWith(u8, reference, "$(") or !std.mem.endsWith(u8, reference, ")")) return null;
    return reference[2 .. reference.len - 1];
}

fn append_external_path_recipe_environment(
    allocator: std.mem.Allocator,
    recipe_env: *std.ArrayList(manifest.EnvPair),
    translated: []const TranslatedModule,
    env_map: *const std.process.Environ.Map,
) !void {
    var variables = std.ArrayList([]const u8).empty;
    defer variables.deinit(allocator);

    for (translated) |module| {
        const config = module.config orelse continue;
        for (config.args) |flag| if (external_path_variable(flag)) |variable| {
            var already_present = false;
            for (variables.items) |existing| {
                if (std.mem.eql(u8, existing, variable)) {
                    already_present = true;
                    break;
                }
            }
            if (!already_present) try variables.append(allocator, variable);
        };
        for (config.ldflags) |flag| if (external_path_variable(flag)) |variable| {
            var already_present = false;
            for (variables.items) |existing| {
                if (std.mem.eql(u8, existing, variable)) {
                    already_present = true;
                    break;
                }
            }
            if (!already_present) try variables.append(allocator, variable);
        };
    }
    std.mem.sort([]const u8, variables.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    for (variables.items) |variable| {
        try recipe_env.append(allocator, .{
            .key = try std.fmt.allocPrint(allocator, "external:{s}", .{variable}),
            .value = try allocator.dupe(u8, env_map.get(variable) orelse "<unset>"),
        });
    }
}

test "LuaRocks external path variables are recognized only in compiler path flags" {
    try std.testing.expectEqualStrings("SQLITE_INCDIR", external_path_variable("-I$(SQLITE_INCDIR)").?);
    try std.testing.expectEqualStrings("SQLITE_LIBDIR", external_path_variable("-L$(SQLITE_LIBDIR)").?);
    try std.testing.expect(external_path_variable("-lsqlite3") == null);
    try std.testing.expect(external_path_variable("-Irelative/include") == null);
    try std.testing.expect(external_path_variable("$(SQLITE_INCDIR)") == null);
}

const DeclaredPatch = struct {
    name: []const u8,
    command: []const u8,
};

fn apply_declared_patches(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    build_declaration: std.json.Value,
    class: RockClass,
) !?[]const u8 {
    if (build_declaration != .object) return null;
    const declared = build_declaration.object.get("patches") orelse return null;
    if (declared != .object) return error.InvalidLuaRocksPatches;
    if (class == .command_build) return error.UnsupportedLuaRocksPatches;

    var entries = std.ArrayList(DeclaredPatch).empty;
    defer entries.deinit(allocator);
    var iterator = declared.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidLuaRocksPatches;
        try entries.append(allocator, .{
            .name = entry.key_ptr.*,
            .command = entry.value_ptr.*.string,
        });
    }
    if (entries.items.len == 0) return null;
    std.mem.sort(DeclaredPatch, entries.items, {}, struct {
        fn lessThan(_: void, left: DeclaredPatch, right: DeclaredPatch) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);

    var canonical = std.ArrayList(u8).empty;
    defer canonical.deinit(allocator);
    try canonical.appendSlice(allocator, "moonstone:luarocks:patches:v1\n");
    for (entries.items) |entry| {
        const fragment = try std.fmt.allocPrint(allocator, "name_bytes={d}\n{s}\ncommand_bytes={d}\n{s}\n", .{
            entry.name.len,
            entry.name,
            entry.command.len,
            entry.command,
        });
        defer allocator.free(fragment);
        try canonical.appendSlice(allocator, fragment);

        var patch = try luarocks_patch.parse(allocator, entry.command);
        defer patch.deinit(allocator);
        for (patch.files) |file| try luarocks_patch.applyFileAtRoot(allocator, io, source_root, file);
    }
    return try blake3_prefixed(allocator, canonical.items);
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

fn select_rockspec_source_root(
    allocator: std.mem.Allocator,
    io: std.Io,
    extracted_root: []const u8,
    declared_dir: ?[]const u8,
) ![]const u8 {
    const relative_dir = declared_dir orelse return try find_source_root(allocator, io, extracted_root);
    if (std.mem.eql(u8, relative_dir, ".")) return try find_source_root(allocator, io, extracted_root);
    if (!is_safe_copy_directory_path(relative_dir)) return error.InvalidLuaRocksSourceDir;

    // source.dir is relative to the extracted archive, not necessarily to the
    // archive's auto-detected single package directory. A common rockspec
    // names that package directory itself; descending first would apply the
    // segment twice (root/root) and reject a valid upstream source layout.
    const selected_root = try std.fs.path.join(allocator, &.{ extracted_root, relative_dir });
    errdefer allocator.free(selected_root);
    var selected_dir = std.Io.Dir.cwd().openDir(io, selected_root, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.LuaRocksSourceDirNotFound,
        else => return err,
    };
    selected_dir.close(io);
    return selected_root;
}

/// Fetch and unpack source. Tries .src.rock first, then falls back to rockspec source.url.
fn fetch_and_unpack_source(
    allocator: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    pkg_name: []const u8,
    version: []const u8,
    rock: *const luarocks.RockspecIntent,
    tmp_dir: []const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
    locked_source_url: ?[]const u8,
    expected_source_hash: ?[]const u8,
) !FetchedSource {
    // 5a. Prefer the LuaRocks source rock when available. Many modern
    // rockspecs point source.url at git+https repositories, while LuaRocks
    // also publishes a .src.rock archive that Moonstone can fetch over HTTPS.
    const guessed_src_rock = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.src.rock", .{ base, pkg_name, version });
    defer allocator.free(guessed_src_rock);

    const source_fetch: SourceFetch = if (locked_source_url) |url| blk: {
        const source_data = try http_get(allocator, io, url, env_map, on_event, on_event_context, null, null);
        break :blk SourceFetch{
            .url = try allocator.dupe(u8, url),
            .data = source_data,
            .is_declared_source = std.mem.eql(u8, url, rock_source_url(rock)),
        };
    } else blk: {
        const src_rock_data = http_get(allocator, io, guessed_src_rock, env_map, on_event, on_event_context, null, null) catch |err| {
            if (err != error.HttpError and err != error.FileNotFound and err != error.UnsupportedUriScheme) return err;
            const src_url = rock_source_url(rock);
            if (src_url.len == 0) return error.SourceRockNotFound;
            const fallback_url = try source_fallback_url(allocator, src_url, rock.source.tag, rock.source.branch);
            errdefer allocator.free(fallback_url);
            const fallback_data = http_get(allocator, io, fallback_url, env_map, on_event, on_event_context, null, null) catch |fallback_err| {
                @import("../../diagnostics/error_context.zig").setFmt(
                    allocator,
                    "failed to fetch declared LuaRocks source for {s}@{s}\nsource: {s}\nreason: {s}",
                    .{ pkg_name, version, fallback_url, @errorName(fallback_err) },
                );
                if (fallback_err == error.HttpError) return error.SourceRockNotFound;
                return fallback_err;
            };
            break :blk SourceFetch{
                .url = fallback_url,
                .data = fallback_data,
                .is_declared_source = std.mem.eql(u8, fallback_url, src_url),
            };
        };
        break :blk SourceFetch{
            .url = try allocator.dupe(u8, guessed_src_rock),
            .data = src_rock_data,
            .is_declared_source = std.mem.eql(u8, guessed_src_rock, rock_source_url(rock)),
        };
    };
    const url = source_fetch.url;
    defer allocator.free(url);
    const source_data = source_fetch.data;
    defer allocator.free(source_data);
    try verify_declared_source_md5(source_fetch, rock.source.md5);
    const source_hash = try blake3_prefixed(allocator, source_data);
    errdefer allocator.free(source_hash);
    if (expected_source_hash) |expected| if (!std.mem.eql(u8, expected, source_hash)) {
        @import("../../diagnostics/error_context.zig").setFmt(
            allocator,
            "locked LuaRocks source hash mismatch\nurl: {s}\nexpected: {s}\nactual: {s}",
            .{ url, expected, source_hash },
        );
        return error.LockedSourceHashMismatch;
    };
    const source_url = try allocator.dupe(u8, url);
    errdefer allocator.free(source_url);
    // The selected payload determines the archive format. `source.file`
    // describes the declared source and may name a tarball even when we chose
    // a `.src.rock` distribution artifact.
    const source_name = url;
    const source_kind = try allocator.dupe(u8, if (std.mem.endsWith(u8, source_name, ".src.rock")) "luarocks_src_rock" else "upstream_archive");
    errdefer allocator.free(source_kind);
    const source_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "source" });
    defer allocator.free(source_dir);

    // If it ends in .src.rock, it's a zip archive.
    if (std.mem.endsWith(u8, source_name, ".src.rock")) {
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
            .path = try select_rockspec_source_root(allocator, io, unpack_dir, rock.source.dir),
            .url = source_url,
            .hash = source_hash,
            .kind = source_kind,
            .payload_path = payload_path,
        };

        try std.Io.Dir.cwd().createDirPath(io, source_dir);
        try unpack_archive(allocator, io, pkg_name, version, tarball, tarball, source_dir);
        return .{
            .path = try select_rockspec_source_root(allocator, io, source_dir, rock.source.dir),
            .url = source_url,
            .hash = source_hash,
            .kind = source_kind,
            .payload_path = payload_path,
        };
    } else {
        // Direct archive download
        const suffix = archive_suffix(source_name);
        const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}{s}", .{ tmp_dir, pkg_name, version, suffix });
        defer allocator.free(archive_path);
        const f = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        try f.writeStreamingAll(io, source_data);
        f.close(io);

        try std.Io.Dir.cwd().createDirPath(io, source_dir);
        try unpack_archive(allocator, io, pkg_name, version, url, archive_path, source_dir);
        return .{
            .path = try select_rockspec_source_root(allocator, io, source_dir, rock.source.dir),
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

fn copy_provisions_from_root(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    destination_root: []const u8,
    provisions: []const manifest.FeatureProvision,
) !void {
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .follow_symlinks = false });
    defer source_dir.close(io);

    for (provisions) |provision| {
        if (!is_safe_relative_file_path(provision.path)) return error.InvalidLuaRocksMaterializedModulePath;
        const source_file = try source_dir.openFile(io, provision.path, .{
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        });
        source_file.close(io);

        const source_path = try std.fs.path.join(allocator, &.{ source_root, provision.path });
        defer allocator.free(source_path);
        const destination_path = try std.fs.path.join(allocator, &.{ destination_root, provision.path });
        defer allocator.free(destination_path);
        try std.Io.Dir.copyFileAbsolute(source_path, destination_path, io, .{ .make_path = true, .replace = true });
    }
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
    provisions: []const manifest.FeatureProvision,
) !void {
    const bins = bins_val orelse return;
    var source_dir = try std.Io.Dir.cwd().openDir(io, work_dir, .{ .follow_symlinks = false });
    defer source_dir.close(io);

    const Copy = struct {
        fn one(
            allocator_inner: std.mem.Allocator,
            io_inner: std.Io,
            source_dir_inner: std.Io.Dir,
            work_dir_inner: []const u8,
            files_bin_dir_inner: []const u8,
            bin_name: []const u8,
            source_relative_path: []const u8,
            known_provisions: []const manifest.FeatureProvision,
        ) !void {
            if (!is_safe_bin_name(bin_name)) return error.InvalidLuaRocksInstallBinName;
            if (!is_safe_relative_file_path(source_relative_path)) return error.InvalidLuaRocksInstallBinPath;
            const artifact_path = try std.fmt.allocPrint(allocator_inner, "bin/{s}", .{bin_name});
            defer allocator_inner.free(artifact_path);
            var declared = false;
            for (known_provisions) |provision| {
                if (std.mem.eql(u8, provision.path, artifact_path)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) return error.InvalidLuaRocksInstallBin;
            const source_file = try source_dir_inner.openFile(io_inner, source_relative_path, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            });
            source_file.close(io_inner);
            const source_path = try std.fs.path.join(allocator_inner, &.{ work_dir_inner, source_relative_path });
            defer allocator_inner.free(source_path);
            const destination_path = try std.fs.path.join(allocator_inner, &.{ files_bin_dir_inner, bin_name });
            defer allocator_inner.free(destination_path);
            try copy_executable_file(io_inner, source_path, destination_path);
        }
    };

    switch (bins) {
        .object => {
            var iterator = bins.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidLuaRocksInstallBin;
                try Copy.one(allocator, io, source_dir, work_dir, files_bin_dir, entry.key_ptr.*, entry.value_ptr.*.string, provisions);
            }
        },
        .array => for (bins.array.items) |entry| {
            if (entry != .string) return error.InvalidLuaRocksInstallBin;
            try Copy.one(allocator, io, source_dir, work_dir, files_bin_dir, std.fs.path.basename(entry.string), entry.string, provisions);
        },
        else => return error.InvalidLuaRocksInstallBin,
    }
}

fn copy_executable_file(io: std.Io, source_path: []const u8, destination_path: []const u8) !void {
    try std.Io.Dir.copyFileAbsolute(source_path, destination_path, io, .{ .replace = true });
    if (comptime target_builtin.os.tag == .windows) return;
    const destination_file = try std.Io.Dir.cwd().openFile(io, destination_path, .{});
    defer destination_file.close(io);
    try destination_file.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
}

fn build_bin_list(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
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

    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .follow_symlinks = false });
    defer source_dir.close(io);
    const Append = struct {
        fn one(
            allocator_inner: std.mem.Allocator,
            io_inner: std.Io,
            source_dir_inner: std.Io.Dir,
            bin_name: []const u8,
            source_relative_path: []const u8,
            output: *std.ArrayList(manifest.FeatureProvision),
        ) !void {
            if (!is_safe_bin_name(bin_name)) return error.InvalidLuaRocksInstallBinName;
            if (!is_safe_relative_file_path(source_relative_path)) return error.InvalidLuaRocksInstallBinPath;
            const source_file = try source_dir_inner.openFile(io_inner, source_relative_path, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            });
            source_file.close(io_inner);
            const name = try allocator_inner.dupe(u8, bin_name);
            errdefer allocator_inner.free(name);
            const path = try std.fmt.allocPrint(allocator_inner, "bin/{s}", .{bin_name});
            errdefer allocator_inner.free(path);
            try output.append(allocator_inner, .{ .name = name, .path = path });
        }
    };

    switch (bins) {
        .object => {
            var iterator = bins.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidLuaRocksInstallBin;
                try Append.one(allocator, io, source_dir, entry.key_ptr.*, entry.value_ptr.*.string, &list);
            }
        },
        .array => for (bins.array.items) |entry| {
            if (entry != .string) return error.InvalidLuaRocksInstallBin;
            try Append.one(allocator, io, source_dir, std.fs.path.basename(entry.string), entry.string, &list);
        },
        else => return error.InvalidLuaRocksInstallBin,
    }
    std.mem.sort(manifest.FeatureProvision, list.items, {}, less_than_provision_path);
    for (list.items, 0..) |provision, index| {
        if (index > 0 and std.mem.eql(u8, list.items[index - 1].path, provision.path)) {
            return error.LuaRocksInstallBinDestinationConflict;
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn deinit_provisions(allocator: std.mem.Allocator, provisions: []manifest.FeatureProvision) void {
    for (provisions) |provision| {
        allocator.free(provision.name);
        allocator.free(provision.path);
    }
    allocator.free(provisions);
}

fn less_than_provision_path(_: void, left: manifest.FeatureProvision, right: manifest.FeatureProvision) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn is_safe_copy_directory_path(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn is_safe_relative_file_path(path: []const u8) bool {
    if (!is_safe_copy_directory_path(path) or std.mem.endsWith(u8, path, "/")) return false;
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn is_safe_bin_name(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-' and character != '.') return false;
    }
    return true;
}

fn is_safe_luarocks_module_name(name: []const u8) bool {
    if (name.len == 0) return false;
    var segments = std.mem.splitScalar(u8, name, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        for (segment) |character| {
            if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return false;
        }
    }
    return true;
}

fn install_library_linkage(target: []const u8, basename: []const u8) !manifest.NativeLibraryLinkage {
    const effective_target = if (std.mem.eql(u8, target, "native")) platform_target.hostTargetLiteral() else target;
    if (std.mem.indexOf(u8, effective_target, "-windows-") != null) {
        if (std.mem.endsWith(u8, basename, ".dll")) return .shared;
        if (std.mem.endsWith(u8, basename, ".lib")) return .static;
        return error.UnsupportedLuaRocksInstallLibFilename;
    }
    if (std.mem.endsWith(u8, effective_target, "-macos")) {
        if (std.mem.endsWith(u8, basename, ".dylib")) return .shared;
        if (std.mem.endsWith(u8, basename, ".a")) return .static;
        return error.UnsupportedLuaRocksInstallLibFilename;
    }
    if (std.mem.indexOf(u8, effective_target, "-linux-") != null or std.mem.endsWith(u8, effective_target, "-freebsd")) {
        if (std.mem.endsWith(u8, basename, ".so") or std.mem.indexOf(u8, basename, ".so.") != null) return .shared;
        if (std.mem.endsWith(u8, basename, ".a")) return .static;
        return error.UnsupportedLuaRocksInstallLibFilename;
    }
    return error.UnsupportedLuaRocksInstallLibTarget;
}

fn install_library_artifact_path(
    allocator: std.mem.Allocator,
    source_relative_path: []const u8,
    logical_name: ?[]const u8,
) ![]const u8 {
    const basename = std.fs.path.basename(source_relative_path);
    if (logical_name) |name| {
        const module_path = try std.mem.replaceOwned(u8, allocator, name, ".", "/");
        defer allocator.free(module_path);
        return std.fs.path.join(allocator, &.{ "lib", "native", module_path, basename });
    }
    return std.fs.path.join(allocator, &.{ "lib", "native", basename });
}

fn append_luarocks_install_library(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    target: []const u8,
    source_relative_path: []const u8,
    logical_name: ?[]const u8,
    libraries: *std.ArrayList(manifest.FeatureProvision),
) !void {
    if (!is_safe_relative_file_path(source_relative_path)) return error.InvalidLuaRocksInstallLibPath;
    if (logical_name) |name| if (!is_safe_luarocks_module_name(name)) return error.InvalidLuaRocksInstallLibName;

    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .follow_symlinks = false });
    defer source_dir.close(io);
    const source_file = try source_dir.openFile(io, source_relative_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    source_file.close(io);

    const basename = std.fs.path.basename(source_relative_path);
    const linkage = try install_library_linkage(target, basename);
    const artifact_path = try install_library_artifact_path(allocator, source_relative_path, logical_name);
    errdefer allocator.free(artifact_path);
    const provision_name = try allocator.dupe(u8, logical_name orelse basename);
    errdefer allocator.free(provision_name);
    try libraries.append(allocator, .{
        .name = provision_name,
        .path = artifact_path,
        .linkage = linkage,
    });
}

fn sort_and_validate_install_libraries(libraries: *std.ArrayList(manifest.FeatureProvision)) !void {
    std.mem.sort(manifest.FeatureProvision, libraries.items, {}, less_than_provision_path);
    for (libraries.items, 0..) |library, index| {
        if (index > 0 and std.mem.eql(u8, libraries.items[index - 1].path, library.path)) {
            return error.LuaRocksInstallLibDestinationConflict;
        }
        if (library.linkage != .shared) continue;
        const basename = std.fs.path.basename(library.path);
        for (libraries.items[0..index]) |other| {
            if (other.linkage == .shared and std.mem.eql(u8, basename, std.fs.path.basename(other.path))) {
                return error.LuaRocksInstallLibLoaderCollision;
            }
        }
    }
}

fn collect_luarocks_install_libraries(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    target: []const u8,
    install_lib: ?std.json.Value,
) ![]manifest.FeatureProvision {
    var libraries = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (libraries.items) |library| {
            allocator.free(library.name);
            allocator.free(library.path);
        }
        libraries.deinit(allocator);
    }
    const declared = install_lib orelse return try libraries.toOwnedSlice(allocator);
    switch (declared) {
        .object => {
            var iterator = declared.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidLuaRocksInstallLib;
                try append_luarocks_install_library(allocator, io, source_root, target, entry.value_ptr.*.string, entry.key_ptr.*, &libraries);
            }
        },
        .array => for (declared.array.items) |entry| {
            if (entry != .string) return error.InvalidLuaRocksInstallLib;
            try append_luarocks_install_library(allocator, io, source_root, target, entry.string, null, &libraries);
        },
        else => return error.InvalidLuaRocksInstallLib,
    }
    try sort_and_validate_install_libraries(&libraries);
    return try libraries.toOwnedSlice(allocator);
}

fn copy_luarocks_install_libraries(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    build_out_dir: []const u8,
    install_lib: ?std.json.Value,
    libraries: []const manifest.FeatureProvision,
) !void {
    const declared = install_lib orelse return;
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .follow_symlinks = false });
    defer source_dir.close(io);

    const Copy = struct {
        fn one(
            allocator_inner: std.mem.Allocator,
            io_inner: std.Io,
            source_dir_inner: std.Io.Dir,
            source_root_inner: []const u8,
            build_out_dir_inner: []const u8,
            source_relative_path: []const u8,
            logical_name: ?[]const u8,
            known_libraries: []const manifest.FeatureProvision,
        ) !void {
            if (!is_safe_relative_file_path(source_relative_path)) return error.InvalidLuaRocksInstallLibPath;
            if (logical_name) |name| if (!is_safe_luarocks_module_name(name)) return error.InvalidLuaRocksInstallLibName;
            const artifact_path = try install_library_artifact_path(allocator_inner, source_relative_path, logical_name);
            defer allocator_inner.free(artifact_path);
            var declared_library = false;
            for (known_libraries) |library| {
                if (std.mem.eql(u8, library.path, artifact_path)) {
                    declared_library = true;
                    break;
                }
            }
            if (!declared_library) return error.InvalidLuaRocksInstallLib;
            const source_file = try source_dir_inner.openFile(io_inner, source_relative_path, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            });
            source_file.close(io_inner);
            const source_path = try std.fs.path.join(allocator_inner, &.{ source_root_inner, source_relative_path });
            defer allocator_inner.free(source_path);
            const destination_path = try std.fs.path.join(allocator_inner, &.{ build_out_dir_inner, artifact_path });
            defer allocator_inner.free(destination_path);
            try std.Io.Dir.copyFileAbsolute(source_path, destination_path, io_inner, .{ .make_path = true, .replace = true });
        }
    };

    switch (declared) {
        .object => {
            var iterator = declared.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidLuaRocksInstallLib;
                try Copy.one(allocator, io, source_dir, source_root, build_out_dir, entry.value_ptr.*.string, entry.key_ptr.*, libraries);
            }
        },
        .array => for (declared.array.items) |entry| {
            if (entry != .string) return error.InvalidLuaRocksInstallLib;
            try Copy.one(allocator, io, source_dir, source_root, build_out_dir, entry.string, null, libraries);
        },
        else => return error.InvalidLuaRocksInstallLib,
    }
}

fn append_asset_provision(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(manifest.FeatureProvision),
    relative_path: []const u8,
) !void {
    const artifact_path = try std.fs.path.join(allocator, &.{ "assets", relative_path });
    errdefer allocator.free(artifact_path);
    const asset_name = try allocator.dupe(u8, relative_path);
    errdefer allocator.free(asset_name);
    try assets.append(allocator, .{ .name = asset_name, .path = artifact_path });
}

fn is_luarocks_default_doc_name(name: []const u8) bool {
    const prefixes = [_][]const u8{ "readme", "license", "copying" };
    for (prefixes) |prefix| {
        if (name.len < prefix.len) continue;
        var matches = true;
        for (prefix, 0..) |character, index| {
            if (std.ascii.toLower(name[index]) != character) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".md");
}

fn append_default_root_document_assets(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    assets: *std.ArrayList(manifest.FeatureProvision),
) !void {
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .iterate = true });
    defer source_dir.close(io);
    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!is_luarocks_default_doc_name(entry.name)) continue;
        switch (entry.kind) {
            .file => {
                const relative_path = try std.fs.path.join(allocator, &.{ "doc", entry.name });
                defer allocator.free(relative_path);
                try append_asset_provision(allocator, assets, relative_path);
            },
            .sym_link => return error.UnsupportedLuaRocksCopyDirectorySymlink,
            else => {},
        }
    }
}

fn has_copy_directory(io: std.Io, path: []const u8) !bool {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    directory.close(io);
    return true;
}

fn append_copy_directory_assets(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    relative_dir: []const u8,
    assets: *std.ArrayList(manifest.FeatureProvision),
) !void {
    const source_dir_path = try std.fs.path.join(allocator, &.{ source_root, relative_dir });
    defer allocator.free(source_dir_path);

    var source_dir = try std.Io.Dir.cwd().openDir(io, source_dir_path, .{ .iterate = true });
    defer source_dir.close(io);
    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative_path = try std.fs.path.join(allocator, &.{ relative_dir, entry.name });
        defer allocator.free(relative_path);

        switch (entry.kind) {
            .directory => try append_copy_directory_assets(allocator, io, source_root, relative_path, assets),
            .file => try append_asset_provision(allocator, assets, relative_path),
            .sym_link => return error.UnsupportedLuaRocksCopyDirectorySymlink,
            else => return error.UnsupportedLuaRocksCopyDirectoryEntry,
        }
    }
}

fn copy_copy_directory_tree(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination_path);
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const source_entry = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_entry);
        const destination_entry = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
        defer allocator.free(destination_entry);

        switch (entry.kind) {
            .directory => try copy_copy_directory_tree(allocator, io, source_entry, destination_entry),
            .file => try std.Io.Dir.copyFileAbsolute(source_entry, destination_entry, io, .{ .replace = true }),
            .sym_link => return error.UnsupportedLuaRocksCopyDirectorySymlink,
            else => return error.UnsupportedLuaRocksCopyDirectoryEntry,
        }
    }
}

fn append_install_conf_asset(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    source_relative_path: []const u8,
    destination_relative_path: []const u8,
    assets: *std.ArrayList(manifest.FeatureProvision),
) !void {
    if (!is_safe_relative_file_path(source_relative_path) or !is_safe_relative_file_path(destination_relative_path)) {
        return error.InvalidLuaRocksInstallConfPath;
    }
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .follow_symlinks = false });
    defer source_dir.close(io);
    const source_file = try source_dir.openFile(io, source_relative_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    source_file.close(io);

    const asset_path = try std.fs.path.join(allocator, &.{ "conf", destination_relative_path });
    defer allocator.free(asset_path);
    try append_asset_provision(allocator, assets, asset_path);
}

fn append_luarocks_install_conf_assets(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    install_conf: ?std.json.Value,
    assets: *std.ArrayList(manifest.FeatureProvision),
) !void {
    const declared = install_conf orelse return;
    switch (declared) {
        .object => {
            var iterator = declared.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidLuaRocksInstallConf;
                try append_install_conf_asset(allocator, io, source_root, entry.value_ptr.*.string, entry.key_ptr.*, assets);
            }
        },
        .array => for (declared.array.items) |entry| {
            if (entry != .string) return error.InvalidLuaRocksInstallConf;
            try append_install_conf_asset(allocator, io, source_root, entry.string, std.fs.path.basename(entry.string), assets);
        },
        else => return error.InvalidLuaRocksInstallConf,
    }
}

fn append_cloned_provisions(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(manifest.FeatureProvision),
    source: []const manifest.FeatureProvision,
) !void {
    for (source) |provision| try output.append(allocator, .{
        .name = try allocator.dupe(u8, provision.name),
        .path = try allocator.dupe(u8, provision.path),
        .linkage = provision.linkage,
    });
}

fn sort_and_validate_asset_provisions(
    allocator: std.mem.Allocator,
    assets: *std.ArrayList(manifest.FeatureProvision),
) !void {
    std.mem.sort(manifest.FeatureProvision, assets.items, {}, less_than_provision_path);
    if (assets.items.len < 2) return;
    for (assets.items[1..], 1..) |asset, index| {
        if (std.mem.eql(u8, assets.items[index - 1].path, asset.path)) return error.LuaRocksInstallConfDestinationConflict;
    }
    _ = allocator;
}

fn collect_luarocks_assets(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    copy_directories: ?std.json.Value,
    install_conf: ?std.json.Value,
) ![]manifest.FeatureProvision {
    const copied_assets = try collect_copy_directory_assets(allocator, io, source_root, copy_directories);
    defer deinit_provisions(allocator, copied_assets);

    var assets = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (assets.items) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.path);
        }
        assets.deinit(allocator);
    }
    try append_cloned_provisions(allocator, &assets, copied_assets);
    try append_luarocks_install_conf_assets(allocator, io, source_root, install_conf, &assets);
    try sort_and_validate_asset_provisions(allocator, &assets);
    return try assets.toOwnedSlice(allocator);
}

fn copy_luarocks_install_conf_assets(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    build_out_dir: []const u8,
    install_conf: ?std.json.Value,
) !void {
    const declared = install_conf orelse return;
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .follow_symlinks = false });
    defer source_dir.close(io);

    const Copy = struct {
        fn one(
            allocator_inner: std.mem.Allocator,
            io_inner: std.Io,
            root: std.Io.Dir,
            source_root_path: []const u8,
            output_root: []const u8,
            source_relative_path: []const u8,
            destination_relative_path: []const u8,
        ) !void {
            if (!is_safe_relative_file_path(source_relative_path) or !is_safe_relative_file_path(destination_relative_path)) {
                return error.InvalidLuaRocksInstallConfPath;
            }
            const source_file = try root.openFile(io_inner, source_relative_path, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            });
            source_file.close(io_inner);
            const source_path = try std.fs.path.join(allocator_inner, &.{ source_root_path, source_relative_path });
            defer allocator_inner.free(source_path);
            const destination_path = try std.fs.path.join(allocator_inner, &.{ output_root, "assets", "conf", destination_relative_path });
            defer allocator_inner.free(destination_path);
            try std.Io.Dir.copyFileAbsolute(source_path, destination_path, io_inner, .{ .make_path = true, .replace = true });
        }
    };

    switch (declared) {
        .object => {
            var iterator = declared.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .string) return error.InvalidLuaRocksInstallConf;
                try Copy.one(allocator, io, source_dir, source_root, build_out_dir, entry.value_ptr.*.string, entry.key_ptr.*);
            }
        },
        .array => for (declared.array.items) |entry| {
            if (entry != .string) return error.InvalidLuaRocksInstallConf;
            try Copy.one(allocator, io, source_dir, source_root, build_out_dir, entry.string, std.fs.path.basename(entry.string));
        },
        else => return error.InvalidLuaRocksInstallConf,
    }
}

fn collect_copy_directory_assets(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    copy_directories: ?std.json.Value,
) ![]manifest.FeatureProvision {
    var assets = std.ArrayList(manifest.FeatureProvision).empty;
    errdefer {
        for (assets.items) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.path);
        }
        assets.deinit(allocator);
    }

    if (copy_directories) |declared| {
        if (declared != .array) return error.InvalidLuaRocksCopyDirectories;
        for (declared.array.items) |entry| {
            if (entry != .string or !is_safe_copy_directory_path(entry.string)) return error.InvalidLuaRocksCopyDirectoryPath;
            const source_dir_path = try std.fs.path.join(allocator, &.{ source_root, entry.string });
            defer allocator.free(source_dir_path);
            if (!try has_copy_directory(io, source_dir_path)) return error.LuaRocksCopyDirectoryNotFound;
            try append_copy_directory_assets(allocator, io, source_root, entry.string, &assets);
        }
    } else {
        const default_doc_path = try std.fs.path.join(allocator, &.{ source_root, "doc" });
        defer allocator.free(default_doc_path);
        if (try has_copy_directory(io, default_doc_path)) {
            try append_copy_directory_assets(allocator, io, source_root, "doc", &assets);
        } else {
            try append_default_root_document_assets(allocator, io, source_root, &assets);
        }
    }

    std.mem.sort(manifest.FeatureProvision, assets.items, {}, less_than_provision_path);
    var write_index: usize = 0;
    for (assets.items) |asset| {
        if (write_index > 0 and std.mem.eql(u8, assets.items[write_index - 1].path, asset.path)) {
            allocator.free(asset.name);
            allocator.free(asset.path);
            continue;
        }
        assets.items[write_index] = asset;
        write_index += 1;
    }
    assets.shrinkRetainingCapacity(write_index);
    return try assets.toOwnedSlice(allocator);
}

fn copy_luarocks_copy_directories(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    build_out_dir: []const u8,
    copy_directories: ?std.json.Value,
) !void {
    if (copy_directories) |declared| {
        if (declared != .array) return error.InvalidLuaRocksCopyDirectories;
        for (declared.array.items) |entry| {
            if (entry != .string or !is_safe_copy_directory_path(entry.string)) return error.InvalidLuaRocksCopyDirectoryPath;
            const source_dir_path = try std.fs.path.join(allocator, &.{ source_root, entry.string });
            defer allocator.free(source_dir_path);
            const destination_dir_path = try std.fs.path.join(allocator, &.{ build_out_dir, "assets", entry.string });
            defer allocator.free(destination_dir_path);
            try copy_copy_directory_tree(allocator, io, source_dir_path, destination_dir_path);
        }
    } else {
        const source_dir_path = try std.fs.path.join(allocator, &.{ source_root, "doc" });
        defer allocator.free(source_dir_path);
        if (try has_copy_directory(io, source_dir_path)) {
            const destination_dir_path = try std.fs.path.join(allocator, &.{ build_out_dir, "assets", "doc" });
            defer allocator.free(destination_dir_path);
            try copy_copy_directory_tree(allocator, io, source_dir_path, destination_dir_path);
        } else {
            var source_dir = try std.Io.Dir.cwd().openDir(io, source_root, .{ .iterate = true });
            defer source_dir.close(io);
            var iterator = source_dir.iterate();
            while (try iterator.next(io)) |entry| {
                if (!is_luarocks_default_doc_name(entry.name)) continue;
                switch (entry.kind) {
                    .file => {
                        const source_file_path = try std.fs.path.join(allocator, &.{ source_root, entry.name });
                        defer allocator.free(source_file_path);
                        const destination_file_path = try std.fs.path.join(allocator, &.{ build_out_dir, "assets", "doc", entry.name });
                        defer allocator.free(destination_file_path);
                        if (std.fs.path.dirname(destination_file_path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
                        try std.Io.Dir.copyFileAbsolute(source_file_path, destination_file_path, io, .{ .replace = true });
                    },
                    .sym_link => return error.UnsupportedLuaRocksCopyDirectorySymlink,
                    else => {},
                }
            }
        }
    }
}

fn compute_synthetic_recipe_hash(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    pkg_version: []const u8,
    pkg_kind: manifest.Kind,
    runtime_spec: []const u8,
    runtime_artifact_hash: []const u8,
    target: []const u8,
    source_hash: []const u8,
    source_transform_hash: []const u8,
    materializer: []const u8,
    lua_modules: []manifest.FeatureProvision,
    lua_cmodules: []manifest.FeatureProvision,
    bins: []manifest.FeatureProvision,
    native_libs: []manifest.FeatureProvision,
    assets: []manifest.FeatureProvision,
    build_env: []const manifest.EnvPair,
    build_artifacts: []const options_mod.BuildArtifact,
) ![]const u8 {
    var build_env_strings = std.ArrayList([]const u8).empty;
    defer {
        for (build_env_strings.items) |entry| allocator.free(entry);
        build_env_strings.deinit(allocator);
    }
    for (build_env) |entry| {
        try build_env_strings.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key, entry.value }));
    }

    var build_artifact_strings = std.ArrayList([]const u8).empty;
    defer {
        for (build_artifact_strings.items) |entry| allocator.free(entry);
        build_artifact_strings.deinit(allocator);
    }
    for (build_artifacts) |artifact| {
        try build_artifact_strings.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ artifact.name, artifact.artifact_hash }));
    }

    return store.computeRecipeHash(allocator, .{
        .kind = if (pkg_kind == .bin) "bin" else "lib",
        .name = pkg_name,
        .version = pkg_version,
        .source_hash = source_hash,
        .source_transform_hash = source_transform_hash,
        .materializer = materializer,
        .strategy = "rocks",
        .runtime_hash = runtime_artifact_hash,
        .lua_abi = runtime_spec,
        .target = target,
        .build_env = build_env_strings.items,
        .build_artifacts = build_artifact_strings.items,
        .collect = .{
            .lua_modules = lua_modules,
            .lua_cmodules = lua_cmodules,
            .bins = bins,
            .native_lib = native_libs,
            .assets = assets,
        },
    });
}

fn find_reusable_recipe_candidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: fs.MOONSTONE_PATHS,
    pkg_name: []const u8,
    pkg_version: []const u8,
    runtime_spec: []const u8,
    runtime_artifact_hash: []const u8,
    target: []const u8,
    recipe_hash: []const u8,
    source_url: []const u8,
    source_hash: []const u8,
    rockspec_url: []const u8,
    rockspec_hash: []const u8,
    base: []const u8,
    registry_name: ?[]const u8,
) !?candidate_mod.Candidate {
    const index_db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
    defer allocator.free(index_db_path);
    const index_db_path_z = try allocator.dupeZ(u8, index_db_path);
    defer allocator.free(index_db_path_z);

    var index = try driver_mod.StoreDriver.init(allocator, index_db_path_z);
    defer index.deinit();
    const matches = try index.findCandidates(.{
        .name = pkg_name,
        .resolver = "rocks",
        .version = pkg_version,
        .target = target,
        .lua_abi = runtime_spec,
        .recipe_hash = recipe_hash,
    });
    defer {
        for (matches) |*match| match.deinit(allocator);
        allocator.free(matches);
    }

    for (matches) |match| {
        std.Io.Dir.cwd().access(io, match.path, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };

        return .{
            .name = try allocator.dupe(u8, pkg_name),
            .version = try allocator.dupe(u8, pkg_version),
            .kind = match.kind,
            .artifact_hash = try allocator.dupe(u8, match.artifact_hash),
            .source = try allocator.dupe(u8, source_url),
            .source_hash = try allocator.dupe(u8, source_hash),
            .rockspec = try allocator.dupe(u8, rockspec_url),
            .rockspec_hash = try allocator.dupe(u8, rockspec_hash),
            .recipe_hash = try allocator.dupe(u8, recipe_hash),
            .runtime_artifact_hash = try allocator.dupe(u8, runtime_artifact_hash),
            .registry_name = try allocator.dupe(u8, registry_name orelse "rocks"),
            .local_path = try allocator.dupe(u8, match.path),
            .origin = .{ .luarocks = .{
                .url = try allocator.dupe(u8, base),
                .rockspec_path = try allocator.dupe(u8, ""),
            } },
        };
    }

    return null;
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
    source_transform_hash: []const u8,
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
    native_libs: []manifest.FeatureProvision,
    assets: []manifest.FeatureProvision,
    dependencies: []const manifest.StoreDependency,
    build_env: []const manifest.EnvPair,
    build_artifacts: []const options_mod.BuildArtifact,
    recipe_hash_override: ?[]const u8,
) !RockResult {
    const recipe_hash = if (recipe_hash_override) |provided|
        try allocator.dupe(u8, provided)
    else
        try compute_synthetic_recipe_hash(allocator, pkg_name, pkg_version, pkg_kind, runtime_spec, runtime_artifact_hash, target, source_hash, source_transform_hash, materializer, lua_modules, lua_cmodules, bins, native_libs, assets, build_env, build_artifacts);
    defer allocator.free(recipe_hash);
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
                    .native_lib = native_libs,
                    .lua_module = lua_modules,
                    .lua_cmodule = lua_cmodules,
                    .asset = assets,
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

pub fn materialize_prepared_rock(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version: []const u8,
    options: options_mod.ResolveOptions,
    env_map: *std.process.Environ.Map,
    base: []const u8,
    registry_name: ?[]const u8,
    prepared: *PreparedRock,
) !candidate_mod.Candidate {
    const runtime_spec = options.runtime orelse "lua54";
    const rock = prepared.parsed_rockspec.value;
    const intent = rock.intent;
    const rock_class = prepared.class;
    const paths = prepared.paths;
    const fetched_rockspec = prepared.fetched_rockspec;
    const fetched_source = prepared.fetched_source;
    const prepared_work_dir = fetched_source.path;
    const compatibility_recipe = prepared.compatibility_recipe;
    const lua_module_dir_version = try lua_module_directory_version(allocator, runtime_spec);
    defer allocator.free(lua_module_dir_version);
    const is_cmake_build = std.mem.eql(u8, rock_build_type(&intent), "cmake");
    const uses_foreign_build = rock_class == .command_build;

    var stable_workspace_lock: ?std.Io.File = null;
    defer if (stable_workspace_lock) |lock_file| {
        lock_file.unlock(io);
        lock_file.close(io);
    };
    var stable_workspace: ?[]const u8 = null;
    defer if (stable_workspace) |workspace| {
        std.Io.Dir.cwd().deleteTree(io, workspace) catch |err| if (err != error.FileNotFound) {};
        allocator.free(workspace);
    };

    const work_dir: []const u8 = if (uses_foreign_build) blk: {
        const target = options.target orelse "native";
        const workspace_name = try stable_source_build_workspace_name(
            allocator,
            pkg_name,
            version,
            fetched_source.hash,
            fetched_rockspec.hash,
            runtime_spec,
            target,
            options.build_env,
        );
        defer allocator.free(workspace_name);

        const locks_dir = try std.fs.path.join(allocator, &.{ paths.tmp, "source-build-locks" });
        defer allocator.free(locks_dir);
        try std.Io.Dir.cwd().createDirPath(io, locks_dir);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ locks_dir, workspace_name });
        defer allocator.free(lock_path);
        stable_workspace_lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{});
        try stable_workspace_lock.?.lock(io, .exclusive);

        const workspace = try std.fs.path.join(allocator, &.{ paths.tmp, workspace_name });
        errdefer allocator.free(workspace);
        std.Io.Dir.cwd().deleteTree(io, workspace) catch |err| if (err != error.FileNotFound) return err;
        try std.Io.Dir.cwd().createDirPath(io, workspace);
        stable_workspace = workspace;

        const source_dir = try std.fs.path.join(allocator, &.{ workspace, "source" });
        errdefer allocator.free(source_dir);
        try fs.copyTreeAbsolute(allocator, io, prepared_work_dir, source_dir);
        break :blk source_dir;
    } else prepared_work_dir;
    defer if (uses_foreign_build) allocator.free(work_dir);

    const build_out_dir: []const u8 = if (stable_workspace) |workspace|
        try std.fs.path.join(allocator, &.{ workspace, "out" })
    else
        prepared.build_out_path;
    defer if (stable_workspace != null) allocator.free(build_out_dir);
    if (stable_workspace != null) try std.Io.Dir.cwd().createDirPath(io, build_out_dir);

    const cmake_install_root = if (is_cmake_build)
        try std.fs.path.join(allocator, &.{ build_out_dir, cmake_mat.install_staging_dir_name })
    else
        null;
    defer if (cmake_install_root) |path| {
        std.Io.Dir.cwd().deleteTree(io, path) catch |err| if (err != error.FileNotFound) {};
        allocator.free(path);
    };
    const translated = prepared.translated;
    const rockspec_payload_path = prepared.rockspec_payload_path;

    const bin_val = if (intent.build.install) |install| install.bin else null;
    var bins: []manifest.FeatureProvision = &.{};
    defer deinit_provisions(allocator, bins);
    const copy_directories = if (intent.build_declaration == .object) intent.build_declaration.object.get("copy_directories") else null;
    const install_conf = if (intent.build.install) |install| install.conf else null;
    const install_lib = if (intent.build.install) |install| install.lib else null;
    var native_libs: []manifest.FeatureProvision = &.{};
    defer deinit_provisions(allocator, native_libs);
    var assets: []manifest.FeatureProvision = &.{};
    defer deinit_provisions(allocator, assets);

    if (rock_class != .command_build) {
        bins = try build_bin_list(allocator, io, work_dir, bin_val);
        native_libs = try collect_luarocks_install_libraries(allocator, io, work_dir, options.target orelse "native", install_lib);
        assets = try collect_luarocks_assets(allocator, io, work_dir, copy_directories, install_conf);
    }
    var pkg_kind: manifest.Kind = if (bins.len > 0) .bin else .lib;

    var store_deps = std.ArrayList(manifest.StoreDependency).empty;
    const dependency_sets = [_]struct {
        values: []const []const u8,
        role: manifest.DependencyRole,
    }{
        .{ .values = intent.dependencies, .role = .runtime },
        .{ .values = intent.build_dependencies, .role = .build },
    };
    for (dependency_sets) |set| for (set.values) |dep_str| {
        const parsed = try luarocks.parse_dependency_string(allocator, dep_str);
        defer parsed.deinit(allocator);
        const name_lower = try std.ascii.allocLowerString(allocator, parsed.name);
        defer allocator.free(name_lower);
        if (std.mem.eql(u8, name_lower, "lua")) continue;
        try store_deps.append(allocator, .{
            .name = try allocator.dupe(u8, parsed.name),
            .constraint = try allocator.dupe(u8, parsed.constraint orelse "*"),
            .resolver = try allocator.dupe(u8, "rocks"),
            .role = set.role,
        });
    };
    const store_deps_slice = try store_deps.toOwnedSlice(allocator);
    defer {
        for (store_deps_slice) |*dependency| dependency.deinit(allocator);
        allocator.free(store_deps_slice);
    }

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
    try append_external_path_recipe_environment(allocator, &recipe_build_env, translated, env_map);

    var lua_modules: []manifest.FeatureProvision = &.{};
    var lua_cmodules: []manifest.FeatureProvision = &.{};
    defer {
        deinit_provisions(allocator, lua_modules);
        deinit_provisions(allocator, lua_cmodules);
    }

    var prepared_recipe_hash: ?[]const u8 = null;
    defer if (prepared_recipe_hash) |recipe_hash| allocator.free(recipe_hash);
    var recipe_lock_file: ?std.Io.File = null;
    defer if (recipe_lock_file) |lock_file| {
        lock_file.unlock(io);
        lock_file.close(io);
    };

    if (rock_class != .command_build) {
        lua_modules = try build_lua_module_list_from_translated(allocator, translated);
        lua_cmodules = try build_c_module_list(allocator, translated);
        const recipe_hash = if (prepared.recipe_hash) |prepared_hash|
            try allocator.dupe(u8, prepared_hash)
        else
            try compute_synthetic_recipe_hash(
                allocator,
                rock.package,
                rock.version,
                pkg_kind,
                runtime_spec,
                options.runtime_artifact_hash orelse "",
                options.target orelse "native",
                fetched_source.hash,
                prepared.patch_transform_hash orelse "",
                "rocks-builtin",
                lua_modules,
                lua_cmodules,
                bins,
                native_libs,
                assets,
                recipe_build_env.items,
                options.build_artifacts,
            );
        prepared_recipe_hash = recipe_hash;

        const locks_dir = try std.fs.path.join(allocator, &.{ paths.tmp, "recipe-locks" });
        defer allocator.free(locks_dir);
        try std.Io.Dir.cwd().createDirPath(io, locks_dir);
        const lock_name_hash = if (std.mem.startsWith(u8, recipe_hash, "b3:")) recipe_hash[3..] else recipe_hash;
        const lock_name = try std.fmt.allocPrint(allocator, "{s}.lock", .{lock_name_hash});
        defer allocator.free(lock_name);
        const lock_path = try std.fs.path.join(allocator, &.{ locks_dir, lock_name });
        defer allocator.free(lock_path);
        recipe_lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{});
        try recipe_lock_file.?.lock(io, .exclusive);

        if (try find_reusable_recipe_candidate(
            allocator,
            io,
            paths,
            rock.package,
            rock.version,
            runtime_spec,
            options.runtime_artifact_hash orelse "",
            options.target orelse "native",
            recipe_hash,
            fetched_source.url,
            fetched_source.hash,
            fetched_rockspec.url,
            fetched_rockspec.hash,
            base,
            registry_name,
        )) |candidate| return candidate;
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
                command_mat.build(allocator, io, env_map, work_dir, build_out_dir, runtime_path, lua_module_dir_version, config, log_file_name, options.on_event, options.on_event_context) catch |err| {
                    @import("../../diagnostics/error_context.zig").setFmt(allocator, "command compilation failed for LuaRocks package {s}@{s}\nmodule: {s}\nsource: {s}\nreason: {s}", .{ pkg_name, version, mod.name, fetched_source.url, @errorName(err) });
                    return err;
                };
            } else if (std.mem.eql(u8, config.kind, "cmake")) {
                const log_file_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}.log", .{ pkg_name, version, hash_short });
                defer allocator.free(log_file_name);
                cmake_mat.build(allocator, io, env_map, work_dir, build_out_dir, runtime_path, lua_module_dir_version, config, log_file_name, .preserve_for_caller, options.on_event, options.on_event_context) catch |err| {
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

            try copy_executable_file(io, src_abs, dest_abs);
        }
    }

    // Foreign command backends may generate declared outputs after their build
    // completes. Make and command outputs live in the source workspace; CMake
    // installs into a disposable staging root. Each path remains explicit: no
    // backend may sweep arbitrary source, build, or install files into CAS.
    if (rock_class == .command_build) {
        const declared_output_root = cmake_install_root orelse work_dir;
        bins = try build_bin_list(allocator, io, declared_output_root, bin_val);
        native_libs = try collect_luarocks_install_libraries(allocator, io, declared_output_root, options.target orelse "native", install_lib);
        assets = try collect_luarocks_assets(allocator, io, declared_output_root, copy_directories, install_conf);
        pkg_kind = if (bins.len > 0) .bin else .lib;
    }

    // Copy declared binaries after source/build materialization. Builtin rocks
    // validate them before shared recipe reuse; command backends validate the
    // same declarations only after their foreign process creates the files.
    const files_bin_dir = try std.fs.path.join(allocator, &.{ build_out_dir, "bin" });
    defer allocator.free(files_bin_dir);
    try std.Io.Dir.cwd().createDirPath(io, files_bin_dir);
    const declared_output_root = cmake_install_root orelse work_dir;
    try copy_bins(allocator, io, declared_output_root, files_bin_dir, bin_val, bins);
    try copy_luarocks_copy_directories(allocator, io, declared_output_root, build_out_dir, copy_directories);
    try copy_luarocks_install_conf_assets(allocator, io, declared_output_root, build_out_dir, install_conf);
    try copy_luarocks_install_libraries(allocator, io, declared_output_root, build_out_dir, install_lib, native_libs);

    if (rock_class == .command_build) {
        const module_root = cmake_install_root orelse build_out_dir;
        const share_dir = try std.fs.path.join(allocator, &.{ module_root, "share", "lua", lua_module_dir_version });
        defer allocator.free(share_dir);
        const lib_dir = try std.fs.path.join(allocator, &.{ module_root, "lib", "lua", lua_module_dir_version });
        defer allocator.free(lib_dir);

        const share_prefix = try std.fmt.allocPrint(allocator, "share/lua/{s}", .{lua_module_dir_version});
        defer allocator.free(share_prefix);
        lua_modules = try discover_modules_from_dir(allocator, io, share_dir, share_prefix, ".lua");
        if (cmake_install_root) |root| try copy_provisions_from_root(allocator, io, root, build_out_dir, lua_modules);

        const lib_prefix = try std.fmt.allocPrint(allocator, "lib/lua/{s}", .{lua_module_dir_version});
        defer allocator.free(lib_prefix);
        lua_cmodules = try discover_modules_from_dir(allocator, io, lib_dir, lib_prefix, ".so");
        if (cmake_install_root) |root| try copy_provisions_from_root(allocator, io, root, build_out_dir, lua_cmodules);
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
        prepared.patch_transform_hash orelse "",
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
        native_libs,
        assets,
        store_deps_slice,
        recipe_build_env.items,
        options.build_artifacts,
        prepared_recipe_hash,
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
        .registry_name = try allocator.dupe(u8, registry_name orelse "rocks"),
        .local_path = try allocator.dupe(u8, commit_res.path),
        .origin = .{ .luarocks = .{ .url = try allocator.dupe(u8, base), .rockspec_path = try allocator.dupe(u8, "") } },
    };
}

/// Resolve a LuaRocks request through discovery and source preparation only.
/// A binary-rock result is already materialized; source results retain their
/// workspace until the caller elects one materialization owner.
pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version_range: []const u8,
    options: options_mod.ResolveOptions,
    env_map: *std.process.Environ.Map,
    base_override: ?[]const u8,
    registry_name: ?[]const u8,
) !PreparedResolution {
    if (options.offline) return error.PackageNotFound;

    const runtime_spec = options.runtime orelse "lua54";

    const base = base_override orelse get_luarocks_base(env_map);

    // Phase 1: Candidate discovery
    const manifest_parsed = try fetch_manifest(allocator, io, base, options.runtime, env_map, options.on_event, options.on_event_context, options.offline, options.cancellation_flag);
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
                return .{ .binary = .{
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
                } };
            }
        }
    }

    return .{ .source = try prepare_source_rock(allocator, io, pkg_name, version, runtime_spec, options, env_map, base) };
}

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
    var prepared = try prepare(allocator, io, pkg_name, version_range, options, env_map, base_override, registry_name);
    switch (prepared) {
        .binary => |candidate| return candidate,
        .source => |*source| {
            defer source.deinit();
            const base = base_override orelse get_luarocks_base(env_map);
            return materialize_prepared_rock(allocator, io, pkg_name, source.parsed_rockspec.value.version, options, env_map, base, registry_name, source);
        },
    }
}
