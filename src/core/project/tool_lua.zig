const std = @import("std");
const driver_mod = @import("../store/driver.zig");
const options_mod = @import("../resolution/options.zig");

pub const ToolLuaProvenance = struct {
    purpose: []const u8,
    source: []const u8, // "project-runtime", "global-toolchain", "path"
    runtime: []const u8,
    artifact_hash: ?[]const u8,
    executable: []const u8,

    pub fn deinit(self: *ToolLuaProvenance, allocator: std.mem.Allocator) void {
        allocator.free(self.purpose);
        allocator.free(self.source);
        allocator.free(self.runtime);
        if (self.artifact_hash) |h| allocator.free(h);
        allocator.free(self.executable);
    }
};

/// Find a Lua interpreter for Moonstone internal tooling (rockspec parsing, etc.).
/// Does NOT assume the project runtime provides a CLI lua binary.
///
/// Resolution order:
/// 1. Project runtime — if it provides bin/lua or bin/luajit with matching ABI.
/// 2. Global Moonstone tool Lua — configured via moon toolchain or similar.
/// 3. PATH fallback — searches for lua/luajit in PATH (warns about host-dependency).
/// 4. Error — tells user to configure a tool Lua.
pub fn findToolLua(
    allocator: std.mem.Allocator,
    io: std.Io,
    idx: driver_mod.StoreDriver,
    required_abi: []const u8,
    purpose: []const u8,
    env_map: ?*std.process.Environ.Map,
) !ToolLuaProvenance {
    // 1. Check if project runtime provides a plain lua/luajit binary
    const project_rt = try findProjectRuntimeLua(allocator, io, idx, required_abi);
    defer if (project_rt) |pr| allocator.free(pr.executable);
    if (project_rt) |pr| {
        return ToolLuaProvenance{
            .purpose = try allocator.dupe(u8, purpose),
            .source = try allocator.dupe(u8, "project-runtime"),
            .runtime = try allocator.dupe(u8, pr.runtime_name),
            .artifact_hash = if (pr.artifact_hash) |h| try allocator.dupe(u8, h) else null,
            .executable = try allocator.dupe(u8, pr.executable),
        };
    }

    // 2. Check for global Moonstone tool Lua
    const global_rt = try findGlobalToolLua(allocator, io, idx, required_abi);
    defer if (global_rt) |gr| allocator.free(gr.executable);
    if (global_rt) |gr| {
        return ToolLuaProvenance{
            .purpose = try allocator.dupe(u8, purpose),
            .source = try allocator.dupe(u8, "global-toolchain"),
            .runtime = try allocator.dupe(u8, gr.runtime_name),
            .artifact_hash = if (gr.artifact_hash) |h| try allocator.dupe(u8, h) else null,
            .executable = try allocator.dupe(u8, gr.executable),
        };
    }

    // 3. PATH fallback
    const path_rt = try findPathLua(allocator, io, required_abi, env_map);
    defer if (path_rt) |pr| allocator.free(pr.executable);
    if (path_rt) |pr| {
        // Log warning about host-dependent fallback
        const stderr = std.Io.File.stderr();
        var buf: [512]u8 = undefined;
        var writer = stderr.writer(io, &buf);
        try writer.interface.print("warning: Using host PATH Lua interpreter for {s}.\n         This is host-dependent and may break reproducibility.\n         Run `moon toolchain use lua@5.1` to configure a Moonstone-managed tool Lua.\n", .{purpose});
        try writer.interface.flush();
        return ToolLuaProvenance{
            .purpose = try allocator.dupe(u8, purpose),
            .source = try allocator.dupe(u8, "path"),
            .runtime = try allocator.dupe(u8, pr.runtime_name),
            .artifact_hash = null,
            .executable = try allocator.dupe(u8, pr.executable),
        };
    }

    // 4. Fail with actionable message
    return error.NoToolLuaAvailable;
}

const LuaCandidate = struct {
    executable: []const u8,
    runtime_name: []const u8,
    artifact_hash: ?[]const u8,
};

fn findProjectRuntimeLua(allocator: std.mem.Allocator, io: std.Io, idx: driver_mod.StoreDriver, required_abi: []const u8) !?LuaCandidate {
    // Query the active project runtime from env.toml
    // For now, simplified: look for any runtime artifact that provides bin/lua with matching ABI
    const sql =
        \\SELECT a.path, a.name, a.version, a.artifact_hash
        \\FROM artifacts a
        \\JOIN provides_bin pb ON a.artifact_hash = pb.artifact_hash
        \\WHERE a.kind = 'runtime'
        \\  AND (pb.name = 'lua' OR pb.name = 'luajit')
        \\  AND (a.lua_abi = ? OR a.lua_abi = ?)
        \\LIMIT 1;
    ;

    var stmt: ?*driver_mod.c.sqlite3_stmt = null;
    if (driver_mod.c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != driver_mod.c.SQLITE_OK) return null;
    defer _ = driver_mod.c.sqlite3_finalize(stmt);

    const transient = driver_mod.moonstone_sqlite_transient_ptr;
    _ = driver_mod.c.sqlite3_bind_text(stmt, 1, required_abi.ptr, @intCast(required_abi.len), transient);
    // Also try normalized form
    var abi_buf: [8]u8 = undefined;
    const normalized = options_mod.normalizeRuntimeAbi(required_abi, &abi_buf);
    _ = driver_mod.c.sqlite3_bind_text(stmt, 2, normalized.ptr, @intCast(normalized.len), transient);

    if (driver_mod.c.sqlite3_step(stmt) == driver_mod.c.SQLITE_ROW) {
        const rt_path = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 0));
        const rt_name = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 1));
        const rt_ver = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 2));
        const art_hash = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 3));

        const exe_path = try std.fs.path.join(allocator, &.{ rt_path, "files", "bin", rt_name });
        if (std.Io.Dir.cwd().access(io, exe_path, .{})) |_| {
            return LuaCandidate{
                .executable = exe_path,
                .runtime_name = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rt_name, rt_ver }),
                .artifact_hash = try allocator.dupe(u8, art_hash),
            };
        } else |_| {
            allocator.free(exe_path);
        }
    }
    return null;
}

fn findGlobalToolLua(allocator: std.mem.Allocator, io: std.Io, idx: driver_mod.StoreDriver, required_abi: []const u8) !?LuaCandidate {
    // TODO: Implement global toolchain lookup once `moon toolchain use` exists.
    // For now, check if there's a globally installed lua/luajit runtime in the store.
    const sql =
        \\SELECT a.path, a.name, a.version, a.artifact_hash
        \\FROM artifacts a
        \\JOIN provides_bin pb ON a.artifact_hash = pb.artifact_hash
        \\WHERE a.kind = 'runtime'
        \\  AND (pb.name = 'lua' OR pb.name = 'luajit')
        \\  AND (a.lua_abi = ? OR a.lua_abi = ?)
        \\  AND a.artifact_hash LIKE 'b3:%'
        \\ORDER BY a.version DESC
        \\LIMIT 1;
    ;

    var stmt: ?*driver_mod.c.sqlite3_stmt = null;
    if (driver_mod.c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != driver_mod.c.SQLITE_OK) return null;
    defer _ = driver_mod.c.sqlite3_finalize(stmt);

    const transient = driver_mod.moonstone_sqlite_transient_ptr;
    _ = driver_mod.c.sqlite3_bind_text(stmt, 1, required_abi.ptr, @intCast(required_abi.len), transient);
    var abi_buf: [8]u8 = undefined;
    const normalized = options_mod.normalizeRuntimeAbi(required_abi, &abi_buf);
    _ = driver_mod.c.sqlite3_bind_text(stmt, 2, normalized.ptr, @intCast(normalized.len), transient);

    if (driver_mod.c.sqlite3_step(stmt) == driver_mod.c.SQLITE_ROW) {
        const rt_path = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 0));
        const rt_name = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 1));
        const rt_ver = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 2));
        const art_hash = std.mem.span(driver_mod.c.sqlite3_column_text(stmt, 3));

        const exe_path = try std.fs.path.join(allocator, &.{ rt_path, "files", "bin", rt_name });
        if (std.Io.Dir.cwd().access(io, exe_path, .{})) |_| {
            return LuaCandidate{
                .executable = exe_path,
                .runtime_name = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ rt_name, rt_ver }),
                .artifact_hash = try allocator.dupe(u8, art_hash),
            };
        } else |_| {
            allocator.free(exe_path);
        }
    }
    return null;
}

fn findPathLua(allocator: std.mem.Allocator, io: std.Io, required_abi: []const u8, env_map: ?*std.process.Environ.Map) !?LuaCandidate {
    _ = required_abi;
    if (env_map) |em| {
        if (em.get("PATH")) |paths| {
            var path_it = std.mem.splitScalar(u8, paths, std.fs.path.delimiter);
            while (path_it.next()) |dir| {
                if (dir.len == 0) continue;
                const binaries = [_][]const u8{ "luajit", "lua" };
                for (binaries) |binary| {
                    const candidate = try std.fs.path.join(allocator, &.{ dir, binary });
                    if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| {
                        return LuaCandidate{
                            .executable = candidate,
                            .runtime_name = try allocator.dupe(u8, binary),
                            .artifact_hash = null,
                        };
                    } else |_| {
                        allocator.free(candidate);
                    }
                }
            }
        }
    }
    return null;
}
