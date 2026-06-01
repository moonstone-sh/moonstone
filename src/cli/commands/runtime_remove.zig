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

pub const RuntimeRemoveCommand = struct {
    pub const name = "remove";
    pub const description = "Remove an installed Lua runtime";

    positionals: []const []const u8 = &.{},
    target: ?[]const u8 = null,
    force: bool = false,
    quiet: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon runtime remove [flags] <name@version>
            \\
            \\Remove one concrete installed runtime artifact from the shared store.
            \\
            \\Flags:
            \\  --target <triple>  Select a target when multiple builds are installed
            \\  --force            Remove a referenced runtime anyway
            \\  --quiet            Suppress non-error output
            \\
        , .{});
    }

    pub fn run(self: RuntimeRemoveCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return error.MissingArgument;
        const spec = self.positionals[0];
        const at = std.mem.indexOfScalar(u8, spec, '@') orelse return error.ConcreteRuntimeVersionRequired;
        const runtime_name = spec[0..at];
        const version = spec[at + 1 ..];
        if (runtime_name.len == 0 or !isConcreteVersion(version)) return error.ConcreteRuntimeVersionRequired;

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

        var matches = try findMatches(allocator, idx, runtime_name, version, self.target);
        defer {
            for (matches.items) |item| item.deinit(allocator);
            matches.deinit(allocator);
        }
        if (matches.items.len == 0) return error.RuntimeNotInstalled;
        if (matches.items.len > 1) {
            try ctx.stdout.print("Multiple builds match {s}. Re-run with `--target <triple>` using one of:\n", .{spec});
            for (matches.items) |item| try ctx.stdout.print("  {s}\n", .{item.target});
            return error.RuntimeTargetRequired;
        }

        const global_reference = try isGlobalDefault(allocator, io, paths.config, runtime_name, version);
        const project_references = try countProjectReferences(allocator, io, paths.projects, runtime_name, version);
        if ((global_reference or project_references > 0) and !self.force) {
            if (global_reference) try ctx.stdout.print("Cannot remove {s}: unset the current global runtime first.\n", .{spec});
            if (project_references > 0) try ctx.stdout.print("Cannot remove {s}: {d} registered project(s) rely on it.\n", .{ spec, project_references });
            try ctx.stdout.print("Re-run with `--force` to remove it anyway.\n", .{});
            return error.RuntimeStillReferenced;
        }
        if (!self.quiet and self.force and (global_reference or project_references > 0)) {
            try ctx.stdout.print("Warning: removing {s} may break the global default and {d} registered project(s).\n", .{ spec, project_references });
        }

        const selected = matches.items[0];
        std.Io.Dir.cwd().deleteTree(io, selected.path) catch |err| if (err != error.FileNotFound) return err;
        try idx.delete_artifact(selected.hash);
        if (!self.quiet) try ctx.stdout.print("Removed runtime {s} ({s}).\n", .{ spec, selected.target });
    }
};

fn isConcreteVersion(version: []const u8) bool {
    if (version.len == 0) return false;
    for (version) |char| if (!(std.ascii.isDigit(char) or char == '.')) return false;
    return true;
}

fn findMatches(allocator: std.mem.Allocator, idx: moonstone.store.driver.StoreDriver, name: []const u8, version: []const u8, target: ?[]const u8) !std.ArrayList(Match) {
    var result = std.ArrayList(Match).empty;
    errdefer result.deinit(allocator);
    const sql = "SELECT artifact_hash, target, path FROM artifacts WHERE kind = 'runtime' AND name = ? AND version = ? AND (? IS NULL OR target = ?) ORDER BY target;";
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(idx.db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SQLitePrepareError;
    defer _ = c.sqlite3_finalize(stmt);
    const transient = moonstone.store.driver.moonstone_sqlite_transient_ptr;
    _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), transient);
    _ = c.sqlite3_bind_text(stmt, 2, version.ptr, @intCast(version.len), transient);
    if (target) |value| {
        _ = c.sqlite3_bind_text(stmt, 3, value.ptr, @intCast(value.len), transient);
        _ = c.sqlite3_bind_text(stmt, 4, value.ptr, @intCast(value.len), transient);
    } else {
        _ = c.sqlite3_bind_null(stmt, 3);
        _ = c.sqlite3_bind_null(stmt, 4);
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

fn isGlobalDefault(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8, name: []const u8, version: []const u8) !bool {
    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.toml" });
    defer allocator.free(config_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer allocator.free(content);
    const needle = try std.fmt.allocPrint(allocator, "default_runtime = \"{s}-{s}\"", .{ name, version });
    defer allocator.free(needle);
    return std.mem.indexOf(u8, content, needle) != null;
}

fn countProjectReferences(allocator: std.mem.Allocator, io: std.Io, projects_path: []const u8, name: []const u8, version: []const u8) !usize {
    var projects = std.Io.Dir.cwd().openDir(io, projects_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer projects.close(io);
    var count: usize = 0;
    var iterator = projects.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .sym_link and entry.kind != .directory) continue;
        const registered = try std.fs.path.join(allocator, &.{ projects_path, entry.name });
        defer allocator.free(registered);
        const project_root = if (entry.kind == .sym_link) blk: {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const length = projects.readLink(io, entry.name, &buffer) catch continue;
            break :blk try allocator.dupe(u8, buffer[0..length]);
        } else try allocator.dupe(u8, registered);
        defer allocator.free(project_root);
        const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "moonstone.toml" });
        defer allocator.free(manifest_path);
        const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch continue;
        defer allocator.free(content);
        var manifest = moonstone.domain.manifest.MoonstoneToml.parse(allocator, content) catch continue;
        defer manifest.deinit(allocator);
        if (std.mem.eql(u8, manifest.runtimeName(), name) and std.mem.startsWith(u8, version, manifest.runtimeVersion())) count += 1;
    }
    return count;
}
