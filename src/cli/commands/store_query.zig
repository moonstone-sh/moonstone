const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

const Warning = struct {
    code: []const u8,
    message: []const u8,
};

const QueryResult = struct {
    package: []const u8,
    version: []const u8,
    resolver: []const u8,
    artifact_id: ?[]const u8,
    artifact_hash: []const u8,
    source_hash: []const u8,
    recipe_hash: []const u8,
    rockspec_hash: []const u8,
    kind: []const u8,
    target: []const u8,
    lua_abi: ?[]const u8,
    runtime: ?[]const u8,
    artifact_path: []const u8,
    source_kind: ?[]const u8,
    source_payload: ?[]const u8,
    source_payload_path: ?[]const u8,
    rockspec_payload: ?[]const u8,
    rockspec_payload_path: ?[]const u8,
    manifest_path: []const u8,
    warnings: []Warning,

    fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.package);
        allocator.free(self.version);
        allocator.free(self.resolver);
        if (self.artifact_id) |v| allocator.free(v);
        allocator.free(self.artifact_hash);
        allocator.free(self.source_hash);
        allocator.free(self.recipe_hash);
        allocator.free(self.rockspec_hash);
        allocator.free(self.kind);
        allocator.free(self.target);
        if (self.lua_abi) |v| allocator.free(v);
        if (self.runtime) |v| allocator.free(v);
        allocator.free(self.artifact_path);
        if (self.source_kind) |v| allocator.free(v);
        if (self.source_payload) |v| allocator.free(v);
        if (self.source_payload_path) |v| allocator.free(v);
        if (self.rockspec_payload) |v| allocator.free(v);
        if (self.rockspec_payload_path) |v| allocator.free(v);
        allocator.free(self.manifest_path);
        for (self.warnings) |warning| allocator.free(warning.code);
        allocator.free(self.warnings);
    }
};

pub const StoreQueryCommand = struct {
    pub const name = "query";
    pub const description = "Query local content store artifacts";

    by_artifact_hash: ?[]const u8 = null,
    by_source_hash: ?[]const u8 = null,
    by_package: ?[]const u8 = null,
    by_name: ?[]const u8 = null,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store query [selector] --json
            \\
            \\Query local content-addressed store artifacts.
            \\
            \\Selectors:
            \\  --by-artifact-hash <b3:...>  Match exact artifact hash
            \\  --by-source-hash <b3:...>    Match exact source hash
            \\  --by-package <name>           Match package name
            \\  --by-name <name>              Alias for --by-package
            \\
            \\Flags:
            \\  --json                        Emit stable JSON array
            \\
        , .{});
    }

    pub fn run(self: StoreQueryCommand, ctx: *router.Context) !void {
        const selector_count = @as(u8, if (self.by_artifact_hash != null) 1 else 0) +
            @as(u8, if (self.by_source_hash != null) 1 else 0) +
            @as(u8, if (self.by_package != null) 1 else 0) +
            @as(u8, if (self.by_name != null) 1 else 0);
        if (selector_count != 1) return error.MissingArgument;
        if (!self.json) return error.MissingArgument;

        const paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
        defer { var p = paths; p.deinit(ctx.allocator); }

        var results = std.ArrayList(QueryResult).empty;
        defer {
            for (results.items) |*result| result.deinit(ctx.allocator);
            results.deinit(ctx.allocator);
        }

        try scanStore(ctx, paths.store, self, &results);
        std.mem.sort(QueryResult, results.items, {}, resultLessThan);
        try writeJsonResults(ctx.allocator, ctx.stdout, results.items);
    }
};

fn resultLessThan(_: void, a: QueryResult, b: QueryResult) bool {
    if (!std.mem.eql(u8, a.package, b.package)) return std.mem.lessThan(u8, a.package, b.package);
    if (!std.mem.eql(u8, a.version, b.version)) return std.mem.lessThan(u8, a.version, b.version);
    const a_id = a.artifact_id orelse "";
    const b_id = b.artifact_id orelse "";
    if (!std.mem.eql(u8, a_id, b_id)) return std.mem.lessThan(u8, a_id, b_id);
    if (!std.mem.eql(u8, a.artifact_hash, b.artifact_hash)) return std.mem.lessThan(u8, a.artifact_hash, b.artifact_hash);
    return std.mem.lessThan(u8, a.artifact_path, b.artifact_path);
}

fn scanStore(ctx: *router.Context, store_root: []const u8, query: StoreQueryCommand, results: *std.ArrayList(QueryResult)) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, store_root, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer dir.close(ctx.io);

    var walker = try dir.walk(ctx.allocator);
    defer walker.deinit();

    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "manifest.toml")) continue;

        const manifest_path = try std.fs.path.join(ctx.allocator, &.{ store_root, entry.path });
        defer ctx.allocator.free(manifest_path);
        const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, manifest_path, ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
        defer ctx.allocator.free(content);

        var sm = moonstone.domain.manifest.StoreManifest.parse(ctx.allocator, content) catch continue;
        defer sm.deinit(ctx.allocator);

        if (!matches(query, sm)) continue;

        const artifact_path_rel = std.fs.path.dirname(entry.path) orelse ".";
        const artifact_path = try std.fs.path.join(ctx.allocator, &.{ store_root, artifact_path_rel });
        errdefer ctx.allocator.free(artifact_path);

        try results.append(ctx.allocator, try makeResult(ctx, sm, artifact_path, manifest_path));
    }
}

fn matches(query: StoreQueryCommand, sm: moonstone.domain.manifest.StoreManifest) bool {
    if (query.by_artifact_hash) |hash| return std.mem.eql(u8, sm.artifact.artifact_hash, hash);
    if (query.by_source_hash) |hash| return std.mem.eql(u8, sm.artifact.source_hash, hash);
    if (query.by_package) |name| return std.mem.eql(u8, sm.artifact.name, name);
    if (query.by_name) |name| return std.mem.eql(u8, sm.artifact.name, name);
    return false;
}

fn makeResult(ctx: *router.Context, sm: moonstone.domain.manifest.StoreManifest, artifact_path: []const u8, manifest_path: []const u8) !QueryResult {
    var warnings = std.ArrayList(Warning).empty;
    errdefer warnings.deinit(ctx.allocator);

    const source_payload = if (sm.origin.source_payload.len > 0) try ctx.allocator.dupe(u8, sm.origin.source_payload) else null;
    errdefer if (source_payload) |v| ctx.allocator.free(v);
    const rockspec_payload = if (sm.origin.rockspec_payload.len > 0) try ctx.allocator.dupe(u8, sm.origin.rockspec_payload) else null;
    errdefer if (rockspec_payload) |v| ctx.allocator.free(v);

    const source_payload_path = if (source_payload) |payload| try payloadAbsolutePath(ctx, artifact_path, payload, "source_payload", &warnings) else null;
    errdefer if (source_payload_path) |v| ctx.allocator.free(v);
    const rockspec_payload_path = if (rockspec_payload) |payload| try payloadAbsolutePath(ctx, artifact_path, payload, "rockspec_payload", &warnings) else null;
    errdefer if (rockspec_payload_path) |v| ctx.allocator.free(v);

    return .{
        .package = try ctx.allocator.dupe(u8, sm.artifact.name),
        .version = try ctx.allocator.dupe(u8, sm.artifact.version),
        .resolver = try ctx.allocator.dupe(u8, sm.origin.resolver),
        .artifact_id = null,
        .artifact_hash = try ctx.allocator.dupe(u8, sm.artifact.artifact_hash),
        .source_hash = try ctx.allocator.dupe(u8, sm.artifact.source_hash),
        .recipe_hash = try ctx.allocator.dupe(u8, sm.artifact.recipe_hash),
        .rockspec_hash = try ctx.allocator.dupe(u8, sm.origin.rockspec_hash),
        .kind = try ctx.allocator.dupe(u8, @tagName(sm.artifact.kind)),
        .target = try ctx.allocator.dupe(u8, sm.artifact.target),
        .lua_abi = if (sm.compat.lua_abi.len > 0) try ctx.allocator.dupe(u8, sm.compat.lua_abi) else null,
        .runtime = if (sm.compat.runtime_version.len > 0) try ctx.allocator.dupe(u8, sm.compat.runtime_version) else null,
        .artifact_path = artifact_path,
        .source_kind = if (sm.origin.source_kind.len > 0) try ctx.allocator.dupe(u8, sm.origin.source_kind) else null,
        .source_payload = source_payload,
        .source_payload_path = source_payload_path,
        .rockspec_payload = rockspec_payload,
        .rockspec_payload_path = rockspec_payload_path,
        .manifest_path = try ctx.allocator.dupe(u8, manifest_path),
        .warnings = try warnings.toOwnedSlice(ctx.allocator),
    };
}

fn payloadAbsolutePath(ctx: *router.Context, artifact_path: []const u8, payload: []const u8, field: []const u8, warnings: *std.ArrayList(Warning)) !?[]const u8 {
    if (!validRelativePayload(payload)) {
        try addWarning(ctx.allocator, warnings, field, "recorded payload path is invalid");
        return null;
    }

    const absolute = try std.fs.path.join(ctx.allocator, &.{ artifact_path, payload });
    errdefer ctx.allocator.free(absolute);
    _ = std.Io.Dir.cwd().statFile(ctx.io, absolute, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try addWarning(ctx.allocator, warnings, field, "payload is recorded but file does not exist under artifact_path");
            return null;
        }
        return err;
    };
    return absolute;
}

fn validRelativePayload(payload: []const u8) bool {
    if (payload.len == 0) return false;
    if (std.fs.path.isAbsolute(payload)) return false;
    if (payload.len >= 2 and std.ascii.isAlphabetic(payload[0]) and payload[1] == ':') return false;

    var it = std.mem.splitScalar(u8, payload, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.mem.indexOfScalar(u8, segment, '\\') != null) return false;
    }
    return true;
}

fn addWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(Warning), field: []const u8, message: []const u8) !void {
    const code = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ field, if (std.mem.indexOf(u8, message, "invalid") != null) "invalid" else "missing" });
    errdefer allocator.free(code);
    try warnings.append(allocator, .{ .code = code, .message = message });
}

fn writeJsonResults(allocator: std.mem.Allocator, stdout: *std.Io.Writer, results: []const QueryResult) !void {
    _ = allocator;
    try stdout.print("[", .{});
    for (results, 0..) |result, index| {
        if (index > 0) try stdout.print(",", .{});
        try stdout.print("\n  {{", .{});
        try writeJsonStringField(stdout, "package", result.package, true);
        try writeJsonStringField(stdout, "version", result.version, false);
        try writeJsonStringField(stdout, "resolver", result.resolver, false);
        try writeJsonNullableStringField(stdout, "artifact_id", result.artifact_id, false);
        try writeJsonStringField(stdout, "artifact_hash", result.artifact_hash, false);
        try writeJsonStringField(stdout, "source_hash", result.source_hash, false);
        try writeJsonStringField(stdout, "recipe_hash", result.recipe_hash, false);
        try writeJsonStringField(stdout, "rockspec_hash", result.rockspec_hash, false);
        try writeJsonStringField(stdout, "kind", result.kind, false);
        try writeJsonStringField(stdout, "target", result.target, false);
        try writeJsonNullableStringField(stdout, "lua_abi", result.lua_abi, false);
        try writeJsonNullableStringField(stdout, "runtime", result.runtime, false);
        try writeJsonStringField(stdout, "artifact_path", result.artifact_path, false);
        try writeJsonNullableStringField(stdout, "source_kind", result.source_kind, false);
        try writeJsonNullableStringField(stdout, "source_payload", result.source_payload, false);
        try writeJsonNullableStringField(stdout, "source_payload_path", result.source_payload_path, false);
        try writeJsonNullableStringField(stdout, "rockspec_payload", result.rockspec_payload, false);
        try writeJsonNullableStringField(stdout, "rockspec_payload_path", result.rockspec_payload_path, false);
        try writeJsonStringField(stdout, "manifest_path", result.manifest_path, false);
        try stdout.print(",\n    \"warnings\": [", .{});
        for (result.warnings, 0..) |warning, warning_index| {
            if (warning_index > 0) try stdout.print(",", .{});
            try stdout.print("{{", .{});
            try writeJsonInlineStringField(stdout, "code", warning.code, true);
            try writeJsonInlineStringField(stdout, "message", warning.message, false);
            try stdout.print("}}", .{});
        }
        try stdout.print("]\n  }}", .{});
    }
    if (results.len > 0) try stdout.print("\n", .{});
    try stdout.print("]\n", .{});
}

fn writeJsonStringField(stdout: *std.Io.Writer, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try stdout.print(",", .{});
    try stdout.print("\n    ", .{});
    try writeJsonInlineStringField(stdout, key, value, true);
}

fn writeJsonNullableStringField(stdout: *std.Io.Writer, key: []const u8, value: ?[]const u8, first: bool) !void {
    if (!first) try stdout.print(",", .{});
    try stdout.print("\n    ", .{});
    try writeJsonEscaped(stdout, key);
    try stdout.print(": ", .{});
    if (value) |v| try writeJsonEscaped(stdout, v) else try stdout.print("null", .{});
}

fn writeJsonInlineStringField(stdout: *std.Io.Writer, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) try stdout.print(", ", .{});
    try writeJsonEscaped(stdout, key);
    try stdout.print(": ", .{});
    try writeJsonEscaped(stdout, value);
}

fn writeJsonEscaped(stdout: *std.Io.Writer, value: []const u8) !void {
    try stdout.print("\"", .{});
    for (value) |c| {
        switch (c) {
            '"' => try stdout.print("\\\"", .{}),
            '\\' => try stdout.print("\\\\", .{}),
            '\n' => try stdout.print("\\n", .{}),
            '\r' => try stdout.print("\\r", .{}),
            '\t' => try stdout.print("\\t", .{}),
            else => try stdout.writeByte(c),
        }
    }
    try stdout.print("\"", .{});
}
