const std = @import("std");
const builtin = @import("builtin");
const path_validation = @import("path_validation.zig");

pub const ExtractOptions = struct {
    strip_components: u32 = 0,
    allow_symlinks: bool = true,
    overwrite: bool = true,
};

pub const ArchiveError = error{
    CorruptArchive,
    UnsupportedArchiveFormat,
    PathTraversalDetected,
    AbsolutePathsNotAllowed,
    SymlinkTargetEscapesDestination,
    NullByteInPath,
    InvalidPath,
    ZstdDecompressionFailed,
    ZstdCompressionFailed,
    GzipDecompressionFailed,
    GzipCompressionFailed,
    TarExtractionFailed,
    TarCreationFailed,
    ZipExtractionFailed,
    UnexpectedEndOfStream,
    InvalidZstdMagic,
    CorruptedTarHeader,
    UnsupportedZipStripComponents,
} || std.mem.Allocator.Error || std.Io.Dir.OpenError || std.Io.Dir.CreateFileError || std.Io.File.ReadError || std.Io.File.WriteError;

// ============================================================================
// Zstandard Compression & Decompression
// ============================================================================

/// Decompress Zstandard data from `reader` to `writer` using pure Zig streaming decompression.
pub fn decompressZstd(allocator: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    const window_buf_size = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
    const window_buf = try allocator.alloc(u8, window_buf_size);
    defer allocator.free(window_buf);

    var decompress = std.compress.zstd.Decompress.init(reader, window_buf, .{});
    _ = decompress.reader.streamRemaining(writer) catch |err| {
        if (decompress.err) |zstd_err| {
            switch (zstd_err) {
                error.BadMagic => return error.InvalidZstdMagic,
                error.MalformedFrame, error.MalformedBlock, error.ChecksumFailure => return error.CorruptArchive,
                error.EndOfStream => return error.UnexpectedEndOfStream,
                else => return error.ZstdDecompressionFailed,
            }
        }
        return err;
    };
}

/// Decompress a `.zst` file from `zst_path` to `out_path`.
pub fn decompressZstdFile(allocator: std.mem.Allocator, io: std.Io, zst_path: []const u8, out_path: []const u8) !void {
    var in_file = std.Io.Dir.cwd().openFile(io, zst_path, .{}) catch |err| return err;
    defer in_file.close(io);

    var out_file = std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch |err| return err;
    defer out_file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var in_buf: [32768]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);

    var out_buf: [32768]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    try decompressZstd(allocator, &in_reader.interface, &out_writer.interface);
    try out_writer.interface.flush();
}

/// Decompress in-memory Zstandard compressed bytes.
pub fn decompressZstdBytes(allocator: std.mem.Allocator, compressed_bytes: []const u8) ![]u8 {
    var in_reader: std.Io.Reader = .fixed(compressed_bytes);
    var out_writer: std.Io.Writer.Allocating = .init(allocator);
    defer out_writer.deinit();

    try decompressZstd(allocator, &in_reader, &out_writer.writer);
    return try out_writer.toOwnedSlice();
}

/// Compress arbitrary stream into a compliant RFC 8878 Zstandard frame using uncompressed raw blocks.
pub fn compressZstd(allocator: std.mem.Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    _ = allocator;

    // 1. Zstandard Frame Magic Number: 0xFD2FB528 (little endian)
    const magic = [4]u8{ 0x28, 0xB5, 0x2F, 0xFD };
    try writer.writeAll(&magic);

    // 2. Frame Header:
    // Frame_Header_Descriptor: 0x00 (Single_Segment=0, Checksum=0, DictID=0, ContentSize=0)
    // Window_Descriptor: 0x38 (Window size 128 KB = 1 << (10 + 7))
    const frame_header = [2]u8{ 0x00, 0x38 };
    try writer.writeAll(&frame_header);

    // 3. Stream data in blocks up to 128KB (std.compress.zstd.block_size_max)
    var buf: [std.compress.zstd.block_size_max]u8 = undefined;
    var current_len: usize = 0;
    var reached_eof = false;

    // Read initial block
    current_len = try reader.readSliceShort(&buf);
    if (current_len == 0) {
        // Empty stream: write 1 empty last block (last=1, type=raw, size=0)
        const empty_block_hdr = [3]u8{ 0x01, 0x00, 0x00 };
        try writer.writeAll(&empty_block_hdr);
        return;
    }

    var next_buf: [std.compress.zstd.block_size_max]u8 = undefined;

    while (!reached_eof) {
        // Lookahead read next block to determine if current block is last
        const next_len = try reader.readSliceShort(&next_buf);
        const is_last = (next_len == 0);

        // Block Header: 3 bytes little-endian u24
        // bit 0: last block flag
        // bits 1-2: block type (00 = Raw_Block)
        // bits 3-23: block size
        const hdr_u24: u24 = (@as(u24, @intCast(current_len)) << 3) | (@as(u24, 0) << 1) | (@as(u24, if (is_last) 1 else 0));
        const hdr_bytes = [3]u8{
            @truncate(hdr_u24),
            @truncate(hdr_u24 >> 8),
            @truncate(hdr_u24 >> 16),
        };

        try writer.writeAll(&hdr_bytes);
        try writer.writeAll(buf[0..current_len]);

        if (is_last) {
            reached_eof = true;
        } else {
            @memcpy(buf[0..next_len], next_buf[0..next_len]);
            current_len = next_len;
        }
    }
}

/// Compress a file from `in_path` to `out_path` as Zstandard.
pub fn compressZstdFile(allocator: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !void {
    var in_file = std.Io.Dir.cwd().openFile(io, in_path, .{}) catch |err| return err;
    defer in_file.close(io);

    var out_file = std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true }) catch |err| return err;
    defer out_file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var in_buf: [32768]u8 = undefined;
    var in_reader = in_file.reader(io, &in_buf);

    var out_buf: [32768]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    try compressZstd(allocator, &in_reader.interface, &out_writer.interface);
    try out_writer.interface.flush();
}

/// Compress in-memory bytes to Zstandard format.
pub fn compressZstdBytes(allocator: std.mem.Allocator, uncompressed_bytes: []const u8) ![]u8 {
    var in_reader: std.Io.Reader = .fixed(uncompressed_bytes);
    var out_writer: std.Io.Writer.Allocating = .init(allocator);
    defer out_writer.deinit();

    try compressZstd(allocator, &in_reader, &out_writer.writer);
    return try out_writer.toOwnedSlice();
}

// ============================================================================
// TAR Extraction & Creation (Pure Zig Streaming)
// ============================================================================

/// Safely extract a TAR archive from a stream `reader` into `dest_dir`.
pub fn extractTarStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
    dest_dir: std.Io.Dir,
    options: ExtractOptions,
) !void {
    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    while (it.next() catch |err| switch (err) {
        error.TarHeader, error.TarHeaderChksum, error.TarNumericValueNegative, error.TarNumericValueTooBig, error.TarUnsupportedHeader, error.TarHeadersTooBig => return error.CorruptedTarHeader,
        error.UnexpectedEndOfStream, error.EndOfStream => return error.UnexpectedEndOfStream,
        else => return err,
    }) |file| {
        // Strip components if requested
        var raw_name = file.name;
        if (options.strip_components > 0) {
            var comp_count: u32 = 0;
            var pos: usize = 0;
            while (pos < raw_name.len and comp_count < options.strip_components) {
                if (raw_name[pos] == '/' or raw_name[pos] == '\\') {
                    comp_count += 1;
                }
                pos += 1;
            }
            if (comp_count < options.strip_components) {
                // Not enough components to strip, skip this entry
                continue;
            }
            raw_name = raw_name[pos..];
        }

        if (raw_name.len == 0) continue;

        // Path validation and traversal protection
        const sanitized_rel_path = path_validation.sanitizeArchivePath(allocator, raw_name) catch |err| switch (err) {
            error.PathTraversalDetected => return error.PathTraversalDetected,
            error.AbsolutePathsNotAllowed => return error.AbsolutePathsNotAllowed,
            error.NullByteInPath => return error.NullByteInPath,
            error.InvalidPath => continue,
            else => return error.PathTraversalDetected,
        };
        defer allocator.free(sanitized_rel_path);

        if (sanitized_rel_path.len == 0) continue;

        switch (file.kind) {
            .directory => {
                try dest_dir.createDirPath(io, sanitized_rel_path);
            },
            .file => {
                if (std.fs.path.dirname(sanitized_rel_path)) |parent| {
                    if (parent.len > 0) {
                        try dest_dir.createDirPath(io, parent);
                    }
                }

                // Strip setuid/setgid/sticky bits for security
                const safe_mode: u32 = file.mode & 0o777;
                _ = safe_mode;

                const create_opts: std.Io.Dir.CreateFileOptions = if (options.overwrite)
                    .{ .truncate = true }
                else
                    .{ .exclusive = true };

                var out_file = dest_dir.createFile(io, sanitized_rel_path, create_opts) catch |err| switch (err) {
                    error.FileNotFound => blk: {
                        if (std.fs.path.dirname(sanitized_rel_path)) |parent| {
                            try dest_dir.createDirPath(io, parent);
                            break :blk try dest_dir.createFile(io, sanitized_rel_path, create_opts);
                        }
                        return err;
                    },
                    else => return err,
                };
                defer out_file.close(io);

                var write_buf: [16384]u8 = undefined;
                var fw = out_file.writer(io, &write_buf);
                try it.streamRemaining(file, &fw.interface);
                try fw.interface.flush();
            },
            .sym_link => {
                if (!options.allow_symlinks) return error.SymlinkTargetEscapesDestination;

                try path_validation.validateSymlinkTarget(file.link_name, sanitized_rel_path);

                if (std.fs.path.dirname(sanitized_rel_path)) |parent| {
                    if (parent.len > 0) {
                        try dest_dir.createDirPath(io, parent);
                    }
                }

                dest_dir.deleteFile(io, sanitized_rel_path) catch {};
                try dest_dir.symLink(io, file.link_name, sanitized_rel_path, .{});
            },
        }
    }
}

/// Extract an uncompressed `.tar` archive.
pub fn extractTar(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_path: []const u8,
    options: ExtractOptions,
) !void {
    var file = std.Io.Dir.cwd().openFile(io, archive_path, .{}) catch |err| return err;
    defer file.close(io);

    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    var dest_dir = std.Io.Dir.cwd().openDir(io, dest_path, .{}) catch |err| return err;
    defer dest_dir.close(io);

    var file_buf: [32768]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    try extractTarStream(allocator, io, &file_reader.interface, dest_dir, options);
}

/// Extract a `.tar.gz` (or `.tgz`) archive using pure Zig gzip decompression + tar iterator.
pub fn extractTarGz(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_path: []const u8,
    options: ExtractOptions,
) !void {
    var file = std.Io.Dir.cwd().openFile(io, archive_path, .{}) catch |err| return err;
    defer file.close(io);

    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    var dest_dir = std.Io.Dir.cwd().openDir(io, dest_path, .{}) catch |err| return err;
    defer dest_dir.close(io);

    var file_buf: [32768]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var gz_decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &flate_buf);

    extractTarStream(allocator, io, &gz_decompress.reader, dest_dir, options) catch |err| {
        if (gz_decompress.err) |gz_err| {
            switch (gz_err) {
                error.BadGzipHeader, error.BadZlibHeader, error.InvalidBlockType, error.InvalidCode, error.InvalidDynamicBlockHeader, error.InvalidMatch, error.MissingEndOfBlockCode, error.OversubscribedHuffmanTree, error.WrongGzipChecksum, error.WrongGzipSize, error.WrongStoredBlockNlen, error.WrongZlibChecksum, error.IncompleteHuffmanTree => return error.CorruptArchive,
                error.EndOfStream => return error.UnexpectedEndOfStream,
                else => return error.GzipDecompressionFailed,
            }
        }
        switch (err) {
            error.ReadFailed => return error.CorruptArchive,
            error.EndOfStream, error.UnexpectedEndOfStream => return error.UnexpectedEndOfStream,
            error.CorruptedTarHeader => return error.CorruptArchive,
            else => return err,
        }
    };
}

/// Extract a `.tar.zst` archive using pure Zig zstd streaming decompression + tar iterator.
pub fn extractTarZstd(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_path: []const u8,
    options: ExtractOptions,
) !void {
    var file = std.Io.Dir.cwd().openFile(io, archive_path, .{}) catch |err| return err;
    defer file.close(io);

    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    var dest_dir = std.Io.Dir.cwd().openDir(io, dest_path, .{}) catch |err| return err;
    defer dest_dir.close(io);

    var file_buf: [32768]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    const window_buf_size = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;
    const window_buf = try allocator.alloc(u8, window_buf_size);
    defer allocator.free(window_buf);

    var zstd_decompress = std.compress.zstd.Decompress.init(&file_reader.interface, window_buf, .{});

    extractTarStream(allocator, io, &zstd_decompress.reader, dest_dir, options) catch |err| {
        if (zstd_decompress.err) |zstd_err| {
            switch (zstd_err) {
                error.BadMagic => return error.InvalidZstdMagic,
                error.MalformedFrame, error.MalformedBlock, error.ChecksumFailure => return error.CorruptArchive,
                error.EndOfStream => return error.UnexpectedEndOfStream,
                else => return error.ZstdDecompressionFailed,
            }
        }
        switch (err) {
            error.ReadFailed => return error.CorruptArchive,
            error.EndOfStream, error.UnexpectedEndOfStream => return error.UnexpectedEndOfStream,
            error.CorruptedTarHeader => return error.CorruptArchive,
            else => return err,
        }
    };
}

/// Create a `.tar.gz` archive from `src_dir_path` into `out_tar_gz_path`.
pub fn createTarGz(
    allocator: std.mem.Allocator,
    io: std.Io,
    src_dir_path: []const u8,
    out_tar_gz_path: []const u8,
) !void {
    var out_file = try std.Io.Dir.cwd().createFile(io, out_tar_gz_path, .{ .truncate = true });
    defer out_file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, out_tar_gz_path) catch {};

    var file_buf: [32768]u8 = undefined;
    var file_writer = out_file.writer(io, &file_buf);

    var flate_comp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&file_writer.interface, &flate_comp_buf, .gzip, .default);

    var tar_writer: std.tar.Writer = .{
        .underlying_writer = &compressor.writer,
    };

    var src_dir = try std.Io.Dir.cwd().openDir(io, src_dir_path, .{ .iterate = true });
    defer src_dir.close(io);

    try writeDirectoryRecursive(allocator, io, src_dir, "", &tar_writer);

    try compressor.finish();
    try file_writer.interface.flush();
}

fn writeDirectoryRecursive(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    current_prefix: []const u8,
    tar_writer: *std.tar.Writer,
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel_path = if (current_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_prefix, entry.name });
        defer allocator.free(rel_path);

        switch (entry.kind) {
            .directory => {
                try tar_writer.writeDir(rel_path, .{ .mode = 0o755 });
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);
                try writeDirectoryRecursive(allocator, io, sub_dir, rel_path, tar_writer);
            },
            .file => {
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);

                const size = try f.length(io);
                const content = try dir.readFileAlloc(io, entry.name, allocator, std.Io.Limit.limited(size + 1024));
                defer allocator.free(content);

                try tar_writer.writeFileBytes(rel_path, content, .{ .mode = 0o644 });
            },
            .sym_link => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const target_len = try dir.readLink(io, entry.name, &link_buf);
                const target = link_buf[0..target_len];
                try tar_writer.writeLink(rel_path, target, .{});
            },
            else => {},
        }
    }
}

// ============================================================================
// ZIP Extraction (Pure Zig Streaming)
// ============================================================================

/// Extract a ZIP archive using `std.zip`.
pub fn extractZip(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_path: []const u8,
    options: ExtractOptions,
) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);

    try std.Io.Dir.cwd().createDirPath(io, dest_path);
    var dest_dir = try std.Io.Dir.cwd().openDir(io, dest_path, .{});
    defer dest_dir.close(io);

    var file_buf: [32768]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var iter = std.zip.Iterator.init(&file_reader) catch |err| switch (err) {
        error.ZipNoEndRecord, error.ZipTruncated, error.ZipBadLocatorSig, error.ZipBadEndRecord64Sig, error.ZipEndRecord64SizeTooSmall, error.ZipEndRecord64UnhandledExtraData, error.ZipDiskRecordCountTooLarge, error.Zip64RecordCountTotalMismatch, error.Zip64CentralDirectoryOffsetMismatch => return error.CorruptArchive,
        error.ZipMultiDiskUnsupported, error.ZipUnsupportedZip64DiskCount, error.ZipUnsupportedVersion => return error.UnsupportedArchiveFormat,
        else => return error.ZipExtractionFailed,
    };
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (iter.next() catch |err| switch (err) {
        error.ZipBadCdOffset, error.ZipBadExtraFieldSize, error.ZipBadCd64Size, error.ZipInvalid => return error.CorruptArchive,
        error.ZipMultiDiskUnsupported, error.ZipEncryptionUnsupported => return error.UnsupportedArchiveFormat,
        else => return error.ZipExtractionFailed,
    }) |entry| {
        if (entry.filename_len > filename_buf.len) return error.ZipExtractionFailed;

        // Read filename from central directory
        try file_reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const raw_name = filename_buf[0..entry.filename_len];
        try file_reader.interface.readSliceAll(raw_name);

        var eff_name = raw_name;
        if (options.strip_components > 0) {
            var comp_count: u32 = 0;
            var pos: usize = 0;
            while (pos < eff_name.len and comp_count < options.strip_components) {
                if (eff_name[pos] == '/' or eff_name[pos] == '\\') {
                    comp_count += 1;
                }
                pos += 1;
            }
            if (comp_count < options.strip_components) continue;
            eff_name = eff_name[pos..];
        }

        if (eff_name.len == 0) continue;

        const sanitized = path_validation.sanitizeArchivePath(allocator, eff_name) catch |err| switch (err) {
            error.PathTraversalDetected => return error.PathTraversalDetected,
            error.AbsolutePathsNotAllowed => return error.AbsolutePathsNotAllowed,
            error.NullByteInPath => return error.NullByteInPath,
            error.InvalidPath => continue,
            else => return error.PathTraversalDetected,
        };
        defer allocator.free(sanitized);

        if (sanitized.len == 0) continue;

        // Directory entry in ZIP
        if (raw_name[raw_name.len - 1] == '/' or raw_name[raw_name.len - 1] == '\\') {
            try dest_dir.createDirPath(io, sanitized);
            continue;
        }

        // File extraction
        if (std.fs.path.dirname(sanitized)) |parent| {
            if (parent.len > 0) {
                try dest_dir.createDirPath(io, parent);
            }
        }

        const create_opts: std.Io.Dir.CreateFileOptions = if (options.overwrite)
            .{ .truncate = true }
        else
            .{ .exclusive = true };

        var out_file = dest_dir.createFile(io, sanitized, create_opts) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (std.fs.path.dirname(sanitized)) |parent| {
                    try dest_dir.createDirPath(io, parent);
                    break :blk try dest_dir.createFile(io, sanitized, create_opts);
                }
                return err;
            },
            else => return err,
        };
        defer out_file.close(io);

        var out_buf: [16384]u8 = undefined;
        var fw = out_file.writer(io, &out_buf);

        // Decompress entry content
        try extractZipEntry(entry, &file_reader, &fw.interface);
        try fw.interface.flush();
    }
}

fn extractZipEntry(entry: std.zip.Iterator.Entry, stream: *std.Io.File.Reader, out_writer: *std.Io.Writer) !void {
    // Read local file header to find data offset
    try stream.seekTo(entry.file_offset);
    const local_header = try stream.interface.takeStruct(std.zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig)) {
        return error.CorruptArchive;
    }

    const data_offset = entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len + local_header.extra_len;
    try stream.seekTo(data_offset);

    switch (entry.compression_method) {
        .store => {
            try stream.interface.streamExact64(out_writer, entry.uncompressed_size);
        },
        .deflate => {
            var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress = std.compress.flate.Decompress.init(&stream.interface, .raw, &flate_buf);
            decompress.reader.streamExact64(out_writer, entry.uncompressed_size) catch |err| switch (err) {
                error.ReadFailed => return stream.err orelse error.CorruptArchive,
                error.WriteFailed => return error.ZipExtractionFailed,
                error.EndOfStream => return error.UnexpectedEndOfStream,
            };
        },
        else => return error.UnsupportedArchiveFormat,
    }
}

// ============================================================================
// Auto-Detect & Unpack
// ============================================================================

/// Unpack an archive file automatically based on its extension.
pub fn unpackArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    dest_path: []const u8,
    options: ExtractOptions,
) !void {
    if (std.mem.endsWith(u8, archive_path, ".tar.zst") or std.mem.endsWith(u8, archive_path, ".tzst")) {
        return extractTarZstd(allocator, io, archive_path, dest_path, options);
    } else if (std.mem.endsWith(u8, archive_path, ".tar.gz") or std.mem.endsWith(u8, archive_path, ".tgz")) {
        return extractTarGz(allocator, io, archive_path, dest_path, options);
    } else if (std.mem.endsWith(u8, archive_path, ".tar")) {
        return extractTar(allocator, io, archive_path, dest_path, options);
    } else if (std.mem.endsWith(u8, archive_path, ".zip") or std.mem.endsWith(u8, archive_path, ".rock") or std.mem.endsWith(u8, archive_path, ".src.rock")) {
        return extractZip(allocator, io, archive_path, dest_path, options);
    } else {
        return error.UnsupportedArchiveFormat;
    }
}
