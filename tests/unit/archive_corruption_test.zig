const std = @import("std");
const moonstone = @import("moonstone");
const archive = moonstone.archive;
const helpers = @import("test_archive_helpers.zig");

test "Archive corruption: Invalid Zstd magic numbers" {
    const allocator = std.testing.allocator;

    // 1. All zeroes
    const zeroes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const err_zeroes = archive.native.decompressZstdBytes(allocator, &zeroes);
    try std.testing.expectError(error.InvalidZstdMagic, err_zeroes);

    // 2. Modified magic byte (standard magic is 0x28, 0xB5, 0x2F, 0xFD)
    const bad_magic = [_]u8{ 0x28, 0xB5, 0x2F, 0xFE, 0x00, 0x38, 0x01, 0x00, 0x00 };
    const err_bad_magic = archive.native.decompressZstdBytes(allocator, &bad_magic);
    try std.testing.expectError(error.InvalidZstdMagic, err_bad_magic);

    // 3. Random noise
    const noise = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x12, 0x34 };
    const err_noise = archive.native.decompressZstdBytes(allocator, &noise);
    try std.testing.expectError(error.InvalidZstdMagic, err_noise);
}

test "Archive corruption: Truncated Zstd frames" {
    const allocator = std.testing.allocator;

    // 1. Valid magic only (4 bytes, no frame header)
    const magic_only = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    const err_magic_only = archive.native.decompressZstdBytes(allocator, &magic_only);
    try std.testing.expect(err_magic_only == error.UnexpectedEndOfStream or err_magic_only == error.CorruptArchive or err_magic_only == error.ZstdDecompressionFailed);

    // 2. Magic + Frame Header only (6 bytes, no blocks)
    const header_only = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38 };
    const err_header_only = archive.native.decompressZstdBytes(allocator, &header_only);
    try std.testing.expect(err_header_only == error.UnexpectedEndOfStream or err_header_only == error.CorruptArchive or err_header_only == error.ZstdDecompressionFailed);

    // 3. Block header declaring 500 bytes (last=1, type=raw, size=500), but stream cut off after 10 bytes
    // block header u24: (500 << 3) | 1 = 4001 = 0x000FA1 -> A1 0F 00
    const truncated_payload = [_]u8{
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38, // Magic + Frame header
        0xA1, 0x0F, 0x00, // Block header: 500 bytes expected
        'A',  'B',  'C',  'D',  'E', // Only 5 bytes provided!
    };
    const err_trunc = archive.native.decompressZstdBytes(allocator, &truncated_payload);
    try std.testing.expect(err_trunc == error.UnexpectedEndOfStream or err_trunc == error.CorruptArchive or err_trunc == error.ZstdDecompressionFailed);
}

test "Archive corruption: Malformed Zstd block headers" {
    const allocator = std.testing.allocator;

    // Block header declaring reserved block type (bits 1-2 = 11 = 3)
    // u24: (10 << 3) | (3 << 1) | 1 = 80 | 6 | 1 = 87 = 0x57 -> 57 00 00
    const reserved_block = [_]u8{
        0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38,
        0x57, 0x00, 0x00,
        1,    2,    3,    4,    5,    6,    7, 8, 9, 10,
    };
    const err_reserved = archive.native.decompressZstdBytes(allocator, &reserved_block);
    try std.testing.expect(err_reserved == error.CorruptArchive or err_reserved == error.ZstdDecompressionFailed);
}

test "Archive corruption: Truncated and malformed TAR streams" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // 1. Incomplete TAR header (< 512 bytes)
    const incomplete_header_path = try std.fs.path.join(allocator, &.{ tmp_path, "truncated_hdr.tar" });
    defer allocator.free(incomplete_header_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "truncated_hdr.tar",
        .data = "ustar file header truncated before 512 bytes...",
    });

    const dest1 = try std.fs.path.join(allocator, &.{ tmp_path, "dest1" });
    defer allocator.free(dest1);
    const err_hdr = archive.native.extractTar(allocator, io_val, incomplete_header_path, dest1, .{});
    try std.testing.expect(err_hdr == error.CorruptedTarHeader or err_hdr == error.UnexpectedEndOfStream or err_hdr == error.CorruptArchive or err_hdr == error.TarExtractionFailed);

    // 2. Header declaring 5000 byte file, but payload truncated after 100 bytes
    const header = helpers.createRawTarHeader("large_truncated.dat", 5000, 0o644, '0', "");
    var trunc_tar = std.ArrayList(u8).empty;
    defer trunc_tar.deinit(allocator);
    try trunc_tar.appendSlice(allocator, &header);
    try trunc_tar.appendSlice(allocator, "Only 30 bytes of payload instead of 5000 bytes");

    const truncated_payload_path = try std.fs.path.join(allocator, &.{ tmp_path, "truncated_payload.tar" });
    defer allocator.free(truncated_payload_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "truncated_payload.tar",
        .data = trunc_tar.items,
    });

    const dest2 = try std.fs.path.join(allocator, &.{ tmp_path, "dest2" });
    defer allocator.free(dest2);
    const err_pay = archive.native.extractTar(allocator, io_val, truncated_payload_path, dest2, .{});
    try std.testing.expect(err_pay == error.CorruptedTarHeader or err_pay == error.UnexpectedEndOfStream or err_pay == error.CorruptArchive or err_pay == error.TarExtractionFailed or err_pay == error.EndOfStream);

    // 3. Header with invalid checksum
    var bad_checksum_hdr = header;
    @memset(bad_checksum_hdr[148..156], 'X'); // Invalidate checksum field

    const bad_checksum_path = try std.fs.path.join(allocator, &.{ tmp_path, "bad_checksum.tar" });
    defer allocator.free(bad_checksum_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "bad_checksum.tar",
        .data = &bad_checksum_hdr,
    });

    const dest3 = try std.fs.path.join(allocator, &.{ tmp_path, "dest3" });
    defer allocator.free(dest3);
    const err_chk = archive.native.extractTar(allocator, io_val, bad_checksum_path, dest3, .{});
    try std.testing.expect(err_chk == error.CorruptedTarHeader or err_chk == error.CorruptArchive or err_chk == error.TarExtractionFailed or err_chk == error.TarHeader);
}

test "Archive corruption: Malformed and truncated GZIP streams" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // 1. Incomplete GZIP header (< 10 bytes)
    const bad_gz_path = try std.fs.path.join(allocator, &.{ tmp_path, "bad_header.tar.gz" });
    defer allocator.free(bad_gz_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "bad_header.tar.gz",
        .data = &[_]u8{ 0x1F, 0x8B, 0x08 }, // Truncated gzip magic/header
    });

    const dest1 = try std.fs.path.join(allocator, &.{ tmp_path, "dest_gz1" });
    defer allocator.free(dest1);
    const err_gz1 = archive.native.extractTarGz(allocator, io_val, bad_gz_path, dest1, .{});
    try std.testing.expect(err_gz1 == error.CorruptArchive or err_gz1 == error.GzipDecompressionFailed or err_gz1 == error.TarExtractionFailed or err_gz1 == error.UnexpectedEndOfStream or err_gz1 == error.CorruptedTarHeader or err_gz1 == error.EndOfStream or err_gz1 == error.WrongMagic or err_gz1 == error.ReadFailed);

    // 2. Corrupted payload after valid GZIP header
    const bad_payload_path = try std.fs.path.join(allocator, &.{ tmp_path, "bad_payload.tar.gz" });
    defer allocator.free(bad_payload_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "bad_payload.tar.gz",
        .data = &[_]u8{ 0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xFF, 0xFE, 0xFD, 0xFC },
    });

    const dest2 = try std.fs.path.join(allocator, &.{ tmp_path, "dest_gz2" });
    defer allocator.free(dest2);
    const err_gz2 = archive.native.extractTarGz(allocator, io_val, bad_payload_path, dest2, .{});
    try std.testing.expect(err_gz2 == error.CorruptArchive or err_gz2 == error.GzipDecompressionFailed or err_gz2 == error.TarExtractionFailed or err_gz2 == error.UnexpectedEndOfStream or err_gz2 == error.CorruptedTarHeader or err_gz2 == error.EndOfStream or err_gz2 == error.BadGzipChecksum or err_gz2 == error.BadHeaderChecksum or err_gz2 == error.ReadFailed);
}

test "Archive corruption: Malformed and truncated ZIP streams" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // 1. Random bytes fed as ZIP (no End of Central Directory record)
    const bad_zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "no_eocd.zip" });
    defer allocator.free(bad_zip_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "no_eocd.zip",
        .data = "This is not a zip file and has no central directory record!",
    });

    const dest1 = try std.fs.path.join(allocator, &.{ tmp_path, "dest_zip1" });
    defer allocator.free(dest1);
    const err_zip1 = archive.native.extractZip(allocator, io_val, bad_zip_path, dest1, .{});
    try std.testing.expect(err_zip1 == error.CorruptArchive or err_zip1 == error.ZipExtractionFailed or err_zip1 == error.ZipNoEndRecord or err_zip1 == error.EndOfStream);

    // 2. ZIP with corrupted local file header signature
    const valid_entries = [_]helpers.ZipEntry{
        .{ .name = "test.txt", .content = "hello" },
    };
    const valid_zip = try helpers.createZipBuffer(allocator, &valid_entries);
    defer allocator.free(valid_zip);

    var corrupted_local_hdr = try allocator.dupe(u8, valid_zip);
    defer allocator.free(corrupted_local_hdr);
    corrupted_local_hdr[0] = 'X'; // Invalidate PK\x03\x04 signature

    const bad_local_hdr_path = try std.fs.path.join(allocator, &.{ tmp_path, "bad_local.zip" });
    defer allocator.free(bad_local_hdr_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "bad_local.zip",
        .data = corrupted_local_hdr,
    });

    const dest2 = try std.fs.path.join(allocator, &.{ tmp_path, "dest_zip2" });
    defer allocator.free(dest2);
    const err_zip2 = archive.native.extractZip(allocator, io_val, bad_local_hdr_path, dest2, .{});
    try std.testing.expect(err_zip2 == error.CorruptArchive or err_zip2 == error.ZipExtractionFailed);
}

test "Archive corruption: Random garbage bytes across all extraction formats" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    var garbage: [256]u8 = undefined;
    for (&garbage, 0..) |*b, i| {
        b.* = @truncate((i * 101 + 37) % 256);
    }

    const garbage_file_path = try std.fs.path.join(allocator, &.{ tmp_path, "garbage.bin" });
    defer allocator.free(garbage_file_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "garbage.bin",
        .data = &garbage,
    });

    const dest = try std.fs.path.join(allocator, &.{ tmp_path, "dest_garbage" });
    defer allocator.free(dest);

    // Extracting garbage as tar must fail
    const tar_res = archive.native.extractTar(allocator, io_val, garbage_file_path, dest, .{});
    try std.testing.expect(tar_res == error.CorruptedTarHeader or tar_res == error.UnexpectedEndOfStream or tar_res == error.TarHeader or tar_res == error.TarExtractionFailed);

    // Extracting garbage as tar.gz must fail
    const gz_res = archive.native.extractTarGz(allocator, io_val, garbage_file_path, dest, .{});
    try std.testing.expect(gz_res == error.CorruptArchive or gz_res == error.GzipDecompressionFailed or gz_res == error.TarExtractionFailed or gz_res == error.CorruptedTarHeader or gz_res == error.WrongMagic or gz_res == error.ReadFailed);

    // Extracting garbage as tar.zst must fail
    const zst_res = archive.native.extractTarZstd(allocator, io_val, garbage_file_path, dest, .{});
    try std.testing.expect(zst_res == error.InvalidZstdMagic or zst_res == error.CorruptArchive or zst_res == error.ZstdDecompressionFailed);

    // Extracting garbage as zip must fail
    const zip_res = archive.native.extractZip(allocator, io_val, garbage_file_path, dest, .{});
    try std.testing.expect(zip_res == error.CorruptArchive or zip_res == error.ZipExtractionFailed);

    // unpackArchive on garbage path must fail
    const unpack_res = archive.native.unpackArchive(allocator, io_val, garbage_file_path, dest, .{});
    try std.testing.expect(unpack_res == error.UnsupportedArchiveFormat);
}

test "Archive error: Non-existent archive file path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const non_existent = "/non_existent_path_moonstone_test_12345/missing.tar.gz";
    const dest = try std.fs.path.join(allocator, &.{ tmp_path, "dest_nonexistent" });
    defer allocator.free(dest);

    const err_tar = archive.native.extractTar(allocator, io_val, non_existent, dest, .{});
    try std.testing.expect(err_tar == error.FileNotFound or err_tar == error.TarExtractionFailed);

    const err_targz = archive.native.extractTarGz(allocator, io_val, non_existent, dest, .{});
    try std.testing.expect(err_targz == error.FileNotFound or err_targz == error.TarExtractionFailed);

    const err_tarzst = archive.native.extractTarZstd(allocator, io_val, non_existent, dest, .{});
    try std.testing.expect(err_tarzst == error.FileNotFound or err_tarzst == error.TarExtractionFailed);

    const err_zip = archive.native.extractZip(allocator, io_val, non_existent, dest, .{});
    try std.testing.expect(err_zip == error.FileNotFound or err_zip == error.ZipExtractionFailed);
}

test "Archive error: Destination is an existing file (not a directory)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "valid.tar" });
    defer allocator.free(tar_path);
    const entries = [_]helpers.TarEntry{
        .{ .name = "item.txt", .content = "hello" },
    };
    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    // Create a regular file at the destination path
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "file_blocking_dir",
        .data = "I am a file, not a directory",
    });
    const bad_dest = try std.fs.path.join(allocator, &.{ tmp_path, "file_blocking_dir" });
    defer allocator.free(bad_dest);

    const res = archive.native.extractTar(allocator, io_val, tar_path, bad_dest, .{});
    try std.testing.expect(res == error.NotDir or res == error.PathAlreadyExists or res == error.TarExtractionFailed);
}
