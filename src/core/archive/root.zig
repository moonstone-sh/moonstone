const std = @import("std");
const build_options = @import("build_options");

pub const BackendKind = enum {
    native,
    system,
};

pub const backend: BackendKind = if (@hasDecl(build_options, "archive_backend"))
    switch (build_options.archive_backend) {
        .native => .native,
        .system => .system,
    }
else
    .native;

pub const native = @import("native.zig");
pub const system = @import("system.zig");
pub const path_validation = @import("path_validation.zig");
pub const permissions = @import("permissions.zig");

pub const ExtractOptions = native.ExtractOptions;
pub const ArchiveError = native.ArchiveError;

// ============================================================================
// Public Backend-Neutral API
// ============================================================================

pub fn decompressZstdFile(allocator: std.mem.Allocator, io: std.Io, zst_path: []const u8, out_path: []const u8) !void {
    return switch (backend) {
        .native => native.decompressZstdFile(allocator, io, zst_path, out_path),
        .system => system.decompressZstdFile(allocator, io, zst_path, out_path),
    };
}

pub fn compressZstdFile(allocator: std.mem.Allocator, io: std.Io, in_path: []const u8, out_path: []const u8) !void {
    return switch (backend) {
        .native => native.compressZstdFile(allocator, io, in_path, out_path),
        .system => system.compressZstdFile(allocator, io, in_path, out_path),
    };
}

pub fn decompressZstdBytes(allocator: std.mem.Allocator, compressed_bytes: []const u8) ![]u8 {
    return switch (backend) {
        .native => native.decompressZstdBytes(allocator, compressed_bytes),
        .system => system.decompressZstdBytes(allocator, compressed_bytes),
    };
}

pub fn compressZstdBytes(allocator: std.mem.Allocator, uncompressed_bytes: []const u8) ![]u8 {
    return switch (backend) {
        .native => native.compressZstdBytes(allocator, uncompressed_bytes),
        .system => system.compressZstdBytes(allocator, uncompressed_bytes),
    };
}

pub fn extractTar(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    return switch (backend) {
        .native => native.extractTar(allocator, io, archive_path, dest_path, options),
        .system => system.extractTar(allocator, io, archive_path, dest_path, options),
    };
}

pub fn extractTarGz(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    return switch (backend) {
        .native => native.extractTarGz(allocator, io, archive_path, dest_path, options),
        .system => system.extractTarGz(allocator, io, archive_path, dest_path, options),
    };
}

pub fn extractTarZstd(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    return switch (backend) {
        .native => native.extractTarZstd(allocator, io, archive_path, dest_path, options),
        .system => system.extractTarZstd(allocator, io, archive_path, dest_path, options),
    };
}

pub fn createTarGz(allocator: std.mem.Allocator, io: std.Io, src_dir_path: []const u8, out_tar_gz_path: []const u8) !void {
    return switch (backend) {
        .native => native.createTarGz(allocator, io, src_dir_path, out_tar_gz_path),
        .system => system.createTarGz(allocator, io, src_dir_path, out_tar_gz_path),
    };
}

pub fn extractZip(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    return switch (backend) {
        .native => native.extractZip(allocator, io, archive_path, dest_path, options),
        .system => system.extractZip(allocator, io, archive_path, dest_path, options),
    };
}

pub fn unpackArchive(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, dest_path: []const u8, options: ExtractOptions) !void {
    return switch (backend) {
        .native => native.unpackArchive(allocator, io, archive_path, dest_path, options),
        .system => system.unpackArchive(allocator, io, archive_path, dest_path, options),
    };
}
