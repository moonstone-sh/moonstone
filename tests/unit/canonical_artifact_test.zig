const std = @import("std");
const moonstone = @import("moonstone");
const canonical = moonstone.archive.canonical_artifact;

test "canonical artifact bytes and b3 are exactly repeatable across declared order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "source");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/readme.txt", .data = "canonical artifact\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/launch", .data = "#!/bin/sh\nexit 0\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const readme = try std.fs.path.join(allocator, &.{ root, "source/readme.txt" });
    defer allocator.free(readme);
    const launch = try std.fs.path.join(allocator, &.{ root, "source/launch" });
    defer allocator.free(launch);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.tar.gz" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.tar.gz" });
    defer allocator.free(second_path);

    const unordered = [_]canonical.Entry{
        .{ .virtual_path = "bin/launch", .source_path = launch, .mode = .executable },
        .{ .virtual_path = "README.txt", .source_path = readme, .mode = .file },
    };
    const reordered = [_]canonical.Entry{
        .{ .virtual_path = "README.txt", .source_path = readme, .mode = .file },
        .{ .virtual_path = "bin/launch", .source_path = launch, .mode = .executable },
    };

    var first = try canonical.create(allocator, io, first_path, &unordered);
    defer first.deinit(allocator);
    var second = try canonical.create(allocator, io, second_path, &reordered);
    defer second.deinit(allocator);

    const first_bytes = try std.Io.Dir.cwd().readFileAlloc(io, first_path, allocator, std.Io.Limit.unlimited);
    defer allocator.free(first_bytes);
    const second_bytes = try std.Io.Dir.cwd().readFileAlloc(io, second_path, allocator, std.Io.Limit.unlimited);
    defer allocator.free(second_bytes);
    try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);
    try std.testing.expectEqual(first.bytes, second.bytes);
    try std.testing.expectEqualStrings(first.b3, second.b3);
    try std.testing.expect(std.mem.startsWith(u8, first.b3, "b3:"));
    // RFC 1952 MTIME is zero in the native deterministic gzip header.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, first_bytes[4..8]);
}

test "canonical artifact rejects unsafe paths, collisions, and unsupported sources without replacing output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "source/dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/file", .data = "data" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const source = try std.fs.path.join(allocator, &.{ root, "source/file" });
    defer allocator.free(source);
    const source_dir = try std.fs.path.join(allocator, &.{ root, "source/dir" });
    defer allocator.free(source_dir);
    const output = try std.fs.path.join(allocator, &.{ root, "artifact.tar.gz" });
    defer allocator.free(output);
    try tmp.dir.writeFile(io, .{ .sub_path = "artifact.tar.gz", .data = "previous artifact" });

    const traversal = [_]canonical.Entry{.{ .virtual_path = "../escape", .source_path = source, .mode = .file }};
    try std.testing.expectError(error.InvalidVirtualPath, canonical.create(allocator, io, output, &traversal));
    const case_collision = [_]canonical.Entry{
        .{ .virtual_path = "Readme", .source_path = source, .mode = .file },
        .{ .virtual_path = "README", .source_path = source, .mode = .file },
    };
    try std.testing.expectError(error.CaseCollision, canonical.create(allocator, io, output, &case_collision));
    const separated_case_collision = [_]canonical.Entry{
        .{ .virtual_path = "A", .source_path = source, .mode = .file },
        .{ .virtual_path = "B", .source_path = source, .mode = .file },
        .{ .virtual_path = "a", .source_path = source, .mode = .file },
    };
    try std.testing.expectError(error.CaseCollision, canonical.create(allocator, io, output, &separated_case_collision));
    const duplicate = [_]canonical.Entry{
        .{ .virtual_path = "readme", .source_path = source, .mode = .file },
        .{ .virtual_path = "readme", .source_path = source, .mode = .file },
    };
    try std.testing.expectError(error.DuplicateVirtualPath, canonical.create(allocator, io, output, &duplicate));
    const directory = [_]canonical.Entry{.{ .virtual_path = "directory", .source_path = source_dir, .mode = .file }};
    try std.testing.expectError(error.UnsupportedEntryType, canonical.create(allocator, io, output, &directory));
    if (comptime @import("builtin").os.tag != .windows) {
        try tmp.dir.symLink(io, "file", "source/link", .{});
        const source_link = try std.fs.path.join(allocator, &.{ root, "source/link" });
        defer allocator.free(source_link);
        const symlink = [_]canonical.Entry{.{ .virtual_path = "link", .source_path = source_link, .mode = .file }};
        try std.testing.expectError(error.UnsupportedEntryType, canonical.create(allocator, io, output, &symlink));
    }

    const preserved = try tmp.dir.readFileAlloc(io, "artifact.tar.gz", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("previous artifact", preserved);
}
