const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const c = moonstone.store.driver.c;

const Match = struct {
    hash: []const u8,
    target: []const u8,
    path: []const u8,

    fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.target);
        allocator.free(self.path);
    }
};

pub const InterpreterRemoveCommand = struct {
    pub const name = "remove";
    pub const description = "Remove an installed Lua interpreter";

    positionals: []const []const u8 = &.{},
    target: ?[]const u8 = null,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon remove --global [flags] <name@version>
            \\
            \\Remove one concrete installed interpreter artifact from the shared store.
            \\
            \\Flags:
            \\  --target <triple>  Select a target when multiple builds are installed
            \\  --json             Emit newline-delimited JSON events
            \\
        , .{});
    }

    pub fn run(self: InterpreterRemoveCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return error.MissingArgument;
        const spec = self.positionals[0];
        const at = std.mem.indexOfScalar(u8, spec, '@') orelse return error.ConcreteInterpreterVersionRequired;
        const interpreter_name = moonstone.domain.package_spec.canonicalOfficialRuntime(spec[0..at]);
        const version = spec[at + 1 ..];
        if (interpreter_name.len == 0 or !isConcreteVersion(version)) return error.ConcreteInterpreterVersionRequired;

        const allocator = ctx.allocator;
        const io = ctx.io;
        var paths = try moonstone.platform.fs.resolve_moonstone(allocator, ctx.env, io);
        defer paths.deinit(allocator);
        try std.Io.Dir.cwd().createDirPath(io, paths.index);
        const db_path = try std.fs.path.join(allocator, &.{ paths.index, "index.sqlite" });
        defer allocator.free(db_path);
        const db_path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(db_path_z);
        var idx = try moonstone.store.driver.StoreDriver.init(allocator, db_path_z);
        defer idx.deinit();

        var matches = try findMatches(allocator, idx, interpreter_name, version, self.target);
        defer {
            for (matches.items) |item| item.deinit(allocator);
            matches.deinit(allocator);
        }
        if (matches.items.len == 0) return error.InterpreterNotInstalled;
        if (matches.items.len > 1) {
            if (self.json) return error.InterpreterTargetRequired;
            try ctx.stdout.print("Multiple interpreter builds match {s}. Re-run with `--target <triple>` using one of:\n", .{spec});
            for (matches.items) |item| try ctx.stdout.print("  {s}\n", .{item.target});
            return error.InterpreterTargetRequired;
        }

        const global_reference = try isGlobalDefault(ctx, interpreter_name, version);
        const project_references = try countProjectReferences(allocator, io, paths.projects, interpreter_name, version, matches.items[0].hash);
        if (global_reference or project_references > 0) {
            ctx.error_detail = .{ .message = .{ .msg = "Runtime is still referenced by a project or the global selection. Select a replacement with `moon set` and sync dependent projects before removing it." } };
            if (self.json) return error.InterpreterStillReferenced;
            if (global_reference) try ctx.stdout.print("Cannot remove {s}: unset the current global interpreter first.\n", .{spec});
            if (project_references > 0) try ctx.stdout.print("Cannot remove {s}: {d} registered project(s) rely on it.\n", .{ spec, project_references });

            return error.InterpreterStillReferenced;
        }
        const selected = matches.items[0];
        const store_root = try std.Io.Dir.cwd().realPathFileAlloc(io, paths.store, allocator);
        defer allocator.free(store_root);
        const owned_prefix = try std.fmt.allocPrint(allocator, "{s}{c}", .{ store_root, std.fs.path.sep });
        defer allocator.free(owned_prefix);
        const artifact_root = std.Io.Dir.cwd().realPathFileAlloc(io, selected.path, allocator) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (artifact_root) |path| allocator.free(path);
        if (artifact_root) |path| {
            if (!std.mem.startsWith(u8, path, owned_prefix)) return error.RuntimeOutsideOwnedStore;
            try std.Io.Dir.cwd().deleteTree(io, path);
        }
        try idx.delete_artifact(selected.hash);
        if (self.json) {
            var emitter = @import("ndjson.zig").Emitter.init(allocator, ctx.stdout, "remove");
            try emitter.terminate(io, spec, "ok", .{ .target = selected.target, .runtime = true, .global = true });
        }
        if (!self.json) try ctx.stdout.print("Removed interpreter {s} ({s}).\n", .{ spec, selected.target });
    }
};

fn isConcreteVersion(version: []const u8) bool {
    _ = moonstone.domain.semver.Version.parse(version) catch return false;
    return true;
}

fn findMatches(allocator: std.mem.Allocator, idx: moonstone.store.driver.StoreDriver, name: []const u8, version: []const u8, target: ?[]const u8) !std.ArrayList(Match) {
    var result = std.ArrayList(Match).empty;
    errdefer result.deinit(allocator);
    const sql = "SELECT artifact_hash, target, path FROM artifacts WHERE kind = 'runtime' AND (name = ? OR name = ?) AND version = ? AND (? IS NULL OR target = ?) ORDER BY target;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    const transient = moonstone.store.driver.moonstone_sqlite_transient_ptr;
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), transient);
    const alias = if (@import("runtime_spec.zig").isOfficial(name)) std.fs.path.basename(name) else name;
    _ = c.sqlite3_bind_text(stmt, 2, alias.ptr, @intCast(alias.len), transient);
    _ = c.sqlite3_bind_text(stmt, 3, version.ptr, @intCast(version.len), transient);
    if (target) |value| {
        _ = c.sqlite3_bind_text(stmt, 4, value.ptr, @intCast(value.len), transient);
        _ = c.sqlite3_bind_text(stmt, 5, value.ptr, @intCast(value.len), transient);
    } else {
        _ = c.sqlite3_bind_null(stmt, 4);
        _ = c.sqlite3_bind_null(stmt, 5);
    }
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try result.append(allocator, .{
            .hash = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 0))),
            .target = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 1))),
            .path = try allocator.dupe(u8, std.mem.span(c.sqlite3_column_text(stmt, 2))),
        });
    }
    return result;
}

pub fn isGlobalDefault(ctx: *router.Context, name: []const u8, version: []const u8) !bool {
    const allocator = ctx.allocator;
    const path = try moonstone.platform.fs.resolve_config_file(allocator, ctx.env);
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(content);
    var parser = moonstone.domain.manifest.toml.Parser(moonstone.domain.manifest.toml.Table).init(allocator);
    defer parser.deinit();
    var parsed = try parser.parseString(content);
    defer parsed.deinit();
    const section = parsed.value.get("moonstone") orelse return false;
    if (section != .table) return error.InvalidConfig;
    const value = section.table.get("default_runtime") orelse return false;
    if (value != .string) return error.InvalidConfig;
    const alias = if (@import("runtime_spec.zig").isOfficial(name)) std.fs.path.basename(name) else name;
    const spec = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ alias, version });
    defer allocator.free(spec);
    const canonical = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, version });
    defer allocator.free(canonical);
    return std.mem.eql(u8, value.string, spec) or std.mem.eql(u8, value.string, canonical);
}

fn countProjectReferences(allocator: std.mem.Allocator, io: std.Io, projects_path: []const u8, name: []const u8, version: []const u8, artifact_hash: []const u8) !usize {
    var projects = std.Io.Dir.cwd().openDir(io, projects_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer projects.close(io);
    var count: usize = 0;
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit();
    }
    var iterator = projects.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .sym_link and entry.kind != .directory and !(entry.kind == .file and std.mem.endsWith(u8, entry.name, ".path"))) continue;
        const registered = try std.fs.path.join(allocator, &.{ projects_path, entry.name });
        defer allocator.free(registered);
        const project_root = if (entry.kind == .file) try @import("project_registry.zig").readRoot(allocator, io, registered) else if (entry.kind == .sym_link) blk: {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = projects.readLink(io, entry.name, &buffer) catch continue;
            break :blk try allocator.dupe(u8, buffer[0..length]);
        } else try allocator.dupe(u8, registered);
        defer allocator.free(project_root);
        if (seen.contains(project_root)) continue;
        try seen.put(try allocator.dupe(u8, project_root), {});
        var locked_reference = false;
        for ([_][]const u8{ "moonstone.lock", ".moonstone/env/env.toml" }) |relative| {
            const path = try std.fs.path.join(allocator, &.{ project_root, relative });
            defer allocator.free(path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(32 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(bytes);
            if (std.mem.indexOf(u8, bytes, artifact_hash) != null) locked_reference = true;
        }
        if (locked_reference) {
            count += 1;
            continue;
        }
        const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "moonstone.toml" });
        defer allocator.free(manifest_path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
        defer allocator.free(content);
        var manifest = moonstone.domain.manifest.MoonstoneToml.parse(allocator, content) catch continue;
        defer manifest.deinit(allocator);
        if (std.mem.eql(u8, moonstone.domain.package_spec.canonicalOfficialRuntime(manifest.runtimeName()), name)) {
            var range = try moonstone.domain.semver.VersionRange.parse(allocator, manifest.runtimeVersion());
            defer range.deinit(allocator);
            const installed = try moonstone.domain.semver.Version.parse(version);
            if (range.contains(installed)) count += 1;
        }
    }
    return count;
}

test "runtime removal accepts prereleases but rejects version ranges" {
    try std.testing.expect(isConcreteVersion("2.1.0-beta3"));
    try std.testing.expect(isConcreteVersion("5.4.123"));
    for ([_][]const u8{ "", "^5.4", "~5.4", "*", "../../5.4" }) |version| try std.testing.expect(!isConcreteVersion(version));
}
