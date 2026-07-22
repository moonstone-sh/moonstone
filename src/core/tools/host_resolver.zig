const std = @import("std");
const replay_mod = @import("../domain/replay_contract.zig");
const HostToolRequirement = replay_mod.HostToolRequirement;
const HostToolVersionPolicy = replay_mod.HostToolVersionPolicy;

pub const ResolvedHostTool = struct {
    executable_path: []const u8,
    normalized_version: []const u8,

    pub fn deinit(self: ResolvedHostTool, allocator: std.mem.Allocator) void {
        allocator.free(self.executable_path);
        allocator.free(self.normalized_version);
    }
};

pub fn normalizeVersionOutput(allocator: std.mem.Allocator, raw_output: []const u8) ![]const u8 {
    var text = std.mem.trim(u8, raw_output, " \t\r\n");
    // Strip common prefixes
    if (std.mem.startsWith(u8, text, "zig ")) text = text[4..];
    if (std.mem.startsWith(u8, text, "cmake version ")) text = text[14..];
    if (std.mem.startsWith(u8, text, "clang version ")) text = text[14..];
    if (std.mem.startsWith(u8, text, "cc (GCC) ")) text = text[9..];

    // Take first line or word
    if (std.mem.indexOfScalar(u8, text, '\n')) |newline_idx| {
        text = text[0..newline_idx];
    }
    if (std.mem.indexOfScalar(u8, text, ' ')) |space_idx| {
        text = text[0..space_idx];
    }

    return try allocator.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
}

pub fn resolveHostTool(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    req: *const HostToolRequirement,
) !ResolvedHostTool {
    var found_path: ?[]const u8 = null;

    // Search PATH for matching executable names
    for (req.executable_names) |name| {
        if (env.get("PATH")) |path_var| {
            var it = std.mem.splitScalar(u8, path_var, ':');
            while (it.next()) |dir| {
                if (dir.len == 0) continue;
                const candidate_path = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
                defer allocator.free(candidate_path);

                var f = std.Io.Dir.openFileAbsolute(io, candidate_path, .{}) catch continue;
                f.close(io);
                found_path = try allocator.dupe(u8, candidate_path);
                break;
            }
        }
        if (found_path != null) break;
    }

    if (found_path == null) {
        return error.HostToolUnavailable;
    }
    errdefer if (found_path) |p| allocator.free(p);

    const exec_path = found_path.?;

    // Probe version
    const probe_flag = if (req.kind == .cmake) "--version" else "version";
    var argv = [_][]const u8{ exec_path, probe_flag };

    const run_res = std.process.run(allocator, io, .{
        .argv = &argv,
    }) catch {
        return error.HostToolProbeFailed;
    };
    defer allocator.free(run_res.stdout);
    defer allocator.free(run_res.stderr);

    if (run_res.term != .exited or run_res.term.exited != 0) {
        return error.HostToolProbeFailed;
    }

    const norm_ver = try normalizeVersionOutput(allocator, run_res.stdout);
    errdefer allocator.free(norm_ver);

    // Validate version policy
    if (req.observed_version) |obs_ver| {
        switch (req.version_policy) {
            .exact_observed => {
                if (!std.mem.eql(u8, norm_ver, obs_ver)) {
                    return error.HostToolVersionMismatch;
                }
            },
            .adapter_compatible => {
                // Major/minor prefix match
                const obs_prefix = if (std.mem.lastIndexOfScalar(u8, obs_ver, '.')) |idx| obs_ver[0..idx] else obs_ver;
                if (!std.mem.startsWith(u8, norm_ver, obs_prefix)) {
                    return error.HostToolVersionMismatch;
                }
            },
        }
    }

    return ResolvedHostTool{
        .executable_path = exec_path,
        .normalized_version = norm_ver,
    };
}
