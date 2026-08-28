const std = @import("std");
const moonstone = @import("moonstone");
const archive = moonstone.archive;
const system_tools = moonstone.system_tools;
const helpers = @import("test_archive_helpers.zig");

test "Differential: Plain .tar extraction native vs system" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    // Check if system 'tar' is available
    const tar_exe = try system_tools.findExecutable(allocator, io_val, "tar");
    if (tar_exe) |exe| {
        defer allocator.free(exe);
    } else {
        // System tar not available on host, skip differential assertion
        return;
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "diff_test.tar" });
    defer allocator.free(tar_path);

    var binary_data: [256]u8 = undefined;
    for (&binary_data, 0..) |*b, idx| {
        b.* = @truncate(idx);
    }

    const entries = [_]helpers.TarEntry{
        .{ .name = "root_file.txt", .content = "Root text content differential" },
        .{ .name = "empty_file.dat", .content = "" },
        .{ .name = "nested/dir1/deep.lua", .content = "return { version = '1.0' }" },
        .{ .name = "nested/dir2/binary.bin", .content = &binary_data },
    };

    try helpers.writeTarFile(allocator, io_val, tar_path, &entries);

    // 1. Native extract
    const dest_native = try std.fs.path.join(allocator, &.{ tmp_path, "dest_native" });
    defer allocator.free(dest_native);
    try archive.native.extractTar(allocator, io_val, tar_path, dest_native, .{});

    // 2. System extract
    const dest_system = try std.fs.path.join(allocator, &.{ tmp_path, "dest_system" });
    defer allocator.free(dest_system);
    try archive.system.extractTar(allocator, io_val, tar_path, dest_system, .{});

    // 3. Compute canonical BLAKE3 tree hashes of both output directories
    var dir_native = try std.Io.Dir.cwd().openDir(io_val, dest_native, .{ .iterate = true });
    defer dir_native.close(io_val);
    const hash_native = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_native);
    defer allocator.free(hash_native);

    var dir_system = try std.Io.Dir.cwd().openDir(io_val, dest_system, .{ .iterate = true });
    defer dir_system.close(io_val);
    const hash_system = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_system);
    defer allocator.free(hash_system);

    // Assert bit-for-bit identical fingerprints
    try std.testing.expectEqualStrings(hash_native, hash_system);
}

test "Differential: .tar.gz extraction native vs system" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tar_exe = try system_tools.findExecutable(allocator, io_val, "tar");
    if (tar_exe) |exe| {
        defer allocator.free(exe);
    } else {
        return;
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const targz_path = try std.fs.path.join(allocator, &.{ tmp_path, "diff_test.tar.gz" });
    defer allocator.free(targz_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "main.lua", .content = "print('Hello world!')\n" },
        .{ .name = "lib/math/vector.lua", .content = "local Vector = {}\nreturn Vector\n" },
        .{ .name = "assets/config.json", .content = "{\"debug\": true, \"port\": 8080}" },
    };

    try helpers.writeTarGzFile(allocator, io_val, targz_path, &entries);

    // 1. Native extract
    const dest_native = try std.fs.path.join(allocator, &.{ tmp_path, "dest_gz_native" });
    defer allocator.free(dest_native);
    try archive.native.extractTarGz(allocator, io_val, targz_path, dest_native, .{});

    // 2. System extract
    const dest_system = try std.fs.path.join(allocator, &.{ tmp_path, "dest_gz_system" });
    defer allocator.free(dest_system);
    try archive.system.extractTarGz(allocator, io_val, targz_path, dest_system, .{});

    // 3. Compare fingerprints
    var dir_native = try std.Io.Dir.cwd().openDir(io_val, dest_native, .{ .iterate = true });
    defer dir_native.close(io_val);
    const hash_native = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_native);
    defer allocator.free(hash_native);

    var dir_system = try std.Io.Dir.cwd().openDir(io_val, dest_system, .{ .iterate = true });
    defer dir_system.close(io_val);
    const hash_system = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_system);
    defer allocator.free(hash_system);

    try std.testing.expectEqualStrings(hash_native, hash_system);
}

test "Differential: .tar.gz with strip_components = 1 native vs system" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tar_exe = try system_tools.findExecutable(allocator, io_val, "tar");
    if (tar_exe) |exe| {
        defer allocator.free(exe);
    } else {
        return;
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const targz_path = try std.fs.path.join(allocator, &.{ tmp_path, "strip_diff.tar.gz" });
    defer allocator.free(targz_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "package-1.0.0/file1.txt", .content = "First file" },
        .{ .name = "package-1.0.0/nested/file2.txt", .content = "Second nested file" },
    };

    try helpers.writeTarGzFile(allocator, io_val, targz_path, &entries);

    // 1. Native extract
    const dest_native = try std.fs.path.join(allocator, &.{ tmp_path, "dest_strip_native" });
    defer allocator.free(dest_native);
    try archive.native.extractTarGz(allocator, io_val, targz_path, dest_native, .{ .strip_components = 1 });

    // 2. System extract
    const dest_system = try std.fs.path.join(allocator, &.{ tmp_path, "dest_strip_system" });
    defer allocator.free(dest_system);
    try archive.system.extractTarGz(allocator, io_val, targz_path, dest_system, .{ .strip_components = 1 });

    // 3. Compare fingerprints
    var dir_native = try std.Io.Dir.cwd().openDir(io_val, dest_native, .{ .iterate = true });
    defer dir_native.close(io_val);
    const hash_native = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_native);
    defer allocator.free(hash_native);

    var dir_system = try std.Io.Dir.cwd().openDir(io_val, dest_system, .{ .iterate = true });
    defer dir_system.close(io_val);
    const hash_system = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_system);
    defer allocator.free(hash_system);

    try std.testing.expectEqualStrings(hash_native, hash_system);
}

test "Differential: .zip extraction native vs system (unzip)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const unzip_exe = try system_tools.findExecutable(allocator, io_val, "unzip");
    if (unzip_exe) |exe| {
        defer allocator.free(exe);
    } else {
        return;
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "diff_test.zip" });
    defer allocator.free(zip_path);

    const entries = [_]helpers.ZipEntry{
        .{ .name = "info.txt", .content = "ZIP information content" },
        .{ .name = "sub/code.lua", .content = "return 'zip diff test'" },
    };

    try helpers.writeZipFile(allocator, io_val, zip_path, &entries);

    // 1. Native extract
    const dest_native = try std.fs.path.join(allocator, &.{ tmp_path, "dest_zip_native" });
    defer allocator.free(dest_native);
    try archive.native.extractZip(allocator, io_val, zip_path, dest_native, .{});

    // 2. System extract
    const dest_system = try std.fs.path.join(allocator, &.{ tmp_path, "dest_zip_system" });
    defer allocator.free(dest_system);
    try archive.system.extractZip(allocator, io_val, zip_path, dest_system, .{});

    // 3. Compare fingerprints
    var dir_native = try std.Io.Dir.cwd().openDir(io_val, dest_native, .{ .iterate = true });
    defer dir_native.close(io_val);
    const hash_native = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_native);
    defer allocator.free(hash_native);

    var dir_system = try std.Io.Dir.cwd().openDir(io_val, dest_system, .{ .iterate = true });
    defer dir_system.close(io_val);
    const hash_system = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_system);
    defer allocator.free(hash_system);

    try std.testing.expectEqualStrings(hash_native, hash_system);
}

test "Differential: Zstd file compression/decompression native vs system" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const zstd_exe = try system_tools.findExecutable(allocator, io_val, "zstd");
    if (zstd_exe) |exe| {
        defer allocator.free(exe);
    } else {
        return;
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const raw_content = "Zstandard differential testing payload with repeated patterns: 12345 67890 ABCDEF 12345 67890";
    const src_file = try std.fs.path.join(allocator, &.{ tmp_path, "input.txt" });
    defer allocator.free(src_file);
    try tmp.dir.writeFile(io_val, .{ .sub_path = "input.txt", .data = raw_content });

    const zst_file = try std.fs.path.join(allocator, &.{ tmp_path, "compressed.zst" });
    defer allocator.free(zst_file);

    // Compress natively
    try archive.native.compressZstdFile(allocator, io_val, src_file, zst_file);

    // Decompress with native
    const out_native = try std.fs.path.join(allocator, &.{ tmp_path, "out_native.txt" });
    defer allocator.free(out_native);
    try archive.native.decompressZstdFile(allocator, io_val, zst_file, out_native);

    // Decompress with system zstd
    const out_system = try std.fs.path.join(allocator, &.{ tmp_path, "out_system.txt" });
    defer allocator.free(out_system);
    try archive.system.decompressZstdFile(allocator, io_val, zst_file, out_system);

    // Read both and compare
    const read_native = try tmp.dir.readFileAlloc(io_val, "out_native.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(read_native);

    const read_system = try tmp.dir.readFileAlloc(io_val, "out_system.txt", allocator, std.Io.Limit.limited(1024));
    defer allocator.free(read_system);

    try std.testing.expectEqualStrings(raw_content, read_native);
    try std.testing.expectEqualStrings(raw_content, read_system);
    try std.testing.expectEqualStrings(read_native, read_system);
}

test "Differential: Permission-aware tree comparison native vs system" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tar_exe = try system_tools.findExecutable(allocator, io_val, "tar");
    if (tar_exe) |exe| {
        defer allocator.free(exe);
    } else {
        return;
    }

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const tar_gz_path = try std.fs.path.join(allocator, &.{ tmp_path, "perm_diff.tar.gz" });
    defer allocator.free(tar_gz_path);

    const entries = [_]helpers.TarEntry{
        .{ .name = "bin/launcher.sh", .content = "#!/bin/sh\necho launch\n", .mode = 0o755 },
        .{ .name = "scripts/helper", .content = "#!/bin/sh\necho help\n", .mode = 0o755 },
        .{ .name = "lib/mod.lua", .content = "return {}\n", .mode = 0o644 },
        .{ .name = "config/settings.json", .content = "{}\n", .mode = 0o644 },
    };

    try helpers.writeTarGzFile(allocator, io_val, tar_gz_path, &entries);

    // 1. Native extract
    const dest_native = try std.fs.path.join(allocator, &.{ tmp_path, "dest_perm_native" });
    defer allocator.free(dest_native);
    try archive.native.extractTarGz(allocator, io_val, tar_gz_path, dest_native, .{});

    // 2. System extract
    const dest_system = try std.fs.path.join(allocator, &.{ tmp_path, "dest_perm_system" });
    defer allocator.free(dest_system);
    try archive.system.extractTarGz(allocator, io_val, tar_gz_path, dest_system, .{});

    // 3. Compare file contents hash
    var dir_native = try std.Io.Dir.cwd().openDir(io_val, dest_native, .{ .iterate = true });
    defer dir_native.close(io_val);
    const hash_native = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_native);
    defer allocator.free(hash_native);

    var dir_system = try std.Io.Dir.cwd().openDir(io_val, dest_system, .{ .iterate = true });
    defer dir_system.close(io_val);
    const hash_system = try moonstone.identity.hash.artifact_hash(allocator, io_val, dir_system);
    defer allocator.free(hash_system);

    try std.testing.expectEqualStrings(hash_native, hash_system);

    // 4. Compare exact permission bits across the tree on POSIX
    if (comptime @import("builtin").os.tag != .windows and @import("builtin").os.tag != .wasi) {
        const test_rel_paths = [_][]const u8{
            "bin/launcher.sh",
            "scripts/helper",
            "lib/mod.lua",
            "config/settings.json",
        };

        for (test_rel_paths) |rel| {
            var f_nat = try dir_native.openFile(io_val, rel, .{});
            defer f_nat.close(io_val);
            const st_nat = try f_nat.stat(io_val);

            var f_sys = try dir_system.openFile(io_val, rel, .{});
            defer f_sys.close(io_val);
            const st_sys = try f_sys.stat(io_val);

            const mode_nat = st_nat.permissions.toMode() & 0o777;
            const mode_sys = st_sys.permissions.toMode() & 0o777;

            try std.testing.expectEqual(mode_sys, mode_nat);
        }
    }
}

