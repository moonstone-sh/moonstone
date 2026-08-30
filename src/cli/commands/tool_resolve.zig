const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");

pub const ToolResolveCommand = struct {
    pub const name = "resolve";
    pub const description = "Resolve an already-provisioned tool executable";

    positionals: []const []const u8 = &.{},
    target_arg: ?[]const u8 = null,
    global: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon provision resolve <executable> [--target <triple>] [--global] [--json]
            \\
            \\Return a versioned JSON record for an executable already provisioned by
            \\a synchronized project/global-tools environment or the local CAS.
            \\This command never contacts registries, downloads binaries, or changes
            \\the project lockfile.
            \\
            \\Arguments:
            \\  <executable>       Logical name declared by a store bin provision
            \\
            \\Flags:
            \\  --target <triple>  Requested supported target (defaults to the host)
            \\  --global           Use the synchronized global-tools environment first
            \\  --json             Emit the result as JSON (the default)
            \\
        , .{});
    }

    pub fn run(self: ToolResolveCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return if (self.positionals.len == 0) error.MissingArgument else error.UnexpectedPositionalArgument;
        moonstone.project.tool_resolve.validateExecutableName(self.positionals[0]) catch |err| {
            if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
            ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(ctx.allocator, "invalid executable provision name '{s}': names must be a single logical executable name, not a path.", .{self.positionals[0]}) } };
            return err;
        };

        const target = if (self.target_arg) |value| blk: {
            try moonstone.platform.target.validate(value);
            break :blk value;
        } else moonstone.platform.target.hostTargetLiteral();

        const paths = try moonstone.platform.fs.resolve_moonstone(ctx.allocator, ctx.env, ctx.io);
        defer {
            var mutable_paths = paths;
            mutable_paths.deinit(ctx.allocator);
        }
        const index_path = try std.fs.path.join(ctx.allocator, &.{ paths.index, "index.sqlite" });
        defer ctx.allocator.free(index_path);
        std.Io.Dir.cwd().access(ctx.io, index_path, .{}) catch |err| {
            if (err == error.FileNotFound) return unavailable(ctx, self.positionals[0], target, "Moonstone's local index is absent; no already-realized provision can be inspected offline.");
            return err;
        };
        const index_path_z = try ctx.allocator.dupeZ(u8, index_path);
        defer ctx.allocator.free(index_path_z);
        var index = try moonstone.store.driver.StoreDriver.initReadOnly(ctx.allocator, index_path_z);
        defer index.deinit();

        if (self.global) {
            const global_root = try @import("global_tools.zig").projectPath(ctx.allocator, ctx.env, ctx.io);
            defer ctx.allocator.free(global_root);
            if (try resolveEnvironment(ctx, index, global_root, self.positionals[0], target, .global)) |result| {
                var mutable_result = result;
                defer mutable_result.deinit(ctx.allocator);
                return writeResult(ctx.stdout, mutable_result);
            }
        } else {
            const project = moonstone.project.discovery.findRoot(ctx.allocator, ctx.io, ".") catch |err| blk: {
                if (err == error.NotInsideMoonstoneProject) break :blk null;
                return err;
            };
            if (project) |root| {
                defer root.deinit(ctx.allocator);
                if (try resolveEnvironment(ctx, index, root.path, self.positionals[0], target, .project)) |result| {
                    var mutable_result = result;
                    defer mutable_result.deinit(ctx.allocator);
                    return writeResult(ctx.stdout, mutable_result);
                }
            }
        }

        switch (try moonstone.project.tool_resolve.resolveFromStore(ctx.allocator, ctx.io, index, self.positionals[0], target)) {
            .found => |result| {
                var mutable_result = result;
                defer mutable_result.deinit(ctx.allocator);
                try writeResult(ctx.stdout, mutable_result);
            },
            .missing => return unavailable(ctx, self.positionals[0], target, "No matching executable provision is materialized locally; this command is offline-only and will not download one."),
            .target_mismatch => return mismatch(ctx, self.positionals[0], target),
            .artifact_missing => return unavailable(ctx, self.positionals[0], target, "A local index record exists, but its declared executable payload is absent; restore the exact artifact with `moon sync` while online."),
            .ambiguous => return unavailable(ctx, self.positionals[0], target, "More than one local artifact provides this executable; resolve it from a synchronized project/global-tools environment instead."),
        }
    }
};

fn resolveEnvironment(ctx: *router.Context, index: moonstone.store.driver.StoreDriver, root: []const u8, executable_name: []const u8, target: []const u8, source: moonstone.project.tool_resolve.Source) !?moonstone.project.tool_resolve.Result {
    const result = moonstone.project.tool_resolve.resolveFromRealizedEnvironment(ctx.allocator, ctx.io, index, root, executable_name, target, source) catch |err| {
        switch (err) {
            error.RealizedToolEnvironmentMissingLockfile => try unavailable(ctx, executable_name, target, "The realized tool scope has no lockfile; run `moon sync` to recreate the environment."),
            error.RealizedToolEnvironmentProvisionMissing => try unavailable(ctx, executable_name, target, "The realized tool scope is not backed by a locked tool/helper provision; run `moon sync` to recreate it."),
            error.ToolProvisionArtifactMissing => try unavailable(ctx, executable_name, target, "The environment lock references a missing local artifact; restore it with `moon sync` while online."),
            error.ToolProvisionTargetMismatch => try mismatch(ctx, executable_name, target),
            error.AmbiguousToolProvision => try unavailable(ctx, executable_name, target, "The realized environment has multiple locked providers for this executable; fix the dependency conflict and run `moon sync`."),
            else => return err,
        }
        unreachable;
    };
    return result;
}

fn unavailable(ctx: *router.Context, executable_name: []const u8, target: []const u8, detail: []const u8) !void {
    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
    ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(ctx.allocator, "tool provision '{s}' for target '{s}' is unavailable offline. {s}", .{ executable_name, target, detail }) } };
    return error.ToolProvisionUnavailableOffline;
}

fn mismatch(ctx: *router.Context, executable_name: []const u8, target: []const u8) !void {
    if (ctx.error_detail) |*old| old.deinit(ctx.allocator);
    ctx.error_detail = .{ .message = .{ .msg = try std.fmt.allocPrint(ctx.allocator, "tool provision '{s}' is present locally but not for target '{s}'. Synchronize or publish the exact target artifact; this command will not download one.", .{ executable_name, target }) } };
    return error.ToolProvisionTargetMismatch;
}

fn writeResult(stdout: *std.Io.Writer, result: moonstone.project.tool_resolve.Result) !void {
    try std.json.Stringify.value(.{
        .contract = "moonstone:tool-resolve:v1",
        .path = result.path,
        .version = result.version,
        .digest = result.digest,
        .source = @tagName(result.source),
    }, .{}, stdout);
    try stdout.writeAll("\n");
}

test "provision resolve emits the v1 JSON contract and no wrapper events" {
    var bytes: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const result = moonstone.project.tool_resolve.Result{
        .path = "/store/files/bin/tool",
        .version = "1.2.3",
        .digest = "b3:fixture",
        .source = .project,
    };
    try writeResult(&writer, result);
    try std.testing.expectEqualStrings(
        "{\"contract\":\"moonstone:tool-resolve:v1\",\"path\":\"/store/files/bin/tool\",\"version\":\"1.2.3\",\"digest\":\"b3:fixture\",\"source\":\"project\"}\n",
        writer.buffered(),
    );
}

test "provision resolve target mismatch diagnostic is explicit and offline-only" {
    var stdout_bytes: [1]u8 = undefined;
    var stderr_bytes: [1]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_bytes);
    var stderr = std.Io.Writer.fixed(&stderr_bytes);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = router.Context{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stdout = &stdout,
        .stderr = &stderr,
        .env = &env,
    };
    defer if (ctx.error_detail) |*detail| detail.deinit(std.testing.allocator);

    try std.testing.expectError(error.ToolProvisionTargetMismatch, mismatch(&ctx, "tool", "x86_64-windows-gnu"));
    switch (ctx.error_detail.?) {
        .message => |detail| {
            try std.testing.expect(std.mem.indexOf(u8, detail.msg, "not for target 'x86_64-windows-gnu'") != null);
            try std.testing.expect(std.mem.indexOf(u8, detail.msg, "will not download one") != null);
        },
        else => return error.TestExpectedEqual,
    }
}
