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

test "Archive contract: Native TAR and ZIP preserve readable relative symlinks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "relative-links.tar" });
    defer allocator.free(tar_path);
    const tar_entries = [_]helpers.TarEntry{
        .{ .name = "target.txt", .content = "tar target" },
        .{ .name = "nested/link.txt", .kind = .symlink, .link_target = "../target.txt" },
    };
    try helpers.writeTarFile(allocator, io_val, tar_path, &tar_entries);

    const tar_dest = try std.fs.path.join(allocator, &.{ tmp_path, "out_relative_tar" });
    defer allocator.free(tar_dest);
    try archive.native.extractTar(allocator, io_val, tar_path, tar_dest, .{});

    const tar_link = try tmp.dir.readFileAlloc(io_val, "out_relative_tar/nested/link.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(tar_link);
    try std.testing.expectEqualStrings("tar target", tar_link);
    try tmp.dir.writeFile(io_val, .{ .sub_path = "out_relative_tar/target.txt", .data = "updated tar target" });
    const updated_tar_link = try tmp.dir.readFileAlloc(io_val, "out_relative_tar/nested/link.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(updated_tar_link);
    try std.testing.expectEqualStrings("updated tar target", updated_tar_link);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "relative-links.zip" });
    defer allocator.free(zip_path);
    const zip_entries = [_]helpers.ZipEntry{
        .{ .name = "target.txt", .content = "zip target", .version_made_by = (3 << 8) | 20, .external_attributes = 0o100644 << 16 },
        .{ .name = "nested/link.txt", .content = "../target.txt", .version_made_by = (3 << 8) | 20, .external_attributes = 0o120777 << 16 },
    };
    try helpers.writeZipFile(allocator, io_val, zip_path, &zip_entries);

    const zip_dest = try std.fs.path.join(allocator, &.{ tmp_path, "out_relative_zip" });
    defer allocator.free(zip_dest);
    try archive.native.extractZip(allocator, io_val, zip_path, zip_dest, .{});

    const zip_link = try tmp.dir.readFileAlloc(io_val, "out_relative_zip/nested/link.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(zip_link);
    try std.testing.expectEqualStrings("zip target", zip_link);
    try tmp.dir.writeFile(io_val, .{ .sub_path = "out_relative_zip/target.txt", .data = "updated zip target" });
    const updated_zip_link = try tmp.dir.readFileAlloc(io_val, "out_relative_zip/nested/link.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(updated_zip_link);
    try std.testing.expectEqualStrings("updated zip target", updated_zip_link);
}

test "Archive contract: Native TAR and ZIP materialize forward directory symlinks" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "forward-directory-links.tar" });
    defer allocator.free(tar_path);
    const tar_entries = [_]helpers.TarEntry{
        .{ .name = "directory-link", .kind = .symlink, .link_target = "directory-target" },
        .{ .name = "directory-target", .kind = .directory, .mode = 0o755 },
        .{ .name = "directory-target/readable.txt", .content = "tar directory target" },
    };
    try helpers.writeTarFile(allocator, io_val, tar_path, &tar_entries);

    const tar_dest = try std.fs.path.join(allocator, &.{ tmp_path, "out_forward_tar" });
    defer allocator.free(tar_dest);
    try archive.native.extractTar(allocator, io_val, tar_path, tar_dest, .{});
    const tar_linked_file = try tmp.dir.readFileAlloc(io_val, "out_forward_tar/directory-link/readable.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(tar_linked_file);
    try std.testing.expectEqualStrings("tar directory target", tar_linked_file);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "forward-directory-links.zip" });
    defer allocator.free(zip_path);
    const zip_entries = [_]helpers.ZipEntry{
        .{ .name = "directory-link", .content = "directory-target", .version_made_by = (3 << 8) | 20, .external_attributes = 0o120777 << 16 },
        .{ .name = "directory-target/" },
        .{ .name = "directory-target/readable.txt", .content = "zip directory target" },
    };
    try helpers.writeZipFile(allocator, io_val, zip_path, &zip_entries);

    const zip_dest = try std.fs.path.join(allocator, &.{ tmp_path, "out_forward_zip" });
    defer allocator.free(zip_dest);
    try archive.native.extractZip(allocator, io_val, zip_path, zip_dest, .{});
    const zip_linked_file = try tmp.dir.readFileAlloc(io_val, "out_forward_zip/directory-link/readable.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(zip_linked_file);
    try std.testing.expectEqualStrings("zip directory target", zip_linked_file);
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

test "Archive contract: TAR extraction preserves executable bits and exact sanitized modes on POSIX" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "perm_test.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "bin/tool", .content = "#!/bin/sh\necho ok\n", .mode = 0o755 },
        .{ .name = "mk/luapath", .content = "#!/bin/sh\necho /usr/include\n", .mode = 0o755 },
        .{ .name = "normal.lua", .content = "return 'normal'\n", .mode = 0o644 },
        .{ .name = "private.key", .content = "secret", .mode = 0o600 },
        .{ .name = "admin.sh", .content = "#!/bin/sh\necho admin\n", .mode = 0o700 },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_perm" });
    defer allocator.free(dest_path);

    try archive.extractTar(allocator, io_val, tar_path, dest_path, .{});

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f_tool = try tmp.dir.openFile(io_val, "out_perm/bin/tool", .{});
        defer f_tool.close(io_val);
        const st_tool = try f_tool.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st_tool.permissions.toMode() & 0o777);

        var f_lua = try tmp.dir.openFile(io_val, "out_perm/mk/luapath", .{});
        defer f_lua.close(io_val);
        const st_lua = try f_lua.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st_lua.permissions.toMode() & 0o777);

        var f_norm = try tmp.dir.openFile(io_val, "out_perm/normal.lua", .{});
        defer f_norm.close(io_val);
        const st_norm = try f_norm.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), st_norm.permissions.toMode() & 0o777);

        var f_priv = try tmp.dir.openFile(io_val, "out_perm/private.key", .{});
        defer f_priv.close(io_val);
        const st_priv = try f_priv.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st_priv.permissions.toMode() & 0o777);
    }
}

test "Archive contract: Privilege bits (SUID, SGID, sticky) are strictly stripped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "privilege.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "suid_bin", .content = "suid", .mode = 0o4755 },
        .{ .name = "sgid_bin", .content = "sgid", .mode = 0o2755 },
        .{ .name = "both_bin", .content = "both", .mode = 0o6755 },
        .{ .name = "sticky_bin", .content = "sticky", .mode = 0o1777 },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_priv" });
    defer allocator.free(dest_path);

    try archive.extractTar(allocator, io_val, tar_path, dest_path, .{});

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f1 = try tmp.dir.openFile(io_val, "out_priv/suid_bin", .{});
        defer f1.close(io_val);
        const st1 = try f1.stat(io_val);
        // SUID 04000 stripped -> 0755
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st1.permissions.toMode() & 0o7777);

        var f2 = try tmp.dir.openFile(io_val, "out_priv/sgid_bin", .{});
        defer f2.close(io_val);
        const st2 = try f2.stat(io_val);
        // SGID 02000 stripped -> 0755
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st2.permissions.toMode() & 0o7777);

        var f3 = try tmp.dir.openFile(io_val, "out_priv/both_bin", .{});
        defer f3.close(io_val);
        const st3 = try f3.stat(io_val);
        // 06755 stripped -> 0755
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st3.permissions.toMode() & 0o7777);

        var f4 = try tmp.dir.openFile(io_val, "out_priv/sticky_bin", .{});
        defer f4.close(io_val);
        const st4 = try f4.stat(io_val);
        // Sticky 01000 stripped -> 0777 (or 0755 if system umask applies)
        const m4 = st4.permissions.toMode() & 0o7777;
        try std.testing.expect(m4 == 0o777 or m4 == 0o755);
        try std.testing.expect((m4 & 0o7000) == 0);
    }
}

test "Archive contract: Restrictive files (0444, 0400) extract successfully because permissions apply after writing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "readonly.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "readonly.txt", .content = "Read-only payload content", .mode = 0o444 },
        .{ .name = "user_readonly.txt", .content = "User read only content", .mode = 0o400 },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_ro" });
    defer allocator.free(dest_path);

    try archive.extractTar(allocator, io_val, tar_path, dest_path, .{});

    const c1 = try tmp.dir.readFileAlloc(io_val, "out_ro/readonly.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(c1);
    try std.testing.expectEqualStrings("Read-only payload content", c1);

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f1 = try tmp.dir.openFile(io_val, "out_ro/readonly.txt", .{});
        defer f1.close(io_val);
        const st1 = try f1.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o444), st1.permissions.toMode() & 0o777);
    }
}

test "Archive contract: Restrictive directory permissions (0555) deferred until descendants extracted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "restrict_dir.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "locked", .kind = .directory, .mode = 0o555 },
        .{ .name = "locked/child.txt", .content = "Child inside locked directory", .mode = 0o644 },
        .{ .name = "locked/nested", .kind = .directory, .mode = 0o555 },
        .{ .name = "locked/nested/deep.txt", .content = "Deep child inside nested locked dir", .mode = 0o644 },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_locked" });
    defer allocator.free(dest_path);

    try archive.extractTar(allocator, io_val, tar_path, dest_path, .{});

    const c1 = try tmp.dir.readFileAlloc(io_val, "out_locked/locked/child.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(c1);
    try std.testing.expectEqualStrings("Child inside locked directory", c1);

    const c2 = try tmp.dir.readFileAlloc(io_val, "out_locked/locked/nested/deep.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(c2);
    try std.testing.expectEqualStrings("Deep child inside nested locked dir", c2);

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var d1 = try tmp.dir.openDir(io_val, "out_locked/locked", .{});
        defer d1.close(io_val);
        const st1 = try d1.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o555), st1.permissions.toMode() & 0o777);

        // Fix permissions so tmp directory cleanup succeeds on restrictive test folders
        tmp.dir.setFilePermissions(io_val, "out_locked/locked/nested", std.Io.File.Permissions.fromMode(0o777), .{}) catch {};
        tmp.dir.setFilePermissions(io_val, "out_locked/locked", std.Io.File.Permissions.fromMode(0o777), .{}) catch {};
    }
}

test "Archive contract: Executable script in archive is actually executable on host" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_gz_path = try std.fs.path.join(allocator, &.{ tmp_path, "exec_test.tar.gz" });
    defer allocator.free(tar_gz_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "run.sh", .content = "#!/bin/sh\nexit 0\n", .mode = 0o755 },
    };

    try helpers.writeTarGzFile(allocator, io_val, tar_gz_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_exec" });
    defer allocator.free(dest_path);

    try archive.extractTarGz(allocator, io_val, tar_gz_path, dest_path, .{});

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        const script_abs = try std.fs.path.join(allocator, &.{ dest_path, "run.sh" });
        defer allocator.free(script_abs);

        const run_res = try std.process.run(allocator, io_val, .{
            .argv = &.{script_abs},
        });
        defer allocator.free(run_res.stdout);
        defer allocator.free(run_res.stderr);

        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, run_res.term);
    }
}

test "Archive contract: ZIP extraction preserves UNIX executable bits and falls back on DOS creator" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "zip_perms.zip" });
    defer allocator.free(zip_path);

    const entries = [_]helpers.ZipEntry{
        // UNIX-created entry (version_made_by = 3 << 8) with 0755 executable mode
        .{
            .name = "bin/unix_tool",
            .content = "#!/bin/sh\necho unix\n",
            .version_made_by = (3 << 8) | 20,
            .external_attributes = (0o755 << 16) | 0o100000,
        },
        // DOS-created entry (version_made_by = 20)
        .{
            .name = "dos_file.txt",
            .content = "dos content",
            .version_made_by = 20,
            .external_attributes = 0x20, // archive attr
        },
    };

    try helpers.writeZipFile(allocator, io_val, zip_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_zipperm" });
    defer allocator.free(dest_path);

    try archive.extractZip(allocator, io_val, zip_path, dest_path, .{});

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f_unix = try tmp.dir.openFile(io_val, "out_zipperm/bin/unix_tool", .{});
        defer f_unix.close(io_val);
        const st_unix = try f_unix.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st_unix.permissions.toMode() & 0o777);

        var f_dos = try tmp.dir.openFile(io_val, "out_zipperm/dos_file.txt", .{});
        defer f_dos.close(io_val);
        const st_dos = try f_dos.stat(io_val);
        // Fallback default 0o644 (not 0000)
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), st_dos.permissions.toMode() & 0o777);
    }
}

test "Archive contract: createTarGz preserves source executable modes in roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    try tmp.dir.createDirPath(io_val, "src/bin");
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "src/bin/my_tool",
        .data = "#!/bin/sh\necho roundtrip\n",
    });
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "src/lib.lua",
        .data = "return { ok = true }\n",
    });

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f = try tmp.dir.openFile(io_val, "src/bin/my_tool", .{});
        defer f.close(io_val);
        try f.setPermissions(io_val, std.Io.File.Permissions.fromMode(0o755));
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const src_path = try std.fs.path.join(allocator, &.{ tmp_path, "src" });
    defer allocator.free(src_path);

    const tar_gz_path = try std.fs.path.join(allocator, &.{ tmp_path, "roundtrip.tar.gz" });
    defer allocator.free(tar_gz_path);

    try archive.createTarGz(allocator, io_val, src_path, tar_gz_path);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "extracted_roundtrip" });
    defer allocator.free(dest_path);

    try archive.extractTarGz(allocator, io_val, tar_gz_path, dest_path, .{});

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f_tool = try tmp.dir.openFile(io_val, "extracted_roundtrip/bin/my_tool", .{});
        defer f_tool.close(io_val);
        const st_tool = try f_tool.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), st_tool.permissions.toMode() & 0o777);

        var f_lib = try tmp.dir.openFile(io_val, "extracted_roundtrip/lib.lua", .{});
        defer f_lib.close(io_val);
        const st_lib = try f_lib.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), st_lib.permissions.toMode() & 0o777);
    }
}

test "Archive contract: Explicit mode 0000 preserves exact 0000 on file and directory with safe cleanup" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "zero_mode.tar" });
    defer allocator.free(tar_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "zero_dir", .kind = .directory, .mode = 0o000 },
        .{ .name = "zero_dir/zero_file.bin", .content = "secret binary data", .mode = 0o000 },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_zero" });
    defer allocator.free(dest_path);

    try archive.extractTar(allocator, io_val, tar_path, dest_path, .{});

    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        // 1. Verify zero_dir mode is 0o000 via parent directory statFile (fstatat)
        const st_d = try tmp.dir.statFile(io_val, "out_zero/zero_dir", .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o000), st_d.permissions.toMode() & 0o777);

        // Temporarily allow traversal through zero_dir to inspect child file mode
        try tmp.dir.setFilePermissions(io_val, "out_zero/zero_dir", std.Io.File.Permissions.fromMode(0o755), .{});

        // 2. Verify zero_file.bin mode is 0o000
        const st_f = try tmp.dir.statFile(io_val, "out_zero/zero_dir/zero_file.bin", .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o000), st_f.permissions.toMode() & 0o777);

        // Fix file permissions so tmp directory cleanup succeeds
        tmp.dir.setFilePermissions(io_val, "out_zero/zero_dir/zero_file.bin", std.Io.File.Permissions.fromMode(0o644), .{}) catch {};
    }
}

test "Archive contract: ZIP S_IFLNK extracts safely as symlink without permission mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "symlink_test.zip" });
    defer allocator.free(zip_path);

    const entries = [_]helpers.ZipEntry{
        .{
            .name = "real_target.txt",
            .content = "Original target content\n",
            .version_made_by = (3 << 8) | 20,
            .external_attributes = (0o100644 << 16), // S_IFREG + 0644
        },
        .{
            .name = "link_to_target",
            .content = "real_target.txt",
            .version_made_by = (3 << 8) | 20,
            .external_attributes = (0o120777 << 16), // S_IFLNK + 0777
        },
    };

    try helpers.writeZipFile(allocator, io_val, zip_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_zlink" });
    defer allocator.free(dest_path);

    try archive.extractZip(allocator, io_val, zip_path, dest_path, .{});

    // Verify reading symlink resolves to target content
    const content = try tmp.dir.readFileAlloc(io_val, "out_zlink/link_to_target", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("Original target content\n", content);

    // Verify target file's permissions were not mutated by symlink extraction
    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        var f_target = try tmp.dir.openFile(io_val, "out_zlink/real_target.txt", .{});
        defer f_target.close(io_val);
        const st = try f_target.stat(io_val);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), st.permissions.toMode() & 0o777);
    }
}

test "Archive contract: ZIP special device files (FIFO/char dev) are rejected" {
    const build_options = @import("build_options");
    if (comptime build_options.archive_backend == .system) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "fifo.zip" });
    defer allocator.free(zip_path);

    const entries = [_]helpers.ZipEntry{
        .{
            .name = "my_fifo",
            .content = "",
            .version_made_by = (3 << 8) | 20,
            .external_attributes = (0o010644 << 16), // S_IFIFO
        },
    };

    try helpers.writeZipFile(allocator, io_val, zip_path, &entries);

    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "out_fifo" });
    defer allocator.free(dest_path);

    try std.testing.expectError(error.UnsupportedArchiveFormat, archive.extractZip(allocator, io_val, zip_path, dest_path, .{}));
}
