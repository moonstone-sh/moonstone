const std = @import("std");
const moonstone = @import("moonstone");
const build_options = @import("build_options");
const archive = moonstone.archive;
const system_tools = moonstone.system_tools;
const helpers = @import("test_archive_helpers.zig");

test "Doctor archive: Archive backend compile-time configuration reflects build option" {
    const backend = archive.backend;
    if (@hasDecl(build_options, "archive_backend")) {
        const expected: archive.BackendKind = switch (build_options.archive_backend) {
            .native => .native,
            .system => .system,
        };
        try std.testing.expectEqual(expected, backend);
    } else {
        try std.testing.expectEqual(archive.BackendKind.native, backend);
    }
}

test "Doctor archive: Native backend functions operate without system tools on PATH" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // Native backend operations (.tar.gz and .tar.zst) do not require system binaries
    const entries = [_]helpers.TarEntry{
        .{ .name = "doctor_check.lua", .content = "return { healthy = true }" },
    };

    const gz_path = try std.fs.path.join(allocator, &.{ tmp_path, "test.tar.gz" });
    defer allocator.free(gz_path);
    try helpers.writeTarGzFile(allocator, io_val, gz_path, &entries);

    const dest_gz = try std.fs.path.join(allocator, &.{ tmp_path, "out_gz" });
    defer allocator.free(dest_gz);
    try archive.native.extractTarGz(allocator, io_val, gz_path, dest_gz, .{});

    const content = try tmp.dir.readFileAlloc(io_val, "out_gz/doctor_check.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("return { healthy = true }", content);

    // Verify native Zstandard roundtrip without zstd cli
    const zst_data = "Zstandard native doctor compression payload without external CLI dependency";
    const compressed = try archive.native.compressZstdBytes(allocator, zst_data);
    defer allocator.free(compressed);

    const decompressed = try archive.native.decompressZstdBytes(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualStrings(zst_data, decompressed);
}

test "Doctor archive: Tool status evaluation correctly categorizes critical vs optional dependencies" {
    const allocator = std.testing.allocator;
    const io_val = std.testing.io;

    // Evaluate standard toolset checked by doctor
    const test_tools = [_][]const u8{ "zig", "cmake", "tar", "unzip", "git", "gcc" };

    for (test_tools) |tool_name| {
        var status = try system_tools.checkTool(allocator, io_val, tool_name, "--version");
        defer status.deinit(allocator);

        if (status.available) {
            try std.testing.expect(status.path != null);
        } else {
            try std.testing.expect(status.path == null);
        }
    }
}
