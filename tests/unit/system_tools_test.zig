const std = @import("std");
const moonstone = @import("moonstone");
const system_tools = moonstone.system_tools;

test "System tools: PATH lookup for existing vs non-existing tools" {
    const allocator = std.testing.allocator;
    const io_val = std.testing.io;

    // 1. Existing tool lookup
    const sh_path = try system_tools.findExecutable(allocator, io_val, "sh");
    try std.testing.expect(sh_path != null);
    if (sh_path) |p| {
        defer allocator.free(p);
        try std.testing.expect(p.len > 0);
        // Verify path is accessible
        try std.Io.Dir.cwd().access(io_val, p, .{});
    }

    // 2. Non-existing tool lookup
    const missing = try system_tools.findExecutable(allocator, io_val, "moonstone_nonexistent_binary_xyz987654321");
    try std.testing.expect(missing == null);
}

test "System tools: Direct path lookup (relative and absolute)" {
    const allocator = std.testing.allocator;
    const io_val = std.testing.io;

    // 1. Relative existing file
    const rel_path = try system_tools.findExecutable(allocator, io_val, "./build.zig");
    try std.testing.expect(rel_path != null);
    if (rel_path) |p| {
        defer allocator.free(p);
        try std.testing.expectEqualStrings("./build.zig", p);
    }

    // 2. Relative non-existent file
    const rel_missing = try system_tools.findExecutable(allocator, io_val, "./nonexistent_file_12345.xyz");
    try std.testing.expect(rel_missing == null);
}

test "System tools: runTool execution with spaces and Unicode arguments" {
    const allocator = std.testing.allocator;
    const io_val = std.testing.io;

    const sh_exe = try system_tools.findExecutable(allocator, io_val, "sh");
    if (sh_exe == null) return;
    defer allocator.free(sh_exe.?);

    // 1. Simple command with spaces in arguments
    var res1 = try system_tools.runTool(allocator, io_val, &.{
        sh_exe.?, "-c", "printf '%s\n' 'Hello from Moonstone with spaces'",
    });
    defer res1.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res1.term);
    try std.testing.expectEqualStrings("Hello from Moonstone with spaces\n", res1.stdout);
    try std.testing.expectEqualStrings("", res1.stderr);

    // 2. Command with Unicode / UTF-8 characters
    var res2 = try system_tools.runTool(allocator, io_val, &.{
        sh_exe.?, "-c", "printf '%s\n' '🚀 Moonstone: 日本語 & Türkçe / üñîcødé'",
    });
    defer res2.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res2.term);
    try std.testing.expectEqualStrings("🚀 Moonstone: 日本語 & Türkçe / üñîcødé\n", res2.stdout);
}

test "System tools: runTool non-zero exit code and stderr capture" {
    const allocator = std.testing.allocator;
    const io_val = std.testing.io;

    const sh_exe = try system_tools.findExecutable(allocator, io_val, "sh");
    if (sh_exe == null) return;
    defer allocator.free(sh_exe.?);

    // 1. Non-zero exit code capture (e.g. exit 42)
    var res_exit = try system_tools.runTool(allocator, io_val, &.{
        sh_exe.?, "-c", "exit 42",
    });
    defer res_exit.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, res_exit.term);

    // 2. Stderr error message capture
    var res_err = try system_tools.runTool(allocator, io_val, &.{
        sh_exe.?, "-c", "printf '%s\n' 'CRITICAL: archive decompression failure' >&2; exit 3",
    });
    defer res_err.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, res_err.term);
    try std.testing.expect(std.mem.indexOf(u8, res_err.stderr, "CRITICAL: archive decompression failure") != null);
}

test "System tools: checkTool for existing and non-existent tools" {
    const allocator = std.testing.allocator;
    const io_val = std.testing.io;

    // 1. Existing tool (sh)
    var status_sh = try system_tools.checkTool(allocator, io_val, "sh", "-c");
    defer status_sh.deinit(allocator);

    try std.testing.expect(status_sh.available);
    try std.testing.expect(status_sh.path != null);

    // 2. Non-existent tool
    var status_none = try system_tools.checkTool(allocator, io_val, "tool_that_does_not_exist_987", "--version");
    defer status_none.deinit(allocator);

    try std.testing.expect(!status_none.available);
    try std.testing.expect(status_none.path == null);
    try std.testing.expect(status_none.version == null);
}
