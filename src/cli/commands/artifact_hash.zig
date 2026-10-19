const std = @import("std");
const router = @import("../router.zig");

pub const ArtifactHashCommand = struct {
    pub const name = "hash";
    pub const description = "Hash a file with BLAKE3 without external tools";
    positionals: []const []const u8 = &.{},
    json: bool = false,

    pub fn printHelp(stdout: *std.Io.Writer) !void {
        try stdout.writeAll("Usage: moon artifact hash [--json] -- <file>\n\nStream a file through BLAKE3. Prints its lowercase digest or the\nmoonstone:artifact-hash:v1 JSON contract (bytes and b3 fields).\n");
    }

    pub fn run(self: ArtifactHashCommand, ctx: *router.Context) !void {
        if (self.positionals.len != 1) return error.InvalidArtifactHashArguments;
        const file = try std.Io.Dir.cwd().openFile(ctx.io, self.positionals[0], .{});
        defer file.close(ctx.io);
        var buffer: [65536]u8 = undefined;
        var reader = file.reader(ctx.io, &buffer);
        var chunk: [65536]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        var bytes: u64 = 0;
        while (true) {
            const count = try reader.interface.readSliceShort(&chunk);
            if (count == 0) break;
            hasher.update(chunk[0..count]);
            bytes += count;
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (self.json) {
            const prefixed = "b3:" ++ hex;
            try std.json.Stringify.value(.{ .contract = "moonstone:artifact-hash:v1", .bytes = bytes, .b3 = prefixed }, .{}, ctx.stdout);
            try ctx.stdout.writeAll("\n");
        } else try ctx.stdout.print("{s}\n", .{hex});
    }
};
