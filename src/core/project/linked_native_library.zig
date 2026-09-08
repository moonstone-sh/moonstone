// SPDX-License-Identifier: Apache-2.0

//! Native-library declarations read from a linked package's own manifest.
//!
//! A published artifact records `native_lib` provisions in its registry
//! descriptor, and the store keeps them as `manifest.FeatureProvision` values
//! that the project linker projects into `.moonstone/env/lib/native`. A
//! package consumed through `path:`/`link:` is never published, so it has no
//! artifact manifest and no target matrix — it is one concrete directory on
//! this host. Its own `moonstone.toml` is therefore the declaration site, and
//! this module reads exactly that:
//!
//! ```toml
//! [[provides.native_lib]]
//! name = "yogacore"
//! path = "native/dist/aarch64-macos/libyogacore.dylib"
//! ```
//!
//! The projection contract is unchanged from
//! `docs/maintenance/native-library-projection-contract-2026-08-09.md`: the
//! loader-visible basename is the project-wide conflict key, `static` entries
//! are retained but never projected, and Moonstone never rewrites install
//! names or rpaths.
//!
//! Because a live dependency can only be realized for the host target
//! (`moon sync` rejects a live source for a foreign target), the accepted
//! filename vocabulary here is the *host* vocabulary, selected at compile time
//! exactly like the loader environment variable in `run_env.zig`.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("../domain/manifest.zig");
const error_context = @import("../diagnostics/error_context.zig");

pub const DeclaredLibrary = struct {
    /// The provision's semantic name, used only in diagnostics.
    name: []const u8,
    /// The loader-visible filename: the project-wide conflict key.
    file_name: []const u8,
    /// Absolute path to the declared file inside the package's own tree.
    source_path: []const u8,
    linkage: manifest.NativeLibraryLinkage,

    pub fn deinit(self: DeclaredLibrary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.file_name);
        allocator.free(self.source_path);
    }
};

pub const Declarations = struct {
    items: []const DeclaredLibrary = &.{},

    pub fn deinit(self: Declarations, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

/// A declaration path must name a file inside the package, using `/` as its
/// separator. Absolute paths, parent traversal, and backslashes are refused so
/// a manifest cannot reach outside its own tree and reads the same on every
/// host.
pub fn isSafeDeclarationPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    // A Windows drive-relative spelling such as `C:lib/x.dll` is not absolute
    // by `isAbsolute`'s POSIX rule but is still host-specific.
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;

    var segments = std.mem.splitScalar(u8, path, '/');
    var segment_count: usize = 0;
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        segment_count += 1;
    }
    return segment_count > 0;
}

/// Does this filename name something the host dynamic loader can open?
///
/// macOS accepts `.so` in addition to `.dylib` because Lua-adjacent build
/// systems routinely emit the portable suffix there; `run_env`'s Lua C module
/// search path already makes the same allowance.
pub fn isHostLoadableLibraryName(file_name: []const u8) bool {
    return switch (builtin.os.tag) {
        .windows => std.ascii.endsWithIgnoreCase(file_name, ".dll"),
        .macos => std.mem.endsWith(u8, file_name, ".dylib") or
            std.mem.endsWith(u8, file_name, ".so") or
            std.mem.indexOf(u8, file_name, ".so.") != null,
        else => std.mem.endsWith(u8, file_name, ".so") or
            std.mem.indexOf(u8, file_name, ".so.") != null,
    };
}

/// Read `[[provides.native_lib]]` from `<package_root>/moonstone.toml`.
///
/// A package without a manifest, or without the section, declares nothing:
/// that is the common case and is not an error. An unsatisfiable declaration
/// is an error with a recovery-oriented diagnostic, raised before the linker
/// touches the environment tree.
///
/// A manifest that does not parse also declares nothing here. `link:`
/// resolution never reads the linked package's manifest at all, so refusing to
/// link it at projection time would reject environments that Moonstone accepts
/// today; the neighbouring live-link readers in `linker.zig` are tolerant for
/// the same reason. A `path:` dependency's manifest is parsed during
/// resolution, so a malformed one already fails before reaching this point.
pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_name: []const u8,
    package_root: []const u8,
) !Declarations {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, "moonstone.toml" });
    defer allocator.free(manifest_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return .{};
        return err;
    };
    defer allocator.free(content);

    var package_manifest = manifest.MoonstoneToml.parse(allocator, content) catch return .{};
    defer package_manifest.deinit(allocator);

    if (package_manifest.provides.native_lib.len == 0) return .{};

    var declared = std.ArrayList(DeclaredLibrary).empty;
    errdefer {
        for (declared.items) |item| item.deinit(allocator);
        declared.deinit(allocator);
    }

    for (package_manifest.provides.native_lib) |provision| {
        if (!isSafeDeclarationPath(provision.path)) {
            error_context.setFmt(
                allocator,
                "Linked dependency '{s}' declares native library '{s}' at unsafe path '{s}'. Use a relative '/'-separated path inside the package, such as 'native/dist/lib{s}.so'.",
                .{ package_name, provision.name, provision.path, provision.name },
            );
            return error.UnsafeNativeLibraryDeclaration;
        }

        const file_name = std.fs.path.basename(provision.path);
        if (provision.linkage == .shared and !isHostLoadableLibraryName(file_name)) {
            error_context.setFmt(
                allocator,
                "Linked dependency '{s}' declares native library '{s}' as '{s}', which this host's dynamic loader cannot open. Point the declaration at a host shared library, or record 'linkage = \"static\"' if it is an archive.",
                .{ package_name, provision.name, file_name },
            );
            return error.UnsupportedNativeLibraryFilename;
        }

        const source_path = try std.fs.path.join(allocator, &.{ package_root, provision.path });
        errdefer allocator.free(source_path);

        const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch |err| {
            if (err == error.FileNotFound or err == error.NotDir) {
                error_context.setFmt(
                    allocator,
                    "Linked dependency '{s}' declares native library '{s}' at '{s}', which does not exist. Build it before syncing, or remove the declaration from that package's moonstone.toml.",
                    .{ package_name, provision.name, source_path },
                );
                return error.DeclaredNativeLibraryMissing;
            }
            return err;
        };
        if (stat.kind != .file) {
            error_context.setFmt(
                allocator,
                "Linked dependency '{s}' declares native library '{s}' at '{s}', which is not a regular file.",
                .{ package_name, provision.name, source_path },
            );
            return error.DeclaredNativeLibraryNotAFile;
        }

        const provision_name = try allocator.dupe(u8, provision.name);
        errdefer allocator.free(provision_name);
        const projected_name = try allocator.dupe(u8, file_name);
        errdefer allocator.free(projected_name);
        try declared.append(allocator, .{
            .name = provision_name,
            .file_name = projected_name,
            .source_path = source_path,
            .linkage = provision.linkage,
        });
    }

    return .{ .items = try declared.toOwnedSlice(allocator) };
}

test "declaration paths stay inside the package and stay portable" {
    try std.testing.expect(isSafeDeclarationPath("native/dist/libyogacore.dylib"));
    try std.testing.expect(isSafeDeclarationPath("libyogacore.so"));

    try std.testing.expect(!isSafeDeclarationPath(""));
    try std.testing.expect(!isSafeDeclarationPath("/usr/lib/libyogacore.dylib"));
    try std.testing.expect(!isSafeDeclarationPath("../sibling/libyogacore.so"));
    try std.testing.expect(!isSafeDeclarationPath("native/../../libyogacore.so"));
    try std.testing.expect(!isSafeDeclarationPath("native//libyogacore.so"));
    try std.testing.expect(!isSafeDeclarationPath("./libyogacore.so"));
    try std.testing.expect(!isSafeDeclarationPath("native\\dist\\yogacore.dll"));
    try std.testing.expect(!isSafeDeclarationPath("C:lib/yogacore.dll"));
}

test "host loadable filenames follow the host loader vocabulary" {
    switch (builtin.os.tag) {
        .windows => {
            try std.testing.expect(isHostLoadableLibraryName("yogacore.dll"));
            try std.testing.expect(!isHostLoadableLibraryName("libyogacore.so"));
        },
        .macos => {
            try std.testing.expect(isHostLoadableLibraryName("libyogacore.dylib"));
            try std.testing.expect(isHostLoadableLibraryName("libyogacore.so"));
            try std.testing.expect(!isHostLoadableLibraryName("libyogacore.a"));
            try std.testing.expect(!isHostLoadableLibraryName("yogacore.dll"));
        },
        else => {
            try std.testing.expect(isHostLoadableLibraryName("libyogacore.so"));
            try std.testing.expect(isHostLoadableLibraryName("libyogacore.so.1.2"));
            try std.testing.expect(!isHostLoadableLibraryName("libyogacore.a"));
            try std.testing.expect(!isHostLoadableLibraryName("libyogacore.dylib"));
        },
    }
}

fn writeTestPackage(io: std.Io, dir: std.Io.Dir, manifest_body: []const u8) !void {
    const file = try dir.createFile(io, "moonstone.toml", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, manifest_body);
}

const host_shared_library_name = switch (builtin.os.tag) {
    .windows => "yogacore.dll",
    .macos => "libyogacore.dylib",
    else => "libyogacore.so",
};

test "a package without declarations collects nothing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathAlloc(io, allocator, ".");
    defer allocator.free(root);

    const missing = try collect(allocator, io, "no-manifest", root);
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);

    try writeTestPackage(io, tmp.dir,
        \\[package]
        \\name = "plain"
        \\version = "0.1.0"
        \\kind = "lib"
        \\
    );
    const plain = try collect(allocator, io, "plain", root);
    defer plain.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), plain.items.len);

    // An unparseable manifest declares nothing rather than failing a
    // projection that `link:` resolution already accepted.
    try writeTestPackage(io, tmp.dir, "this is not TOML at all\n");
    const unparseable = try collect(allocator, io, "unparseable", root);
    defer unparseable.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), unparseable.items.len);
}

test "declared native libraries resolve against the package root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "native/dist");
    var dist = try tmp.dir.openDir(io, "native/dist", .{});
    defer dist.close(io);
    const library = try dist.createFile(io, host_shared_library_name, .{});
    library.close(io);
    const archive = try dist.createFile(io, "libyogacore.a", .{});
    archive.close(io);

    const manifest_body = try std.fmt.allocPrint(allocator,
        \\[package]
        \\name = "hydronium-ink"
        \\version = "0.1.0"
        \\kind = "lib"
        \\
        \\[[provides.native_lib]]
        \\name = "yogacore"
        \\path = "native/dist/{s}"
        \\
        \\[[provides.native_lib]]
        \\name = "yogacore-archive"
        \\path = "native/dist/libyogacore.a"
        \\linkage = "static"
        \\
    , .{host_shared_library_name});
    defer allocator.free(manifest_body);
    try writeTestPackage(io, tmp.dir, manifest_body);

    const root = try tmp.dir.realPathAlloc(io, allocator, ".");
    defer allocator.free(root);

    const declared = try collect(allocator, io, "hydronium-ink", root);
    defer declared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), declared.items.len);
    try std.testing.expectEqualStrings(host_shared_library_name, declared.items[0].file_name);
    try std.testing.expectEqual(manifest.NativeLibraryLinkage.shared, declared.items[0].linkage);
    try std.testing.expectEqual(manifest.NativeLibraryLinkage.static, declared.items[1].linkage);

    const expected = try std.fs.path.join(allocator, &.{ root, "native/dist", host_shared_library_name });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, declared.items[0].source_path);
}

test "a declared but unbuilt native library fails with a recovery diagnostic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_body = try std.fmt.allocPrint(allocator,
        \\[package]
        \\name = "hydronium-ink"
        \\version = "0.1.0"
        \\kind = "lib"
        \\
        \\[[provides.native_lib]]
        \\name = "yogacore"
        \\path = "native/dist/{s}"
        \\
    , .{host_shared_library_name});
    defer allocator.free(manifest_body);
    try writeTestPackage(io, tmp.dir, manifest_body);

    const root = try tmp.dir.realPathAlloc(io, allocator, ".");
    defer allocator.free(root);

    try std.testing.expectError(error.DeclaredNativeLibraryMissing, collect(allocator, io, "hydronium-ink", root));
    const diagnostic = error_context.take(allocator).?;
    defer allocator.free(diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "does not exist") != null);
}

test "a shared declaration must name a host-loadable file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestPackage(io, tmp.dir,
        \\[package]
        \\name = "hydronium-ink"
        \\version = "0.1.0"
        \\kind = "lib"
        \\
        \\[[provides.native_lib]]
        \\name = "yogacore"
        \\path = "native/dist/libyogacore.unknown"
        \\
    );

    const root = try tmp.dir.realPathAlloc(io, allocator, ".");
    defer allocator.free(root);

    try std.testing.expectError(error.UnsupportedNativeLibraryFilename, collect(allocator, io, "hydronium-ink", root));
    const diagnostic = error_context.take(allocator).?;
    defer allocator.free(diagnostic);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "dynamic loader cannot open") != null);
}

test "an escaping declaration path is refused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestPackage(io, tmp.dir,
        \\[package]
        \\name = "hydronium-ink"
        \\version = "0.1.0"
        \\kind = "lib"
        \\
        \\[[provides.native_lib]]
        \\name = "yogacore"
        \\path = "../../elsewhere/libyogacore.so"
        \\
    );

    const root = try tmp.dir.realPathAlloc(io, allocator, ".");
    defer allocator.free(root);

    try std.testing.expectError(error.UnsafeNativeLibraryDeclaration, collect(allocator, io, "hydronium-ink", root));
    _ = error_context.take(allocator);
}
