const std = @import("std");
const moonstone = @import("moonstone");
const archive = moonstone.archive;

test "Zstd compression and decompression roundtrip" {
    const allocator = std.testing.allocator;
    const test_data = "Moonstone native Zstandard compression test string with repetitive content: abcabcabcabcabc 1234567890 1234567890";

    const compressed = try archive.compressZstdBytes(allocator, test_data);
    defer allocator.free(compressed);

    // Verify magic bytes
    try std.testing.expect(compressed.len >= 4);
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0xB5, 0x2F, 0xFD }, compressed[0..4]);

    const decompressed = try archive.decompressZstdBytes(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(test_data, decompressed);
}

test "Zstd empty input roundtrip" {
    const allocator = std.testing.allocator;
    const empty_data = "";

    const compressed = try archive.compressZstdBytes(allocator, empty_data);
    defer allocator.free(compressed);

    const decompressed = try archive.decompressZstdBytes(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(empty_data, decompressed);
}

test "Zstd file compression and decompression roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    try tmp.dir.writeFile(io_val, .{
        .sub_path = "input.txt",
        .data = "File-based Zstandard compression payload for Moonstone",
    });

    const root_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(root_path);

    const in_path = try std.fs.path.join(allocator, &.{ root_path, "input.txt" });
    defer allocator.free(in_path);

    const zst_path = try std.fs.path.join(allocator, &.{ root_path, "compressed.zst" });
    defer allocator.free(zst_path);

    const out_path = try std.fs.path.join(allocator, &.{ root_path, "decompressed.txt" });
    defer allocator.free(out_path);

    try archive.compressZstdFile(allocator, io_val, in_path, zst_path);
    try archive.decompressZstdFile(allocator, io_val, zst_path, out_path);

    const content = try tmp.dir.readFileAlloc(io_val, "decompressed.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("File-based Zstandard compression payload for Moonstone", content);
}

test "TAR.GZ creation and extraction roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    // Create source structure
    try tmp.dir.createDirPath(io_val, "src/nested/dir");
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "src/hello.txt",
        .data = "Hello, world from archive test!",
    });
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "src/nested/dir/data.bin",
        .data = &.{ 0x01, 0x02, 0x03, 0x04, 0xFF, 0xFE },
    });

    const src_path = try tmp.dir.realPathFileAlloc(io_val, "src", allocator);
    defer allocator.free(src_path);

    const archive_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(archive_path);
    const tar_gz_path = try std.fs.path.join(allocator, &.{ archive_path, "output.tar.gz" });
    defer allocator.free(tar_gz_path);

    try archive.createTarGz(allocator, io_val, src_path, tar_gz_path);

    // Extract to destination
    try tmp.dir.createDirPath(io_val, "extracted");
    const dest_path = try tmp.dir.realPathFileAlloc(io_val, "extracted", allocator);
    defer allocator.free(dest_path);

    try archive.extractTarGz(allocator, io_val, tar_gz_path, dest_path, .{});

    // Verify extracted files
    const hello_content = try tmp.dir.readFileAlloc(io_val, "extracted/hello.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(hello_content);
    try std.testing.expectEqualStrings("Hello, world from archive test!", hello_content);

    const bin_content = try tmp.dir.readFileAlloc(io_val, "extracted/nested/dir/data.bin", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(bin_content);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04, 0xFF, 0xFE }, bin_content);

    // Also verify unpackArchive auto-detection
    try tmp.dir.createDirPath(io_val, "unpack_dest");
    const unpack_dest_path = try tmp.dir.realPathFileAlloc(io_val, "unpack_dest", allocator);
    defer allocator.free(unpack_dest_path);

    try archive.unpackArchive(allocator, io_val, tar_gz_path, unpack_dest_path, .{});
    const unpacked_hello = try tmp.dir.readFileAlloc(io_val, "unpack_dest/hello.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(unpacked_hello);
    try std.testing.expectEqualStrings("Hello, world from archive test!", unpacked_hello);
}
