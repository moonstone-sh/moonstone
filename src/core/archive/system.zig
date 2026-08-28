const std = @import("std");
const system_tools = @import("../system_tools/root.zig");
const native = @import("native.zig");

pub const ExtractOptions = native.ExtractOptions;

pub fn decompressZstdFile(allocator: std.mem.Allocator, io: std.Io, zst_path: []const u8, out_path: []const u8) !void {
    errdefer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var res = system_tools.zstd.decompress(allocator, io, zst_path, out_path) catch {
        return error.ZstdDecompressionFailed;
    };
    defer res.deinit(allocator);

    if (res.term != .exited or res.term.exited != 0) {
        return error.ZstdDecompressionFailed;
    }
}

pub fn compressZstdFile(allocator: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !void {
    errdefer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    var res = system_tools.zstd.compress(allocator, io, in_path, out_path) catch {
        return error.ZstdCompressionFailed;
    };
    defer res.deinit(allocator);

    if (res.term != .exited or res.term.exited != 0) {
        return error.ZstdCompressionFailed;
    }
}

pub fn decompressZstdBytes(allocator: std.mem.Allocator, compressed_bytes: []const u8) ![]u8 {
    return native.decompressZstdBytes(allocator, compressed_bytes);
}

pub fn compressZstdBytes(allocator: std.mem.Allocator, uncompressed_bytes: []const u8) ![]u8 {
    return native.compressZstdBytes(allocator, uncompressed_bytes);
}

pub fn extractTar(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_path);

    var res = system_tools.tar.extract(allocator, io, archive_path, dest_path, options.strip_components) catch {
        return error.TarExtractionFailed;
    };
    defer res.deinit(allocator);

    if (res.term != .exited or res.term.exited != 0) {
        return error.TarExtractionFailed;
    }
}

pub fn extractTarGz(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_path);

    var res = system_tools.tar.extractGz(allocator, io, archive_path, dest_path, options.strip_components) catch {
        return error.TarExtractionFailed;
    };
    defer res.deinit(allocator);

    if (res.term != .exited or res.term.exited != 0) {
        // Fallback: modern GNU/BSD tar auto-detects compression without -z
        var fallback_res = system_tools.tar.extract(allocator, io, archive_path, dest_path, options.strip_components) catch {
            return error.TarExtractionFailed;
        };
        defer fallback_res.deinit(allocator);

        if (fallback_res.term != .exited or fallback_res.term.exited != 0) {
            return error.TarExtractionFailed;
        }
    }
}

pub fn extractTarZstd(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_path);

    var res = system_tools.tar.extractZstd(allocator, io, archive_path, dest_path, options.strip_components) catch {
        return error.TarExtractionFailed;
    };
    defer res.deinit(allocator);

    if (res.term != .exited or res.term.exited != 0) {
        return error.TarExtractionFailed;
    }
}

pub fn createTarGz(allocator: std.mem.Allocator, io: std.Io, src_dir_path: []const u8, out_tar_gz_path: []const u8) !void {
    errdefer std.Io.Dir.cwd().deleteFile(io, out_tar_gz_path) catch {};

    var res = system_tools.tar.createGz(allocator, io, src_dir_path, out_tar_gz_path) catch {
        return error.TarCreationFailed;
    };
    defer res.deinit(allocator);

    if (res.term != .exited or res.term.exited != 0) {
        return error.TarCreationFailed;
    }
}

pub fn extractZip(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    if (options.strip_components > 0) return error.UnsupportedZipStripComponents;

    try std.Io.Dir.cwd().createDirPath(io, dest_path);

    var res = system_tools.unzip.extract(allocator, io, archive_path, dest_path) catch {
        return error.ZipExtractionFailed;
    };
    defer res.deinit(allocator);

    // Info-ZIP unzip returns 0 for success and 1 for warnings (e.g. empty zipfile)
    if (res.term != .exited or (res.term.exited != 0 and res.term.exited != 1)) {
        return error.ZipExtractionFailed;
    }
}

pub fn unpackArchive(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
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
