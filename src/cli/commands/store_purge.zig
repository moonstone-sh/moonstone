const std = @import("std");
const moonstone = @import("moonstone");
const router = @import("../router.zig");
const ndjson = @import("ndjson.zig");

pub const StorePurgeCommand = struct {
    pub const name = "purge";
    pub const description = "Purge all cached store artifacts and index metadata";

    force: bool = false,
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: moon store purge [flags]
            \\
            \\Purge all content-addressed store artifacts and metadata index entries.
            \\
            \\Flags:
            \\  --force    Skip confirmation warning
            \\  --json     Output result as JSON
            \\
        , .{});
    }

    pub fn run(self: StorePurgeCommand, ctx: *router.Context) !void {
        try purgeStore(ctx.allocator, ctx.io, ctx.stdout, ctx.env, self.json);
    }
};

pub fn purgeStore(allocator: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, env: *std.process.Environ.Map, is_json: bool) !void {
    var paths = try moonstone.platform.fs.resolve_moonstone(allocator, env, io);
    defer paths.deinit(allocator);

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, stdout, StorePurgeCommand.name);
        try emitter.emit(io, .INFO, StorePurgeCommand.name, "purging store artifacts and metadata index", .{
            .store = paths.store,
            .index = paths.index,
        });
    }

    std.Io.Dir.cwd().deleteTree(io, paths.store) catch {};
    std.Io.Dir.cwd().deleteTree(io, paths.index) catch {};

    try std.Io.Dir.cwd().createDirPath(io, paths.store);
    try std.Io.Dir.cwd().createDirPath(io, paths.index);

    if (is_json) {
        var emitter = ndjson.Emitter.init(allocator, stdout, StorePurgeCommand.name);
        try emitter.terminate(io, StorePurgeCommand.name, "ok", .{
            .store = paths.store,
            .index = paths.index,
        });
    } else {
        try stdout.print("Purged store artifacts and metadata index.\n", .{});
    }
}
