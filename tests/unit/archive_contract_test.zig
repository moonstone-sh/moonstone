const std = @import("std");
const moonstone = @import("moonstone");
const archive = moonstone.archive;
const helpers = @import("test_archive_helpers.zig");

test "Archive contract: Valid plain .tar extraction and roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "sample.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "hello.txt", .content = "Hello, plain tar!" },
        .{ .name = "nested/dir/inner.txt", .content = "Nested file content in tar" },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_tar" });
    defer allocator.free(dest_path);

    try archive.extractTar(allocator, io_val, tar_path, dest_path, .{});

    const hello = try tmp.dir.readFileAlloc(io_val, "out_tar/hello.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(hello);
    try std.testing.expectEqualStrings("Hello, plain tar!", hello);

    const nested = try tmp.dir.readFileAlloc(io_val, "out_tar/nested/dir/inner.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("Nested file content in tar", nested);
}

test "Archive contract: Valid .tar.gz extraction and roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_gz_path = try std.fs.path.join(allocator, &.{ tmp_path, "sample.tar.gz" });
    defer allocator.free(tar_gz_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "app.lua", .content = "print('hello from tar.gz')" },
        .{ .name = "lib/utils.lua", .content = "return { ok = true }" },
    };

    try helpers.writeTarGzFile(allocator, io_val, tar_gz_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_targz" });
    defer allocator.free(dest_path);

    try archive.extractTarGz(allocator, io_val, tar_gz_path, dest_path, .{});

    const app = try tmp.dir.readFileAlloc(io_val, "out_targz/app.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(app);
    try std.testing.expectEqualStrings("print('hello from tar.gz')", app);

    const lib = try tmp.dir.readFileAlloc(io_val, "out_targz/lib/utils.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(lib);
    try std.testing.expectEqualStrings("return { ok = true }", lib);
}

test "Archive contract: Valid .tar.zst extraction and roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_zst_path = try std.fs.path.join(allocator, &.{ tmp_path, "sample.tar.zst" });
    defer allocator.free(tar_zst_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "package.json", .content = "{\"name\": \"moonstone-pkg\"}" },
        .{ .name = "bin/launch", .content = "#!/bin/sh\necho test\n" },
    };

    try helpers.writeTarZstdFile(allocator, io_val, tar_zst_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_tarzst" });
    defer allocator.free(dest_path);

    try archive.extractTarZstd(allocator, io_val, tar_zst_path, dest_path, .{});

    const pkg = try tmp.dir.readFileAlloc(io_val, "out_tarzst/package.json", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(pkg);
    try std.testing.expectEqualStrings("{\"name\": \"moonstone-pkg\"}", pkg);

    const launch = try tmp.dir.readFileAlloc(io_val, "out_tarzst/bin/launch", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(launch);
    try std.testing.expectEqualStrings("#!/bin/sh\necho test\n", launch);
}

test "Archive contract: Valid .zip extraction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "sample.zip" });
    defer allocator.free(zip_path);

    const entries = [_]helpers.ZipEntry{
        .{ .name = "readme.md", .content = "# Moonstone Zip Test" },
        .{ .name = "src/core.lua", .content = "return 'core module'" },
    };

    try helpers.writeZipFile(allocator, io_val, zip_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_zip" });
    defer allocator.free(dest_path);

    try archive.extractZip(allocator, io_val, zip_path, dest_path, .{});

    const readme = try tmp.dir.readFileAlloc(io_val, "out_zip/readme.md", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(readme);
    try std.testing.expectEqualStrings("# Moonstone Zip Test", readme);

    const core = try tmp.dir.readFileAlloc(io_val, "out_zip/src/core.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(core);
    try std.testing.expectEqualStrings("return 'core module'", core);
}

test "Archive contract: Empty archives (empty tar, empty tar.gz, empty tar.zst, empty zip)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // 1. Empty TAR
    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "empty.tar" });
    defer allocator.free(tar_path);
    try helpers.writeTarFile(allocator, io_val, tar_path, &.{});

    const dest_tar = try std.fs.path.join(allocator, &.{ tmp_path, "out_empty_tar" });
    defer allocator.free(dest_tar);
    try archive.extractTar(allocator, io_val, tar_path, dest_tar, .{});

    // 2. Empty TAR.GZ
    const targz_path = try std.fs.path.join(allocator, &.{ tmp_path, "empty.tar.gz" });
    defer allocator.free(targz_path);
    try helpers.writeTarGzFile(allocator, io_val, targz_path, &.{});

    const dest_targz = try std.fs.path.join(allocator, &.{ tmp_path, "out_empty_targz" });
    defer allocator.free(dest_targz);
    try archive.extractTarGz(allocator, io_val, targz_path, dest_targz, .{});

    // 3. Empty TAR.ZST
    const tarzst_path = try std.fs.path.join(allocator, &.{ tmp_path, "empty.tar.zst" });
    defer allocator.free(tarzst_path);
    try helpers.writeTarZstdFile(allocator, io_val, tarzst_path, &.{});

    const dest_tarzst = try std.fs.path.join(allocator, &.{ tmp_path, "out_empty_tarzst" });
    defer allocator.free(dest_tarzst);
    try archive.extractTarZstd(allocator, io_val, tarzz_blk: {
        break :tarzz_blk tarzst_path;
    }, dest_tarzst, .{});

    // 4. Empty ZIP
    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "empty.zip" });
    defer allocator.free(zip_path);
    try helpers.writeZipFile(allocator, io_val, zip_path, &.{});

    const dest_zip = try std.fs.path.join(allocator, &.{ tmp_path, "out_empty_zip" });
    defer allocator.free(dest_zip);
    try archive.extractZip(allocator, io_val, zip_path, dest_zip, .{});
}

test "Archive contract: Nested deep directories (depth 7+)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const deep_rel = "d1/d2/d3/d4/d5/d6/d7/deep_file.txt";
    const content = "Deeply nested file payload at level 7";

    const entries = [_]helpers.TarEntry{
        .{ .name = deep_rel, .content = content },
    };

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "deep.tar.gz" });
    defer allocator.free(tar_path);
    try helpers.writeTarGzFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_deep" });
    defer allocator.free(dest_path);
    try archive.extractTarGz(allocator, io_val, tar_path, dest_path, .{});

    const read_content = try tmp.dir.readFileAlloc(io_val, "out_deep/" ++ deep_rel, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(read_content);
    try std.testing.expectEqualStrings(content, read_content);
}

test "Archive contract: Many files (100+ files) extraction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const file_count: usize = 120;
    var entries = try allocator.alloc(helpers.TarEntry, file_count);
    defer allocator.free(entries);

    var name_buffers = try allocator.alloc([64]u8, file_count);
    defer allocator.free(name_buffers);

    var content_buffers = try allocator.alloc([64]u8, file_count);
    defer allocator.free(content_buffers);

    for (0..file_count) |i| {
        const name = try std.fmt.bufPrint(&name_buffers[i], "subdir_{d}/file_{d:0>4}.txt", .{ i % 10, i });
        const data = try std.fmt.bufPrint(&content_buffers[i], "Data payload for entry #{d}", .{i});
        entries[i] = .{
            .name = name,
            .content = data,
        };
    }

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "many_files.tar.gz" });
    defer allocator.free(tar_path);
    try helpers.writeTarGzFile(allocator, io_val, tar_path, entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_many" });
    defer allocator.free(dest_path);
    try archive.extractTarGz(allocator, io_val, tar_path, dest_path, .{});

    // Verify all files extracted accurately
    for (0..file_count) |i| {
        const expected_name = entries[i].name;
        const sub_path = try std.fmt.allocPrint(allocator, "out_many/{s}", .{expected_name});
        defer allocator.free(sub_path);

        const expected_data = entries[i].content;
        const actual_data = try tmp.dir.readFileAlloc(io_val, sub_path, allocator, std.Io.Limit.limited(1024));
        defer allocator.free(actual_data);

        try std.testing.expectEqualStrings(expected_data, actual_data);
    }
}

test "Archive contract: 0-byte files, binary files, and large files (1MB+)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // 1. Binary data with all byte values 0x00 .. 0xFF
    var binary_data: [512]u8 = undefined;
    for (&binary_data, 0..) |*b, idx| {
        b.* = @truncate(idx % 256);
    }

    // 2. Large 1.2MB payload
    const large_size: usize = 1200 * 1024;
    const large_data = try allocator.alloc(u8, large_size);
    defer allocator.free(large_data);
    for (large_data, 0..) |*b, idx| {
        b.* = @truncate((idx * 31 + 17) % 256);
    }

    const entries = [_]helpers.TarEntry{
        .{ .name = "empty_zero_byte.dat", .content = "" },
        .{ .name = "binary_spectrum.bin", .content = &binary_data },
        .{ .name = "large_payload.bin", .content = large_data },
    };

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "content_variety.tar.zst" });
    defer allocator.free(tar_path);
    try helpers.writeTarZstdFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_variety" });
    defer allocator.free(dest_path);
    try archive.extractTarZstd(allocator, io_val, tar_path, dest_path, .{});

    // Check 0-byte file
    const zero_read = try tmp.dir.readFileAlloc(io_val, "out_variety/empty_zero_byte.dat", allocator, std.Io.Limit.limited(100));
    defer allocator.free(zero_read);
    try std.testing.expectEqual(@as(usize, 0), zero_read.len);

    // Check binary file
    const bin_read = try tmp.dir.readFileAlloc(io_val, "out_variety/binary_spectrum.bin", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(bin_read);
    try std.testing.expectEqualSlices(u8, &binary_data, bin_read);

    // Check large file
    const large_read = try tmp.dir.readFileAlloc(io_val, "out_variety/large_payload.bin", allocator, std.Io.Limit.limited(2 * 1024 * 1024));
    defer allocator.free(large_read);
    try std.testing.expectEqualSlices(u8, large_data, large_read);
}

test "Archive contract: Unicode filenames, spaces in path, and long path entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const unicode_name = "日本語/тест/ünîcødé_файл_🚀.txt";
    const unicode_content = "UTF-8 Unicode Content!";

    const space_name = "folder with spaces/file with space 2026.txt";
    const space_content = "Filename with spaces preserved.";

    const long_name = "very_long_path_prefix_0123456789/middle_directory_level_abcdefghijklmnopqrstuvwxyz/target_final_leaf_file.txt";
    const long_content = "Long path content.";

    const entries = [_]helpers.TarEntry{
        .{ .name = unicode_name, .content = unicode_content },
        .{ .name = space_name, .content = space_content },
        .{ .name = long_name, .content = long_content },
    };

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "unicode_and_spaces.tar.gz" });
    defer allocator.free(tar_path);
    try helpers.writeTarGzFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_unicode" });
    defer allocator.free(dest_path);
    try archive.extractTarGz(allocator, io_val, tar_path, dest_path, .{});

    const read_uni = try tmp.dir.readFileAlloc(io_val, "out_unicode/" ++ unicode_name, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(read_uni);
    try std.testing.expectEqualStrings(unicode_content, read_uni);

    const read_space = try tmp.dir.readFileAlloc(io_val, "out_unicode/" ++ space_name, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(read_space);
    try std.testing.expectEqualStrings(space_content, read_space);

    const read_long = try tmp.dir.readFileAlloc(io_val, "out_unicode/" ++ long_name, allocator, std.Io.Limit.limited(1024));
    defer allocator.free(read_long);
    try std.testing.expectEqualStrings(long_content, read_long);
}

test "Archive contract: Overwrite behavior (overwrite: true vs overwrite: false)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "test_overwrite.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "target.txt", .content = "Updated content from archive" },
    };
    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_overwrite" });
    defer allocator.free(dest_path);

    // Pre-create existing file
    try tmp.dir.createDirPath(io_val, "out_overwrite");
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "out_overwrite/target.txt",
        .data = "Original pre-existing content",
    });

    // 1. overwrite = false -> should error or prevent overwriting
    const no_overwrite_res = archive.native.extractTar(allocator, io_val, tar_path, dest_path, .{ .overwrite = false });
    try std.testing.expectError(error.PathAlreadyExists, no_overwrite_res);

    // Verify original content remained intact
    const orig = try tmp.dir.readFileAlloc(io_val, "out_overwrite/target.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(orig);
    try std.testing.expectEqualStrings("Original pre-existing content", orig);

    // 2. overwrite = true -> should succeed and overwrite
    try archive.native.extractTar(allocator, io_val, tar_path, dest_path, .{ .overwrite = true });

    const updated = try tmp.dir.readFileAlloc(io_val, "out_overwrite/target.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("Updated content from archive", updated);
}

test "Archive contract: Strip components (strip_components: 1 and strip_components: 2)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "pkg-v1.0.0/root_file.txt", .content = "Root file" },
        .{ .name = "pkg-v1.0.0/src/nested.lua", .content = "Nested lua file" },
        .{ .name = "pkg-v1.0.0/src/lib/deep.lua", .content = "Deep lua file" },
        .{ .name = "standalone.txt", .content = "Standalone root file" },
    };

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "strip_test.tar.gz" });
    defer allocator.free(tar_path);
    try helpers.writeTarGzFile(allocator, io_val, tar_path, &entries);

    // 1. strip_components = 1
    const dest_strip1 = try std.fs.path.join(allocator, &.{ tmp_path, "out_strip1" });
    defer allocator.free(dest_strip1);
    try archive.extractTarGz(allocator, io_val, tar_path, dest_strip1, .{ .strip_components = 1 });

    const root_read = try tmp.dir.readFileAlloc(io_val, "out_strip1/root_file.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(root_read);
    try std.testing.expectEqualStrings("Root file", root_read);

    const nested_read = try tmp.dir.readFileAlloc(io_val, "out_strip1/src/nested.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(nested_read);
    try std.testing.expectEqualStrings("Nested lua file", nested_read);

    // standalone.txt should be skipped when stripping 1 component
    const standalone_exists = if (tmp.dir.access(io_val, "out_strip1/standalone.txt", .{})) |_| true else |_| false;
    try std.testing.expect(!standalone_exists);

    // 2. strip_components = 2
    const dest_strip2 = try std.fs.path.join(allocator, &.{ tmp_path, "out_strip2" });
    defer allocator.free(dest_strip2);
    try archive.extractTarGz(allocator, io_val, tar_path, dest_strip2, .{ .strip_components = 2 });

    const deep_read = try tmp.dir.readFileAlloc(io_val, "out_strip2/lib/deep.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(deep_read);
    try std.testing.expectEqualStrings("Deep lua file", deep_read);

    const nested_level2_read = try tmp.dir.readFileAlloc(io_val, "out_strip2/nested.lua", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(nested_level2_read);
    try std.testing.expectEqualStrings("Nested lua file", nested_level2_read);
}

test "Archive contract: unpackArchive auto-detection and extension handling" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "detected.txt", .content = "Auto-detected archive extension!" },
    };

    // Test .tar.zst
    const p1 = try std.fs.path.join(allocator, &.{ tmp_path, "auto.tar.zst" });
    defer allocator.free(p1);
    try helpers.writeTarZstdFile(allocator, io_val, p1, &entries);
    const d1 = try std.fs.path.join(allocator, &.{ tmp_path, "d1" });
    defer allocator.free(d1);
    try archive.unpackArchive(allocator, io_val, p1, d1, .{});

    // Test .tgz
    const p2 = try std.fs.path.join(allocator, &.{ tmp_path, "auto.tgz" });
    defer allocator.free(p2);
    try helpers.writeTarGzFile(allocator, io_val, p2, &entries);
    const d2 = try std.fs.path.join(allocator, &.{ tmp_path, "d2" });
    defer allocator.free(d2);
    try archive.unpackArchive(allocator, io_val, p2, d2, .{});

    // Test .tzst
    const p3 = try std.fs.path.join(allocator, &.{ tmp_path, "auto.tzst" });
    defer allocator.free(p3);
    try helpers.writeTarZstdFile(allocator, io_val, p3, &entries);
    const d3 = try std.fs.path.join(allocator, &.{ tmp_path, "d3" });
    defer allocator.free(d3);
    try archive.unpackArchive(allocator, io_val, p3, d3, .{});

    // Test .rock (treated as zip)
    const zip_entries = [_]helpers.ZipEntry{
        .{ .name = "rock_entry.txt", .content = "Rock content" },
    };
    const p4 = try std.fs.path.join(allocator, &.{ tmp_path, "sample.rock" });
    defer allocator.free(p4);
    try helpers.writeZipFile(allocator, io_val, p4, &zip_entries);
    const d4 = try std.fs.path.join(allocator, &.{ tmp_path, "d4" });
    defer allocator.free(d4);
    try archive.unpackArchive(allocator, io_val, p4, d4, .{});

    // Test unsupported format (.rar / .7z)
    const p_invalid = try std.fs.path.join(allocator, &.{ tmp_path, "unknown.rar" });
    defer allocator.free(p_invalid);
    try tmp.dir.writeFile(io_val, .{ .sub_path = "unknown.rar", .data = "dummy" });
    const d_invalid = try std.fs.path.join(allocator, &.{ tmp_path, "d_invalid" });
    defer allocator.free(d_invalid);

    try std.testing.expectError(error.UnsupportedArchiveFormat, archive.unpackArchive(allocator, io_val, p_invalid, d_invalid, .{}));
}
