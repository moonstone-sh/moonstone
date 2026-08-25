const std = @import("std");
const builtin = @import("builtin");

/// Owns only the argv slice used to add a Windows command-shell prefix. The
/// argument strings remain borrowed from the caller.
pub const PreparedArgv = struct {
    argv: []const []const u8,
    owned: ?[][]const u8 = null,

    pub fn deinit(self: *PreparedArgv, allocator: std.mem.Allocator) void {
        if (self.owned) |items| allocator.free(items);
        self.* = undefined;
    }
};

/// Avoid std.process's implicit .cmd/.bat wrapping on Windows. Zig obtains
/// cmd.exe through CSRSS shared process data for that path, which is valid on
/// native Windows but unavailable in some compatibility environments such as
/// Wine. An explicit cmd.exe argv uses the ordinary executable spawn path.
pub fn prepareArgv(allocator: std.mem.Allocator, argv: []const []const u8) !PreparedArgv {
    if (comptime builtin.os.tag == .windows) return prepareWindowsArgv(allocator, argv);
    return .{ .argv = argv };
}

fn prepareWindowsArgv(allocator: std.mem.Allocator, argv: []const []const u8) !PreparedArgv {
    if (argv.len == 0 or !isWindowsCommandScript(argv[0])) return .{ .argv = argv };

    const wrapped = try allocator.alloc([]const u8, argv.len + 4);
    wrapped[0] = "cmd.exe";
    wrapped[1] = "/d";
    wrapped[2] = "/s";
    wrapped[3] = "/c";
    wrapped[4] = argv[0];
    @memcpy(wrapped[5..], argv[1..]);
    return .{ .argv = wrapped, .owned = wrapped };
}

fn isWindowsCommandScript(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".cmd") or std.ascii.eqlIgnoreCase(extension, ".bat");
}

test "Windows command scripts receive an explicit command-shell prefix" {
    var prepared = try prepareWindowsArgv(std.testing.allocator, &.{ "C:\\tools\\check.CMD", "first", "second" });
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices([]const u8, &.{
        "cmd.exe",
        "/d",
        "/s",
        "/c",
        "C:\\tools\\check.CMD",
        "first",
        "second",
    }, prepared.argv);
}

test "Windows native executables retain their argv" {
    const original = [_][]const u8{ "C:\\tools\\check.exe", "first" };
    var prepared = try prepareWindowsArgv(std.testing.allocator, &original);
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.owned == null);
    try std.testing.expectEqualSlices([]const u8, &original, prepared.argv);
}
