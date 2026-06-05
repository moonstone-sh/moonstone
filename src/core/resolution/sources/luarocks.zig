const std = @import("std");
const manifest = @import("../../domain/manifest.zig");
const fs = @import("../../platform/fs.zig");
const http = @import("../../platform/http.zig");
const store = @import("../../store.zig");
const hash = @import("../../identity/hash.zig");
const luarocks = @import("../../luarocks/rockspec.zig");
const options_mod = @import("../options.zig");
const candidate_mod = @import("../candidate.zig");

fn get_luarocks_base(env_map: *std.process.Environ.Map) []const u8 {
    return env_map.get("MOONSTONE_LUAROCKS_URL") orelse "https://luarocks.org";
}

// ---------------------------------------------------------------------------
// Phase 1 — Candidate discovery
// ---------------------------------------------------------------------------

fn http_get_single(allocator: std.mem.Allocator, io: std.Io, url: []const u8, timeout_ms: u32) ![]u8 {
    const resp = try http.fetchGet(allocator, io, url, null, timeout_ms);
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
) ![]u8 {
    const net_cfg = fs.get_network_config(allocator, env_map, io);
    const http_cfg = http.get_http_config(allocator, env_map, io);

    const max_retries = net_cfg.retries;
    const delay_seconds = net_cfg.retry_delay;

    var attempt: u32 = 0;
    while (true) {
        if (http_get_single(allocator, io, url, http_cfg.timeout_ms)) |data| {
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
) !std.json.Parsed(std.json.Value) {
    const url = try runtime_to_manifest_url(allocator, base, runtime);
    defer allocator.free(url);
    const body = http_get(allocator, io, url, env_map, on_event, on_event_context) catch |err| {
        // TODO: handle err
        std.debug.print("luarocks source error: {s}\n", .{@errorName(err)});
        return error.RocksVersionDiscoveryFailed;
    };
    defer allocator.free(body);
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

const TranslatedModule = struct {
    name: []const u8,
    kind: enum { lua, c },
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
                for (c.cmake_args) |a| allocator.free(a);
                allocator.free(c.cmake_args);
            }
        }
        list.deinit(allocator);
    }

    const lua_ver_dot = if (std.mem.startsWith(u8, lua_abi, "lua") and lua_abi.len == 5)
        try std.fmt.allocPrint(allocator, "{c}.{c}", .{ lua_abi[3], lua_abi[4] })
    else
        try allocator.dupe(u8, lua_abi);
    defer allocator.free(lua_ver_dot);

    const modules = rock.build.modules orelse return try list.toOwnedSlice(allocator);
    if (modules != .object) return try list.toOwnedSlice(allocator);

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
                    .cmake_args = try ldflags.toOwnedSlice(allocator),
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

    return try list.toOwnedSlice(allocator);
}

/// Pick the newest version that has a source rockspec.
fn select_version(allocator: std.mem.Allocator, manifest_json: std.json.Value, pkg_name: []const u8, version_range: []const u8) ![]const u8 {
    // If user gave an exact version (or constraint prefix), strip it and trust it exists.
    if (!std.mem.eql(u8, version_range, "*") and !std.mem.eql(u8, version_range, "")) {
        const ver = if (version_range.len > 0 and (version_range[0] == '^' or version_range[0] == '~' or version_range[0] == '='))
            version_range[1..]
        else
            version_range;
        return try allocator.dupe(u8, ver);
    }

    const repository = manifest_json.object.get("repository") orelse {
        return error.RocksVersionDiscoveryFailed;
    };
    const pkg_entry = repository.object.get(pkg_name) orelse {
        return error.PackageNotFound;
    };

    var best_version: ?[]const u8 = null;
    var it = pkg_entry.object.iterator();
    while (it.next()) |entry| {
        const version_key = entry.key_ptr.*;
        const arch_list = entry.value_ptr.array;
        var has_rockspec = false;
        for (arch_list.items) |arch_entry| {
            const arch_val = arch_entry.object.get("arch") orelse continue;
            if (std.mem.eql(u8, arch_val.string, "rockspec")) {
                has_rockspec = true;
                break;
            }
        }
        if (!has_rockspec) continue;

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

const RockResult = struct { path: []const u8, hash: []const u8 };

/// Download a binary .rock from LuaRocks, unpack it, and commit to store.
/// Returns the store path and artifact hash.
fn resolve_binary_rock(
    allocator: std.mem.Allocator,
    io: std.Io,
    pkg_name: []const u8,
    version: []const u8,
    runtime_spec: []const u8,
    env_map: *std.process.Environ.Map,
    on_event: ?options_mod.ResolveCallback,
    on_event_context: ?*anyopaque,
) !RockResult {
    const base = get_luarocks_base(env_map);
    const arch_str = (try host_to_luarocks_arch(allocator)) orelse return error.UnsupportedArchitecture;
    defer allocator.free(arch_str);

    const url = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.{s}.rock", .{ base, pkg_name, version, arch_str });
    defer allocator.free(url);

    const rock_data = try http_get(allocator, io, url, env_map, on_event, on_event_context);
    defer allocator.free(rock_data);

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

    try unpack_archive(allocator, io, archive_path, unpack_dir);

    const commit_res = try commit_synthetic_artifact(
        allocator,
        io,
        env_map,
        unpack_dir,
        pkg_name,
        version,
        .lib,
        runtime_spec,
        "rocks-binary",
        &.{},
        &.{},
        &.{},
        &.{},
    );
    return RockResult{ .path = commit_res.path, .hash = commit_res.hash };
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
) ![]const u8 {
    // If version already includes a LuaRocks revision (e.g. "3.1.3-1"), try exact rockspec first.
    if (has_luarocks_revision(version)) {
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.rockspec", .{
            base, pkg_name, version,
        });
        defer allocator.free(url);
        const content = http_get(allocator, io, url, env_map, on_event, on_event_context) catch |err| blk: {
            if (err == error.HttpError or err == error.FileNotFound) break :blk null;
            return err;
        };
        if (content) |c| {
            if (std.mem.indexOf(u8, c, "package =") != null) {
                return c;
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
        const content = http_get(allocator, io, url, env_map, on_event, on_event_context) catch |err| {
            if (err == error.HttpError or err == error.FileNotFound) continue;
            return err;
        };
        if (std.mem.indexOf(u8, content, "package =") != null) {
            return content;
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
    const is_builtin = rock.build.type.len == 0 or std.mem.eql(u8, rock.build.type, "builtin");
    const is_make = std.mem.eql(u8, rock.build.type, "make");
    const is_cmake = std.mem.eql(u8, rock.build.type, "cmake");
    const is_command = std.mem.eql(u8, rock.build.type, "command");

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

fn unpack_archive(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, out_dir: []const u8) !void {
    const is_zip = std.mem.endsWith(u8, archive_path, ".zip") or
        std.mem.endsWith(u8, archive_path, ".src.rock") or
        std.mem.endsWith(u8, archive_path, ".rock");
    const is_tar_gz = std.mem.endsWith(u8, archive_path, ".tar.gz") or
        std.mem.endsWith(u8, archive_path, ".tgz") or
        std.mem.endsWith(u8, archive_path, ".gz");
    const is_tar = std.mem.endsWith(u8, archive_path, ".tar");

    if (is_zip) {
        const res = try std.process.run(allocator, io, .{
            .argv = &.{ "unzip", "-q", archive_path, "-d", out_dir },
        });
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return error.UnpackError;
    } else if (is_tar_gz) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = try std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xzf", archive_path, "-C", out_dir },
        });
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return error.UnpackError;
    } else if (is_tar) {
        try std.Io.Dir.cwd().createDirPath(io, out_dir);
        const res = try std.process.run(allocator, io, .{
            .argv = &.{ "tar", "-xf", archive_path, "-C", out_dir },
        });
        defer allocator.free(res.stdout);
        defer allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) return error.UnpackError;
    } else {
        return error.UnsupportedArchiveFormat;
    }
}

fn compute_dir_hash(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const raw = try hash.artifact_hash(allocator, io, dir);
    return try std.fmt.allocPrint(allocator, "b3:{s}", .{raw});
}

pub fn find_runtime_lua_executable(allocator: std.mem.Allocator, io: std.Io, runtime_path: []const u8) ![]const u8 {
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
) ![]const u8 {
    // 5a. Prefer the LuaRocks source rock when available. Many modern
    // rockspecs point source.url at git+https repositories, while LuaRocks
    // also publishes a .src.rock archive that Moonstone can fetch over HTTPS.
    const guessed_src_rock = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.src.rock", .{ base, pkg_name, version });
    defer allocator.free(guessed_src_rock);

    const url = blk: {
        const src_rock_data = http_get(allocator, io, guessed_src_rock, env_map, on_event, on_event_context) catch |err| {
            if (err != error.HttpError and err != error.FileNotFound and err != error.UnsupportedUriScheme) return err;
            break :blk if (rock.source.url.len > 0) try allocator.dupe(u8, rock.source.url) else return error.SourceRockNotFound;
        };
        allocator.free(src_rock_data);
        break :blk try allocator.dupe(u8, guessed_src_rock);
    };
    defer allocator.free(url);

    const source_data = http_get(allocator, io, url, env_map, on_event, on_event_context) catch |err| {
        if (err == error.HttpError and rock.source.url.len == 0) return error.SourceRockNotFound;
        return err;
    };
    defer allocator.free(source_data);
    const source_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "source" });
    defer allocator.free(source_dir);

    // If it ends in .src.rock, it's a zip archive.
    if (std.mem.endsWith(u8, url, ".src.rock")) {
        const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir, "source.src.rock" });
        defer allocator.free(archive_path);
        const f = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        try f.writeStreamingAll(io, source_data);
        f.close(io);

        const unpack_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "unpack" });
        defer allocator.free(unpack_dir);
        try std.Io.Dir.cwd().createDirPath(io, unpack_dir);

        try unpack_archive(allocator, io, archive_path, unpack_dir);

        // Find the actual source tarball inside the src.rock
        var up_dir = try std.Io.Dir.cwd().openDir(io, unpack_dir, .{ .iterate = true });
        defer up_dir.close(io);
        var up_it = up_dir.iterate();
        var source_tarball_path: ?[]const u8 = null;
        while (try up_it.next(io)) |entry| {
            if (entry.kind == .file) {
                const name = entry.name;
                if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz") or std.mem.endsWith(u8, name, ".zip") or std.mem.endsWith(u8, name, ".tar")) {
                    source_tarball_path = try std.fs.path.join(allocator, &.{ unpack_dir, name });
                    break;
                }
            }
        }
        const tarball = source_tarball_path orelse return try find_source_root(allocator, io, unpack_dir);

        try std.Io.Dir.cwd().createDirPath(io, source_dir);
        try unpack_archive(allocator, io, tarball, source_dir);
    } else {
        // Direct archive download
        const ext = std.fs.path.extension(url);
        const archive_path = try std.fmt.allocPrint(allocator, "{s}/source{s}", .{ tmp_dir, ext });
        defer allocator.free(archive_path);
        const f = try std.Io.Dir.cwd().createFile(io, archive_path, .{});
        try f.writeStreamingAll(io, source_data);
        f.close(io);

        try std.Io.Dir.cwd().createDirPath(io, source_dir);
        try unpack_archive(allocator, io, archive_path, source_dir);
    }

    return try find_source_root(allocator, io, source_dir);
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
    materializer: []const u8,
    lua_modules: []manifest.FeatureProvision,
    lua_cmodules: []manifest.FeatureProvision,
    bins: []manifest.FeatureProvision,
    dependencies: []const manifest.StoreDependency,
) !RockResult {
    const recipe_hash = try store.computeRecipeHash(allocator, .{
        .kind = if (pkg_kind == .bin) "bin" else "lib",
        .name = pkg_name,
        .version = pkg_version,
        .source_hash = "",
        .materializer = materializer,
        .strategy = "rocks",
        .lua_abi = runtime_spec,
        .target = "native",
        .collect = .{
            .lua_modules = lua_modules,
            .lua_cmodules = lua_cmodules,
            .bins = bins,
        },
    });
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
                .target = "native",
                .lua_abi = runtime_spec,
                .url = "",
                .hash = art_hash_dup,
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

    const source_str = try std.fmt.allocPrint(allocator, "rocks:{s}", .{pkg_name});
    defer allocator.free(source_str);

    const store_path = try store.commit_to_store(allocator, io, env_map, build_out_dir, synthetic_desc, synthetic_desc.artifact[0], "rocks", source_str, deps_copy);

    return RockResult{ .path = store_path, .hash = try allocator.dupe(u8, art_hash) };
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
) !candidate_mod.Candidate {
    if (options.offline) return error.PackageNotFound;

    const runtime_spec = options.runtime orelse "lua54";

    const base = get_luarocks_base(env_map);

    // Phase 1: Candidate discovery
    const manifest_parsed = try fetch_manifest(allocator, io, base, options.runtime, env_map, options.on_event, options.on_event_context);
    defer manifest_parsed.deinit();
    const manifest_json = manifest_parsed.value;

    const version = try select_version(allocator, manifest_json, pkg_name, version_range);
    defer allocator.free(version);

    // Phase 2: Prefer binary rock if safe
    if (try host_to_luarocks_arch(allocator)) |arch_str| {
        defer allocator.free(arch_str);
        if (has_binary_rock(manifest_json, pkg_name, version, arch_str)) {
            const bin_res = blk: {
                break :blk resolve_binary_rock(allocator, io, pkg_name, version, runtime_spec, env_map, options.on_event, options.on_event_context) catch |err| {
                    if (err != error.BinaryRockNotImplemented) return err;
                    break :blk null;
                };
            };
            if (bin_res) |res| {
                defer allocator.free(res.path);
                return candidate_mod.Candidate{
                    .name = try allocator.dupe(u8, pkg_name),
                    .version = try allocator.dupe(u8, version),
                    .kind = .lib,
                    .artifact_hash = res.hash,
                    .registry_name = try allocator.dupe(u8, "rocks"),
                    .local_path = try allocator.dupe(u8, res.path),
                    .origin = .{ .luarocks = .{ .url = try allocator.dupe(u8, base), .rockspec_path = try allocator.dupe(u8, "") } },
                };
            }
        }
    }

    // Phase 3: Fetch rockspec
    const rockspec_content = try fetch_rockspec(allocator, io, base, pkg_name, version, env_map, options.on_event, options.on_event_context);
    defer allocator.free(rockspec_content);

    // Phase 4: Classify
    const rt_path = options.runtime_path orelse return error.RuntimeRequiredForParsing;
    const lua_exe = try find_runtime_lua_executable(allocator, io, rt_path);
    defer allocator.free(lua_exe);

    var rock_parsed = try luarocks.parse_rockspec(allocator, io, rockspec_content, lua_exe);
    defer rock_parsed.deinit();
    const rock = rock_parsed.value;

    const rock_class = classify_rock(&rock);
    switch (rock_class) {
        .pure_lua, .builtin_cmodule => {}, // Continue below
        .command_build => {
            return error.UnsupportedLuaRocksBuildType;
        },
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

    const work_dir = fetch_and_unpack_source(allocator, io, base, pkg_name, version, &rock, tmp_dir, env_map, options.on_event, options.on_event_context) catch |err| {
        return err;
    };
    defer allocator.free(work_dir);

    // Phase 6: Translate to Moonstone recipe
    const build_out_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "out" });
    defer allocator.free(build_out_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_out_dir);

    const translated = try translateBuiltinBuild(allocator, &rock, runtime_spec);
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
                for (c.cmake_args) |a| allocator.free(a);
                allocator.free(c.cmake_args);
            }
        }
        allocator.free(translated);
    }

    const native_cmodule = @import("../../materialization/materializers/native_cmodule.zig");
    const runtime_path = options.runtime_path orelse return error.RuntimePathRequired;

    for (translated) |mod| {
        if (mod.kind == .c) {
            try native_cmodule.build(allocator, io, env_map, work_dir, build_out_dir, runtime_path, mod.config.?);
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

    const lua_modules = try build_lua_module_list_from_translated(allocator, translated);
    defer {
        for (lua_modules) |m| {
            allocator.free(m.name);
            allocator.free(m.path);
        }
        allocator.free(lua_modules);
    }

    const lua_cmodules = try build_c_module_list(allocator, translated);
    defer {
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
    const commit_res = try commit_synthetic_artifact(
        allocator,
        io,
        env_map,
        build_out_dir,
        rock.package,
        rock.version,
        pkg_kind,
        runtime_spec,
        "rocks-builtin",
        lua_modules,
        lua_cmodules,
        bins,
        store_deps_slice,
    );
    defer allocator.free(commit_res.path);
    defer allocator.free(commit_res.hash);

    return candidate_mod.Candidate{
        .name = try allocator.dupe(u8, rock.package),
        .version = try allocator.dupe(u8, rock.version),
        .kind = pkg_kind,
        .artifact_hash = try allocator.dupe(u8, commit_res.hash),
        .registry_name = try allocator.dupe(u8, "rocks"),
        .local_path = try allocator.dupe(u8, commit_res.path),
        .origin = .{ .luarocks = .{ .url = try allocator.dupe(u8, base), .rockspec_path = try allocator.dupe(u8, "") } },
    };
}
