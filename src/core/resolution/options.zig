const std = @import("std");
const coordinator = @import("coordinator.zig");
const runtime_c_api = @import("../runtime/c_api.zig");

pub const ResolveOptions = struct {
    offline: bool = false,
    runtime: ?[]const u8 = null,
    runtime_c_api: runtime_c_api.Profile = .unknown,
    runtime_path: ?[]const u8 = null,
    locked: bool = false,
    prefer_local: bool = false,
    target: ?[]const u8 = null,
    on_event: ?ResolveCallback = null,
    runtime_artifact_hash: ?[]const u8 = null,
    lua_exe: ?[]const u8 = null,
    on_event_context: ?*anyopaque = null,
    build_env: []const @import("../domain/manifest.zig").EnvPair = &.{},
    build_artifacts: []const BuildArtifact = &.{},
    cancellation_flag: ?*const std.atomic.Value(bool) = null,
    locked_rockspec_url: ?[]const u8 = null,
    locked_rockspec_hash: ?[]const u8 = null,
    locked_source_url: ?[]const u8 = null,
    locked_source_hash: ?[]const u8 = null,
};

/// One already-resolved artifact made visible only to a foreign build. The
/// identity participates in its dependent recipe; its filesystem projection is
/// assembled separately by `project.build_scope`.
pub const BuildArtifact = struct {
    name: []const u8,
    artifact_hash: []const u8,
};

pub const ResolveEvent = union(enum) {
    status: struct {
        pkg_name: []const u8,
        msg: []const u8,
    },
    retry: struct {
        url: []const u8,
        err_name: []const u8,
        attempt: u32,
        max_retries: u32,
        delay_seconds: u32,
    },
    download_progress: struct {
        url: []const u8,
        pkg_name: ?[]const u8,
        downloaded_bytes: usize,
        total_bytes: ?usize,
    },
    metadata_sync_started: []const u8,
    metadata_sync_done: []const u8,
    build_failed: struct {
        pkg_name: []const u8,
        command: []const u8,
        stderr_tail: []const u8,
        log_path: ?[]const u8,
    },
};

pub const ResolveCallback = *const fn (ctx: ?*anyopaque, event: ResolveEvent) void;

pub fn normalizeRuntimeAbi(input: []const u8, out: *[8]u8) []const u8 {
    if (std.mem.eql(u8, input, "luajit") or std.mem.eql(u8, input, "love")) return "5.1";

    var value = input;
    // Strip operators
    while (value.len > 0 and (value[0] == '^' or value[0] == '~' or value[0] == '=')) value = value[1..];
    // Strip "lua-" or "lua" prefix
    if (std.mem.startsWith(u8, value, "lua-")) value = value[4..];
    if (std.mem.startsWith(u8, value, "lua")) value = value[3..];

    // Handle X.Y.Z or X.Y
    if (value.len >= 3 and std.ascii.isDigit(value[0]) and value[1] == '.' and std.ascii.isDigit(value[2])) {
        out[0] = value[0];
        out[1] = '.';
        out[2] = value[2];
        return out[0..3];
    }
    // Handle XY (like 54)
    if (value.len >= 2 and std.ascii.isDigit(value[0]) and std.ascii.isDigit(value[1])) {
        out[0] = value[0];
        out[1] = '.';
        out[2] = value[1];
        return out[0..3];
    }
    return value;
}

pub fn runtimeAbiMatches(active: []const u8, candidate: []const u8) bool {
    if (candidate.len == 0 or std.mem.eql(u8, candidate, "any")) return true;
    var active_buf: [8]u8 = undefined;
    var candidate_buf: [8]u8 = undefined;
    const normalized_active = normalizeRuntimeAbi(active, &active_buf);
    const normalized_candidate = normalizeRuntimeAbi(candidate, &candidate_buf);
    return std.mem.eql(u8, normalized_active, normalized_candidate);
}
