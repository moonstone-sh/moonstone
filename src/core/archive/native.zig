const std = @import("std");
const builtin = @import("builtin");
const path_validation = @import("path_validation.zig");
const permissions = @import("permissions.zig");
const platform_fs = @import("../platform/fs.zig");

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
    ArchivePermissionRestoreFailed,
} || std.mem.Allocator.Error || std.Io.Dir.OpenError || std.Io.Dir.CreateFileError || std.Io.File.ReadError || std.Io.File.WriteError;

const PendingArchiveSymlink = struct {
    entry_path: []const u8,
    target: []const u8,

    fn deinit(self: PendingArchiveSymlink, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.target);
    }
};

fn queueArchiveSymlink(
    allocator: std.mem.Allocator,
    pending_symlinks: *std.ArrayList(PendingArchiveSymlink),
    entry_path: []const u8,
    target: []const u8,
) !void {
    const owned_entry_path = try allocator.dupe(u8, entry_path);
    errdefer allocator.free(owned_entry_path);
    const owned_target = try allocator.dupe(u8, target);
    errdefer allocator.free(owned_target);
    try pending_symlinks.append(allocator, .{
        .entry_path = owned_entry_path,
        .target = owned_target,
    });
}

/// Archive symlinks are intentionally created only after every regular entry.
/// Windows needs the directory flag at creation time, while a missing target is
/// a valid dangling file link. Deferral makes a forward-referenced directory
/// observable without changing relative link targets or copying their data.
fn materializeArchiveSymlinks(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination_dir: std.Io.Dir,
    destination_root: []const u8,
    pending_symlinks: []const PendingArchiveSymlink,
) !void {
    for (pending_symlinks) |pending| {
        // Each target was validated before it was queued. Create implicit
        // parents before classifying: a link to its own parent (`.`) is a
        // directory symlink even when that parent was otherwise absent.
        if (std.fs.path.dirname(pending.entry_path)) |parent| {
            if (parent.len > 0) try destination_dir.createDirPath(io, parent);
        }

        const target_is_directory = if (comptime builtin.os.tag == .windows)
            try archiveSymlinkTargetIsDirectory(
                allocator,
                io,
                destination_dir,
                pending.target,
                pending.entry_path,
            )
        else
            false;

        destination_dir.deleteFile(io, pending.entry_path) catch {};
        try platform_fs.createArchiveSymlink(
            allocator,
            io,
            destination_dir,
            destination_root,
            pending.target,
            pending.entry_path,
            target_is_directory,
        );
    }
}

/// Classify an already-validated target after regular archive entries have
/// been extracted. Backslashes are archive path separators for Windows target
/// semantics, so normalize only for the local lookup; the created target stays
/// byte-for-byte relative apart from the Win32 representation conversion.
fn archiveSymlinkTargetIsDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination_dir: std.Io.Dir,
    target: []const u8,
    entry_path: []const u8,
) !bool {
    const normalized_target = try allocator.dupe(u8, target);
    defer allocator.free(normalized_target);
    std.mem.replaceScalar(u8, normalized_target, '\\', '/');

    const parent = std.fs.path.dirname(entry_path) orelse ".";
    const target_path = try std.fs.path.resolve(allocator, &.{ parent, normalized_target });
    defer allocator.free(target_path);

    var target_dir = destination_dir.openDir(io, target_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    target_dir.close(io);
    return true;
}

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
    const dest_path = try dest_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dest_path);

    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    var pending_dirs = std.ArrayList(permissions.PendingDirPermission).empty;
    defer {
        for (pending_dirs.items) |p| allocator.free(p.path);
        pending_dirs.deinit(allocator);
    }

    var pending_symlinks = std.ArrayList(PendingArchiveSymlink).empty;
    defer {
        for (pending_symlinks.items) |pending| pending.deinit(allocator);
        pending_symlinks.deinit(allocator);
    }

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
                const sanitized_mode = permissions.sanitizeArchivedMode(.directory, file.mode);
                try pending_dirs.append(allocator, .{
                    .path = try allocator.dupe(u8, sanitized_rel_path),
                    .mode = sanitized_mode.mode,
                });
            },
            .file => {
                if (std.fs.path.dirname(sanitized_rel_path)) |parent| {
                    if (parent.len > 0) {
                        try dest_dir.createDirPath(io, parent);
                    }
                }

                const sanitized_mode = permissions.sanitizeArchivedMode(.file, file.mode);

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

                // Apply sanitized permissions through open file handle
                try permissions.applyFilePermissions(io, out_file, sanitized_mode.mode);
            },
            .sym_link => {
                if (!options.allow_symlinks) return error.SymlinkTargetEscapesDestination;

                try path_validation.validateSymlinkTarget(file.link_name, sanitized_rel_path);
                try queueArchiveSymlink(allocator, &pending_symlinks, sanitized_rel_path, file.link_name);
            },
        }
    }

    try materializeArchiveSymlinks(allocator, io, dest_dir, dest_path, pending_symlinks.items);

    // Deferred/post-order directory permission restoration (deepest-first)
    if (pending_dirs.items.len > 0) {
        std.mem.sort(permissions.PendingDirPermission, pending_dirs.items, {}, permissions.comparePendingDirsDeepestFirst);
        for (pending_dirs.items) |pending| {
            try permissions.applyDirPermissions(io, dest_dir, pending.path, pending.mode);
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
                var dir_mode: u32 = permissions.DEFAULT_DIR_MODE;
                var sub_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub_dir.close(io);

                if (comptime permissions.supports_posix_permissions) {
                    if (sub_dir.stat(io) catch null) |st| {
                        const raw_mode: u32 = @intCast(st.permissions.toMode());
                        const sanitized = permissions.sanitizeArchivedMode(.directory, raw_mode);
                        dir_mode = sanitized.mode;
                    }
                }

                try tar_writer.writeDir(rel_path, .{ .mode = dir_mode });
                try writeDirectoryRecursive(allocator, io, sub_dir, rel_path, tar_writer);
            },
            .file => {
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);

                const size = try f.length(io);
                const content = try dir.readFileAlloc(io, entry.name, allocator, std.Io.Limit.limited(size + 1024));
                defer allocator.free(content);

                var file_mode: u32 = permissions.DEFAULT_FILE_MODE;
                if (comptime permissions.supports_posix_permissions) {
                    if (f.stat(io) catch null) |st| {
                        const raw_mode: u32 = @intCast(st.permissions.toMode());
                        const sanitized = permissions.sanitizeArchivedMode(.file, raw_mode);
                        file_mode = sanitized.mode;
                    }
                }

                try tar_writer.writeFileBytes(rel_path, content, .{ .mode = file_mode });
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

    const dest_real_path = try dest_dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dest_real_path);

    var file_buf: [32768]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var iter = std.zip.Iterator.init(&file_reader) catch |err| switch (err) {
        error.ZipNoEndRecord, error.ZipTruncated, error.ZipBadLocatorSig, error.ZipBadEndRecord64Sig, error.ZipEndRecord64SizeTooSmall, error.ZipEndRecord64UnhandledExtraData, error.ZipDiskRecordCountTooLarge, error.Zip64RecordCountTotalMismatch, error.Zip64CentralDirectoryOffsetMismatch => return error.CorruptArchive,
        error.ZipMultiDiskUnsupported, error.ZipUnsupportedZip64DiskCount, error.ZipUnsupportedVersion => return error.UnsupportedArchiveFormat,
        else => return error.ZipExtractionFailed,
    };
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var pending_dirs = std.ArrayList(permissions.PendingDirPermission).empty;
    defer {
        for (pending_dirs.items) |p| allocator.free(p.path);
        pending_dirs.deinit(allocator);
    }

    var pending_symlinks = std.ArrayList(PendingArchiveSymlink).empty;
    defer {
        for (pending_symlinks.items) |pending| pending.deinit(allocator);
        pending_symlinks.deinit(allocator);
    }

    while (iter.next() catch |err| switch (err) {
        error.ZipBadCdOffset, error.ZipBadExtraFieldSize, error.ZipBadCd64Size, error.ZipInvalid => return error.CorruptArchive,
        error.ZipMultiDiskUnsupported, error.ZipEncryptionUnsupported => return error.UnsupportedArchiveFormat,
        else => return error.ZipExtractionFailed,
    }) |entry| {
        if (entry.filename_len > filename_buf.len) return error.ZipExtractionFailed;

        // Read Central Directory header to extract metadata & filename
        try file_reader.seekTo(entry.header_zip_offset);
        const cd_header = file_reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little) catch |err| switch (err) {
            error.ReadFailed => return error.CorruptArchive,
            error.EndOfStream => return error.UnexpectedEndOfStream,
        };

        const raw_name = filename_buf[0..entry.filename_len];
        try file_reader.interface.readSliceAll(raw_name);

        // Parse POSIX mode from Central Directory header if creator host is UNIX (3)
        const host_system = cd_header.version_made_by >> 8;
        const raw_posix_mode: ?u32 = if (host_system == 3)
            (cd_header.external_file_attributes >> 16)
        else
            null;

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

        const file_type = if (raw_posix_mode) |m| (m & 0o170000) else 0;
        const is_symlink_entry = (file_type == 0o120000);
        const is_dir_entry = (raw_name[raw_name.len - 1] == '/' or raw_name[raw_name.len - 1] == '\\') or
            (file_type == 0o040000);

        // Reject dangerous/special files (block/char devices, FIFOs, sockets)
        if (file_type != 0 and file_type != 0o100000 and file_type != 0o040000 and file_type != 0o120000) {
            return error.UnsupportedArchiveFormat;
        }

        // Symlink entry in ZIP (UNIX S_IFLNK)
        if (is_symlink_entry) {
            if (!options.allow_symlinks) return error.SymlinkTargetEscapesDestination;

            var target_writer = std.Io.Writer.Allocating.init(allocator);
            defer target_writer.deinit();

            try extractZipEntry(entry, &file_reader, &target_writer.writer);
            const target_link = try target_writer.toOwnedSlice();
            defer allocator.free(target_link);

            try path_validation.validateSymlinkTarget(target_link, sanitized);
            try queueArchiveSymlink(allocator, &pending_symlinks, sanitized, target_link);
            continue;
        }

        // Directory entry in ZIP
        if (is_dir_entry) {
            try dest_dir.createDirPath(io, sanitized);
            const sanitized_mode = permissions.sanitizeArchivedMode(.directory, raw_posix_mode);
            try pending_dirs.append(allocator, .{
                .path = try allocator.dupe(u8, sanitized),
                .mode = sanitized_mode.mode,
            });
            continue;
        }

        // File extraction
        if (std.fs.path.dirname(sanitized)) |parent| {
            if (parent.len > 0) {
                try dest_dir.createDirPath(io, parent);
            }
        }

        const sanitized_mode = permissions.sanitizeArchivedMode(.file, raw_posix_mode);

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

        // Apply sanitized permissions through open file handle
        try permissions.applyFilePermissions(io, out_file, sanitized_mode.mode);
    }

    try materializeArchiveSymlinks(allocator, io, dest_dir, dest_real_path, pending_symlinks.items);

    // Deferred/post-order directory permission restoration (deepest-first)
    if (pending_dirs.items.len > 0) {
        std.mem.sort(permissions.PendingDirPermission, pending_dirs.items, {}, permissions.comparePendingDirsDeepestFirst);
        for (pending_dirs.items) |pending| {
            try permissions.applyDirPermissions(io, dest_dir, pending.path, pending.mode);
        }
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
