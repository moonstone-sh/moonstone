const std = @import("std");
const moonstone = @import("moonstone");
const path_validation = moonstone.archive.path_validation;
const archive = moonstone.archive;
const helpers = @import("test_archive_helpers.zig");

test "Path validation: Rejects Zip-Slip path traversal" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.PathTraversalDetected, path_validation.sanitizeArchivePath(allocator, "../../../etc/passwd"));
    try std.testing.expectError(error.PathTraversalDetected, path_validation.sanitizeArchivePath(allocator, "a/b/../../../../shadow"));
    try std.testing.expectError(error.PathTraversalDetected, path_validation.sanitizeArchivePath(allocator, ".."));
    try std.testing.expectError(error.PathTraversalDetected, path_validation.sanitizeArchivePath(allocator, "dir/../.."));
    try std.testing.expectError(error.PathTraversalDetected, path_validation.sanitizeArchivePath(allocator, "foo/bar/../../../root.sh"));
}

test "Path validation: Rejects absolute and drive paths" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "/etc/passwd"));
    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "/tmp/pwn"));
    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "\\Windows\\System32"));
    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "C:\\autoexec.bat"));
    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "D:foo.txt"));
    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "\\\\server\\share\\evil"));
    try std.testing.expectError(error.AbsolutePathsNotAllowed, path_validation.sanitizeArchivePath(allocator, "//network/share/evil"));
}

test "Path validation: Rejects null bytes in path" {
    const allocator = std.testing.allocator;

    const evil_null1 = "valid/path\x00/../../etc/passwd";
    try std.testing.expectError(error.NullByteInPath, path_validation.sanitizeArchivePath(allocator, evil_null1));

    const evil_null2 = "foo\x00bar.txt";
    try std.testing.expectError(error.NullByteInPath, path_validation.sanitizeArchivePath(allocator, evil_null2));
}

test "Path validation: Normalizes safe relative paths" {
    const allocator = std.testing.allocator;

    const safe1 = try path_validation.sanitizeArchivePath(allocator, "a/b/c.txt");
    defer allocator.free(safe1);
    try std.testing.expectEqualStrings("a/b/c.txt", safe1);

    const safe_backslashes = try path_validation.sanitizeArchivePath(allocator, "a\\b\\c.txt");
    defer allocator.free(safe_backslashes);
    try std.testing.expectEqualStrings("a/b/c.txt", safe_backslashes);

    const safe_dots = try path_validation.sanitizeArchivePath(allocator, "./a/./b/../b/c.txt");
    defer allocator.free(safe_dots);
    try std.testing.expectEqualStrings("a/b/c.txt", safe_dots);
}

test "Symlink validation: Prevents escaping extraction root" {
    // Valid symlinks inside destination
    try path_validation.validateSymlinkTarget("target.txt", "link.txt");
    try path_validation.validateSymlinkTarget("../target.txt", "sub/link.txt");
    try path_validation.validateSymlinkTarget("../../target.txt", "a/b/link.txt");
    try path_validation.validateSymlinkTarget("nested/target.txt", "link.txt");

    // Invalid escaping symlinks
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("../escape.txt", "link.txt"));
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("../../escape.txt", "sub/link.txt"));
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("../../../escape.txt", "a/b/link.txt"));
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("/etc/passwd", "link.txt"));
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("\\etc\\passwd", "link.txt"));
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("C:\\Windows\\System32", "link.txt"));
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, path_validation.validateSymlinkTarget("..\\..\\escape.txt", "sub/link.txt"));
}

test "Permission sanitization: Strips setuid, setgid, and sticky bits" {
    // Setuid (0o4755) -> 0o755
    try std.testing.expectEqual(@as(u32, 0o755), path_validation.sanitizeMode(0o4755));

    // Setgid (0o2755) -> 0o755
    try std.testing.expectEqual(@as(u32, 0o755), path_validation.sanitizeMode(0o2755));

    // Sticky bit (0o1777) -> 0o777
    try std.testing.expectEqual(@as(u32, 0o777), path_validation.sanitizeMode(0o1777));

    // Plain permissions untouched
    try std.testing.expectEqual(@as(u32, 0o644), path_validation.sanitizeMode(0o644));
    try std.testing.expectEqual(@as(u32, 0o700), path_validation.sanitizeMode(0o700));
}

test "Attack fixture: TAR Zip-Slip extraction attack blocked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    // Create a TAR containing a malicious "../../../escape.txt" entry
    var attack_tar = std.ArrayList(u8).empty;
    defer attack_tar.deinit(allocator);

    const malicious_hdr = helpers.createRawTarHeader("../../escaped_from_tar.txt", 19, 0o644, '0', "");
    try attack_tar.appendSlice(allocator, &malicious_hdr);
    try attack_tar.appendSlice(allocator, "PWNED_TAR_ZIP_SLIP!");
    const pad = [_]u8{0} ** (512 - 19);
    try attack_tar.appendSlice(allocator, &pad);
    const eof = [_]u8{0} ** 1024;
    try attack_tar.appendSlice(allocator, &eof);

    const attack_tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "attack_slip.tar" });
    defer allocator.free(attack_tar_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "attack_slip.tar",
        .data = attack_tar.items,
    });

    const dest_dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest_sandbox" });
    defer allocator.free(dest_dir_path);

    const res = archive.native.extractTar(allocator, io_val, attack_tar_path, dest_dir_path, .{});
    try std.testing.expectError(error.PathTraversalDetected, res);

    // Assert that the escaped file was NEVER written outside the sandbox
    const escaped_exists = if (tmp.dir.access(io_val, "escaped_from_tar.txt", .{})) |_| true else |_| false;
    try std.testing.expect(!escaped_exists);
}

test "Attack fixture: ZIP Zip-Slip extraction attack blocked" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const attack_entries = [_]helpers.ZipEntry{
        .{ .name = "../../escaped_from_zip.txt", .content = "PWNED_ZIP_SLIP!" },
    };

    const zip_bytes = try helpers.createZipBuffer(allocator, &attack_entries);
    defer allocator.free(zip_bytes);

    const attack_zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "attack_slip.zip" });
    defer allocator.free(attack_zip_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "attack_slip.zip",
        .data = zip_bytes,
    });

    const dest_dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest_zip_sandbox" });
    defer allocator.free(dest_dir_path);

    const res = archive.native.extractZip(allocator, io_val, attack_zip_path, dest_dir_path, .{});
    try std.testing.expectError(error.PathTraversalDetected, res);

    // Assert that the escaped file was NEVER written outside the sandbox
    const escaped_exists = if (tmp.dir.access(io_val, "escaped_from_zip.txt", .{})) |_| true else |_| false;
    try std.testing.expect(!escaped_exists);
}

test "Attack fixture: Absolute path TAR entry rejected" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    var attack_tar = std.ArrayList(u8).empty;
    defer attack_tar.deinit(allocator);

    const malicious_hdr = helpers.createRawTarHeader("/tmp/pwned_absolute.txt", 16, 0o644, '0', "");
    try attack_tar.appendSlice(allocator, &malicious_hdr);
    try attack_tar.appendSlice(allocator, "ABSOLUTE_ATTACK!");
    const pad = [_]u8{0} ** (512 - 16);
    try attack_tar.appendSlice(allocator, &pad);
    const eof = [_]u8{0} ** 1024;
    try attack_tar.appendSlice(allocator, &eof);

    const attack_tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "attack_abs.tar" });
    defer allocator.free(attack_tar_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "attack_abs.tar",
        .data = attack_tar.items,
    });

    const dest_dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest_abs_sandbox" });
    defer allocator.free(dest_dir_path);

    const res = archive.native.extractTar(allocator, io_val, attack_tar_path, dest_dir_path, .{});
    try std.testing.expectError(error.AbsolutePathsNotAllowed, res);
}

test "Attack fixture: Escaping symlink in TAR rejected" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    var attack_tar = std.ArrayList(u8).empty;
    defer attack_tar.deinit(allocator);

    // Create a symlink entry named 'evil_link' pointing to '../../outside'
    const link_hdr = helpers.createRawTarHeader("evil_link", 0, 0o777, '2', "../../outside_target");
    try attack_tar.appendSlice(allocator, &link_hdr);
    const eof = [_]u8{0} ** 1024;
    try attack_tar.appendSlice(allocator, &eof);

    const attack_tar_path = try std.fs.path.join(allocator, &.{ tmp_path, "attack_symlink.tar" });
    defer allocator.free(attack_tar_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "attack_symlink.tar",
        .data = attack_tar.items,
    });

    const dest_dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest_sym_sandbox" });
    defer allocator.free(dest_dir_path);

    const res = archive.native.extractTar(allocator, io_val, attack_tar_path, dest_dir_path, .{});
    try std.testing.expectError(error.SymlinkTargetEscapesDestination, res);
}

test "Attack fixture: Null byte injected member path in ZIP" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_val = std.testing.io;

    const tmp_path = try tmp.dir.realPathFileAlloc(io_val, ".", allocator);
    defer allocator.free(tmp_path);

    const null_entries = [_]helpers.ZipEntry{
        .{ .name = "safe_name\x00/../../etc/passwd", .content = "MALICIOUS" },
    };

    const zip_bytes = try helpers.createZipBuffer(allocator, &null_entries);
    defer allocator.free(zip_bytes);

    const zip_path = try std.fs.path.join(allocator, &.{ tmp_path, "null_slip.zip" });
    defer allocator.free(zip_path);
    try tmp.dir.writeFile(io_val, .{
        .sub_path = "null_slip.zip",
        .data = zip_bytes,
    });

    const dest_dir_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest_null_zip" });
    defer allocator.free(dest_dir_path);

    const res = archive.native.extractZip(allocator, io_val, zip_path, dest_dir_path, .{});
    try std.testing.expectError(error.NullByteInPath, res);
}
