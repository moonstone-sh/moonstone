const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const content = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        std.Io.Limit.limited(100 * 1024 * 1024),
    );

    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(content, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    var buffer: [80]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("{s}\n", .{&hex});
    try stdout.interface.flush();
}
