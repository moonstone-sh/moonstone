const std = @import("std");
const moonstone = @import("moonstone");
const archive = moonstone.archive;

pub const TarEntryKind = enum {
    file,
    directory,
    symlink,
};

pub const TarEntry = struct {
    name: []const u8,
    content: []const u8 = "",
    kind: TarEntryKind = .file,
    link_target: []const u8 = "",
    mode: u32 = 0o644,
    mtime: u64 = 0,
};

pub const ZipEntry = struct {
    name: []const u8,
    content: []const u8 = "",
    is_dir: bool = false,
    version_made_by: u16 = 20,
    external_attributes: u32 = 0,
};

/// Create a raw 512-byte TAR header block with precise control over header fields.
pub fn createRawTarHeader(
    name: []const u8,
    size: usize,
    mode: u32,
    typeflag: u8,
    linkname: []const u8,
) [512]u8 {
    var header = [_]u8{0} ** 512;

    // name (0..100) and prefix (345..500) for USTAR format
    if (name.len <= 100) {
        @memcpy(header[0..name.len], name);
    } else {
        var split_idx: ?usize = null;
        var i: usize = name.len;
        while (i > 0) {
            i -= 1;
            if (name[i] == '/' or name[i] == '\\') {
                const prefix_candidate = name[0..i];
                const suffix_candidate = name[i + 1 ..];
                if (suffix_candidate.len <= 100 and prefix_candidate.len <= 155) {
                    split_idx = i;
                    break;
                }
            }
        }
        if (split_idx) |idx| {
            const prefix_part = name[0..idx];
            const suffix_part = name[idx + 1 ..];
            @memcpy(header[0..suffix_part.len], suffix_part);
            @memcpy(header[345..][0..prefix_part.len], prefix_part);
        } else {
            const name_len = @min(name.len, 100);
            @memcpy(header[0..name_len], name[0..name_len]);
        }
    }

    // mode: 100..108 (8 bytes: 6 octal digits + null + space)
    _ = std.fmt.bufPrint(header[100..108], "{o:0>6}\x00 ", .{mode & 0o7777}) catch {};

    // uid: 108..116
    _ = std.fmt.bufPrint(header[108..116], "{o:0>6}\x00 ", .{@as(u32, 0)}) catch {};

    // gid: 116..124
    _ = std.fmt.bufPrint(header[116..124], "{o:0>6}\x00 ", .{@as(u32, 0)}) catch {};

    // size: 124..136 (12 bytes: 11 octal digits + space)
    _ = std.fmt.bufPrint(header[124..136], "{o:0>11} ", .{size}) catch {};

    // mtime: 136..148 (12 bytes)
    _ = std.fmt.bufPrint(header[136..148], "{o:0>11} ", .{@as(u64, 0)}) catch {};

    // typeflag: 156
    header[156] = typeflag;

    // linkname: 157..257
    const link_len = @min(linkname.len, 100);
    if (link_len > 0) {
        @memcpy(header[157..][0..link_len], linkname[0..link_len]);
    }

    // magic & version: 257..265
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");

    // chksum: 148..156 (initial 8 spaces for calculation)
    @memset(header[148..156], ' ');
    var chksum: u32 = 0;
    for (header) |b| {
        chksum += b;
    }
    _ = std.fmt.bufPrint(header[148..156], "{o:0>6}\x00 ", .{chksum}) catch {};

    return header;
}

/// Create an uncompressed TAR archive in memory from a list of TarEntry items.
pub fn createTarBuffer(allocator: std.mem.Allocator, entries: []const TarEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    for (entries) |entry| {
        const typeflag: u8 = switch (entry.kind) {
            .file => '0',
            .directory => '5',
            .symlink => '2',
        };
        const content_size = if (entry.kind == .file) entry.content.len else 0;
        const header = createRawTarHeader(entry.name, content_size, entry.mode, typeflag, entry.link_target);
        try out.appendSlice(allocator, &header);

        if (entry.kind == .file and entry.content.len > 0) {
            try out.appendSlice(allocator, entry.content);
            const remainder = entry.content.len % 512;
            if (remainder != 0) {
                const pad_len = 512 - remainder;
                const zeroes = [_]u8{0} ** 512;
                try out.appendSlice(allocator, zeroes[0..pad_len]);
            }
        }
    }

    // Two 512-byte end-of-archive marker blocks
    const eof_blocks = [_]u8{0} ** 1024;
    try out.appendSlice(allocator, &eof_blocks);

    return try out.toOwnedSlice(allocator);
}

/// Write a TAR archive to a file.
pub fn writeTarFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: []const TarEntry) !void {
    const tar_bytes = try createTarBuffer(allocator, entries);
    defer allocator.free(tar_bytes);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [32768]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(tar_bytes);
    try writer.interface.flush();
}

/// Write a `.tar.gz` archive to a file.
pub fn writeTarGzFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: []const TarEntry) !void {
    const tar_bytes = try createTarBuffer(allocator, entries);
    defer allocator.free(tar_bytes);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var file_buf: [32768]u8 = undefined;
    var file_writer = file.writer(io, &file_buf);

    var flate_comp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&file_writer.interface, &flate_comp_buf, .gzip, .default);

    try compressor.writer.writeAll(tar_bytes);
    try compressor.finish();
    try file_writer.interface.flush();
}

/// Write a `.tar.zst` archive to a file.
pub fn writeTarZstdFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: []const TarEntry) !void {
    const tar_bytes = try createTarBuffer(allocator, entries);
    defer allocator.free(tar_bytes);

    const zst_bytes = try archive.native.compressZstdBytes(allocator, tar_bytes);
    defer allocator.free(zst_bytes);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [32768]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(zst_bytes);
    try writer.interface.flush();
}

/// Create a valid ZIP archive in memory with STORE (uncompressed) entries.
pub fn createZipBuffer(allocator: std.mem.Allocator, entries: []const ZipEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var cd_entries = std.ArrayList(u8).empty;
    defer cd_entries.deinit(allocator);

    var local_offsets = std.ArrayList(u32).empty;
    defer local_offsets.deinit(allocator);

    for (entries) |entry| {
        const offset: u32 = @intCast(out.items.len);
        try local_offsets.append(allocator, offset);

        const crc = std.hash.Crc32.hash(entry.content);
        const comp_size: u32 = @intCast(entry.content.len);
        const uncomp_size: u32 = @intCast(entry.content.len);
        const name_len: u16 = @intCast(entry.name.len);

        // Local file header: 30 bytes
        var lfh: [30]u8 = undefined;
        @memcpy(lfh[0..4], &std.zip.local_file_header_sig);
        std.mem.writeInt(u16, lfh[4..6], 20, .little); // version needed
        std.mem.writeInt(u16, lfh[6..8], 0, .little); // flags
        std.mem.writeInt(u16, lfh[8..10], 0, .little); // compression method (0 = store)
        std.mem.writeInt(u16, lfh[10..12], 0, .little); // mod time
        std.mem.writeInt(u16, lfh[12..14], 0, .little); // mod date
        std.mem.writeInt(u32, lfh[14..18], crc, .little); // crc32
        std.mem.writeInt(u32, lfh[18..22], comp_size, .little); // compressed size
        std.mem.writeInt(u32, lfh[22..26], uncomp_size, .little); // uncompressed size
        std.mem.writeInt(u16, lfh[26..28], name_len, .little); // filename len
        std.mem.writeInt(u16, lfh[28..30], 0, .little); // extra field len

        try out.appendSlice(allocator, &lfh);
        try out.appendSlice(allocator, entry.name);
        try out.appendSlice(allocator, entry.content);

        // Central directory header: 46 bytes
        var cdh: [46]u8 = undefined;
        @memcpy(cdh[0..4], &std.zip.central_file_header_sig);
        std.mem.writeInt(u16, cdh[4..6], entry.version_made_by, .little); // version made by
        std.mem.writeInt(u16, cdh[6..8], 20, .little); // version needed
        std.mem.writeInt(u16, cdh[8..10], 0, .little); // flags
        std.mem.writeInt(u16, cdh[10..12], 0, .little); // compression method (0 = store)
        std.mem.writeInt(u16, cdh[12..14], 0, .little); // mod time
        std.mem.writeInt(u16, cdh[14..16], 0, .little); // mod date
        std.mem.writeInt(u32, cdh[16..20], crc, .little); // crc32
        std.mem.writeInt(u32, cdh[20..24], comp_size, .little); // compressed size
        std.mem.writeInt(u32, cdh[24..28], uncomp_size, .little); // uncompressed size
        std.mem.writeInt(u16, cdh[28..30], name_len, .little); // filename len
        std.mem.writeInt(u16, cdh[30..32], 0, .little); // extra field len
        std.mem.writeInt(u16, cdh[32..34], 0, .little); // comment len
        std.mem.writeInt(u16, cdh[34..36], 0, .little); // disk number
        std.mem.writeInt(u16, cdh[36..38], 0, .little); // internal attrs
        std.mem.writeInt(u32, cdh[38..42], entry.external_attributes, .little); // external attrs
        std.mem.writeInt(u32, cdh[42..46], offset, .little); // local header offset

        try cd_entries.appendSlice(allocator, &cdh);
        try cd_entries.appendSlice(allocator, entry.name);
    }

    const cd_offset: u32 = @intCast(out.items.len);
    const cd_size: u32 = @intCast(cd_entries.items.len);
    const count: u16 = @intCast(entries.len);

    try out.appendSlice(allocator, cd_entries.items);

    // End of central directory record: 22 bytes
    var eocd: [22]u8 = undefined;
    @memcpy(eocd[0..4], &std.zip.end_record_sig);
    std.mem.writeInt(u16, eocd[4..6], 0, .little); // disk number
    std.mem.writeInt(u16, eocd[6..8], 0, .little); // cd disk number
    std.mem.writeInt(u16, eocd[8..10], count, .little); // entries this disk
    std.mem.writeInt(u16, eocd[10..12], count, .little); // entries total
    std.mem.writeInt(u32, eocd[12..16], cd_size, .little); // cd size
    std.mem.writeInt(u32, eocd[16..20], cd_offset, .little); // cd offset
    std.mem.writeInt(u16, eocd[20..22], 0, .little); // comment len

    try out.appendSlice(allocator, &eocd);

    return try out.toOwnedSlice(allocator);
}

/// Write a `.zip` archive to a file.
pub fn writeZipFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: []const ZipEntry) !void {
    const zip_bytes = try createZipBuffer(allocator, entries);
    defer allocator.free(zip_bytes);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buf: [32768]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(zip_bytes);
    try writer.interface.flush();
}
