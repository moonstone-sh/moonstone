const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const ndjson = @import("ndjson.zig");

pub const CacheCleanCommand = struct {
    pub const name = "clean";
    pub const description = "Clean Moonstone build and download caches";

    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon cache clean [flags]
            \\
            \\Clean all build, download, and manifest caches.
            \\
            \\Flags:
            \\  --json    Output result as JSON
            \\
        , .{});
    }

    pub fn run(self: CacheCleanCommand, ctx: *router.Context) !void {
        try cleanCache(ctx.allocator, ctx.io, ctx.stdout, ctx.env, self.json);
    }
};

pub fn cleanCache(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map, is_json: bool) !void {
    var paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
    defer paths.deinit(allocator);

    std.Io.Dir.cwd().deleteTree(io, paths.cache) catch {};
    std.Io.Dir.cwd().deleteTree(io, paths.tmp) catch {};

    try std.Io.Dir.cwd().createDirPath(io, paths.cache);
    try std.Io.Dir.cwd().createDirPath(io, paths.tmp);

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, stdout, CacheCleanCommand.name);
        try emitter.terminate(io, CacheCleanCommand.name, "ok", .{
            .cache = paths.cache,
            .tmp = paths.tmp,
        });
    } else {
        try stdout.print("Cleaned Moonstone build and download caches.\n", .{});
    }
}
