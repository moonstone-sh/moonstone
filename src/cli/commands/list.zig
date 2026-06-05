const std = @import("std");
const moonstone = @import("moonstone");
const ndjson = @import("ndjson.zig");
const router = @import("../router.zig");

pub const ListCommand = struct {
    pub const name = "list";
    pub const description = "List current project dependencies";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon list [flags]
            \\
            \\List all dependencies for the current project.
            \\
            \\Flags:
            \\  --json    Output results as JSON (bloated protocol)
            \\
        , .{});
    }

    pub fn run(self: ListCommand, ctx: *router.Context) !void {
        const project_root = try moonstone.project.discovery.enterRoot(ctx.allocator, ctx.io, ".");
        defer project_root.deinit(ctx.allocator);

        var emitter_obj = if (self.json) ndjson.Emitter.init(ctx.allocator, ctx.stdout, name) else null;
        const emitter = if (emitter_obj) |*e| e else null;

        if (emitter) |e| {
            try e.emit(ctx.io, .START, name, "begin", .{});
        }

        // 1. Read moonstone.toml
        const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.toml", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) {
                if (emitter) |e| {
                    try e.emit(ctx.io, .ERROR, "manifest", "error.NoProjectFound", .{});
                } else {
                    try ctx.stdout.print("Error: moonstone.toml not found in the current directory.\n", .{});
                }
                return error.NoProjectFound;
            }
            return err;
        };
        defer ctx.allocator.free(content);
        var mt = try moonstone.domain.manifest.MoonstoneToml.parse(ctx.allocator, content);
        defer mt.deinit(ctx.allocator);

        // 2. Try to read moonstone.lock for exact versions
        const lock_content = std.Io.Dir.cwd().readFileAlloc(ctx.io, "moonstone.lock", ctx.allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| blk: {
            if (err == error.FileNotFound) break :blk @as(?[]const u8, null);
            return err;
        };
        defer if (lock_content) |c| ctx.allocator.free(c);

        var lf_opt: ?moonstone.domain.lockfile.LockFile = if (lock_content) |c| try moonstone.domain.lockfile.LockFile.parse(ctx.allocator, c) else null;
        defer if (lf_opt) |*lf| lf.deinit();

        if (emitter == null) {
            try ctx.stdout.print("Project: {s} v{s}\n", .{ mt.package.name, mt.package.version });
            try ctx.stdout.print("{s: <20} {s: <15} {s: <10} {s}\n", .{ "Package", "Version", "Kind", "Source/Hash" });
            try ctx.stdout.print("--------------------------------------------------------------------------------\n", .{});
        }

        var count: usize = 0;
        
        // Helper to print a dependency
        const printDep = struct {
            fn run_internal(pkg_name: []const u8, constraint: []const u8, lf: ?moonstone.domain.lockfile.LockFile, is_json: bool, e: ?*ndjson.Emitter, c_ctx: *router.Context, c_ptr: *usize) !void {
                c_ptr.* += 1;
                const entry = if (lf) |l| l.find(pkg_name) else null;
                const version = if (entry) |ent| ent.version else constraint;
                const hash = if (entry) |ent| (if (ent.artifact_hash.len >= 12) ent.artifact_hash[0..12] else ent.artifact_hash) else "-";
                const kind = if (entry) |ent| @tagName(ent.kind) else "unknown";

                if (is_json) {
                    try e.?.emit(c_ctx.io, .STATUS, pkg_name, "dependency", .{
                        .name = pkg_name,
                        .version = version,
                        .kind = kind,
                        .hash = if (entry) |ent| ent.artifact_hash else null,
                        .locked = entry != null,
                    });
                } else {
                    try c_ctx.stdout.print("{s: <20} {s: <15} {s: <10} {s}\n", .{ pkg_name, version, kind, hash });
                }
            }
        }.run_internal;

        // Iterate through all dependencies
        for (mt.dependencies.items) |dep| {
            const raw_spec = if (dep.resolver) |r|
                if (std.mem.eql(u8, r, "moonstone"))
                    try ctx.allocator.dupe(u8, dep.constraint)
                else
                    try std.fmt.allocPrint(ctx.allocator, "{s}:{s}@{s}", .{ r, dep.name, dep.constraint })
            else
                try std.fmt.allocPrint(ctx.allocator, "{s}@{s}", .{ dep.name, dep.constraint });
            defer ctx.allocator.free(raw_spec);

            try printDep(dep.name, raw_spec, lf_opt, self.json, emitter, ctx, &count);
        }

        if (count == 0) {
            if (emitter) |e| {
                try e.terminate(ctx.io, name, "ok", .{ .count = count });
            } else {
                try ctx.stdout.print("(no dependencies found)\n", .{});
            }
        } else {
            if (emitter) |e| {
                try e.terminate(ctx.io, name, "ok", .{ .count = count });
            }
        }
    }
};
