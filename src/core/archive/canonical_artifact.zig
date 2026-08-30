const std = @import("std");
const hash = @import("../identity/hash.zig");

/// The only modes accepted by the canonical artifact format.  They mean
/// ordinary data and a portable executable respectively; source filesystem
/// metadata is deliberately not consulted.
pub const PortableMode = enum(u16) {
    file = 0o644,
    executable = 0o755,

    pub fn parse(text: []const u8) !PortableMode {
        if (std.mem.eql(u8, text, "0644") or std.mem.eql(u8, text, "644")) return .file;
        if (std.mem.eql(u8, text, "0755") or std.mem.eql(u8, text, "755")) return .executable;
        return error.UnsupportedPortableMode;
    }
};

/// A declared regular-file member. `virtual_path` names the member in the
/// archive and is never inferred from `source_path`.
pub const Entry = struct {
    virtual_path: []const u8,
    source_path: []const u8,
    mode: PortableMode,
};

pub const Result = struct {
    /// The destination path passed to create(). Owned by the caller.
    path: []u8,
    /// Number of bytes in the compressed .tar.gz artifact.
    bytes: u64,
    /// BLAKE3 of the compressed artifact, formatted as `b3:<lowercase-hex>`.
    b3: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.b3);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidVirtualPath,
    DuplicateVirtualPath,
    CaseCollision,
    PathHierarchyConflict,
    UnsupportedPortableMode,
    UnsupportedEntryType,
    OutputPathInvalid,
} || std.mem.Allocator.Error;

const PreparedEntry = struct {
    entry: Entry,
    file: std.Io.File,
    size: u64,
    folded_path: []u8,

    fn deinit(self: *PreparedEntry, allocator: std.mem.Allocator, io: std.Io) void {
        self.file.close(io);
        allocator.free(self.folded_path);
        self.* = undefined;
    }
};

/// Create an exactly reproducible gzip-compressed POSIX tar artifact.
///
/// All entries are preflighted before the destination is touched. The archive
/// contains only sorted regular-file entries with the declared portable mode,
/// mtime 0, and zeroed tar ownership fields. Compression uses the native Zig
/// gzip implementation, whose header has mtime 0 and OS=Unix. The temporary
/// output is a sibling created with std.Io.File.Atomic and only replaces the
/// destination after the gzip stream, hash, and file writer have completed.
pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_path: []const u8,
    entries: []const Entry,
) !Result {
    if (output_path.len == 0 or std.mem.eql(u8, output_path, ".") or std.mem.eql(u8, output_path, "..")) {
        return error.OutputPathInvalid;
    }

    var prepared = std.ArrayList(PreparedEntry).empty;
    defer {
        for (prepared.items) |*item| item.deinit(allocator, io);
        prepared.deinit(allocator);
    }

    // Open each source without following a symlink. Holding the file handle
    // makes the archive independent of later pathname replacement.
    for (entries) |entry| {
        const folded_path = try validateVirtualPath(allocator, entry.virtual_path);
        errdefer allocator.free(folded_path);

        const source_stat = try std.Io.Dir.cwd().statFile(io, entry.source_path, .{ .follow_symlinks = false });
        if (source_stat.kind != .file) return error.UnsupportedEntryType;

        var source_file = try std.Io.Dir.cwd().openFile(io, entry.source_path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        errdefer source_file.close(io);
        const opened_stat = try source_file.stat(io);
        if (opened_stat.kind != .file) return error.UnsupportedEntryType;

        try prepared.append(allocator, .{
            .entry = entry,
            .file = source_file,
            .size = opened_stat.size,
            .folded_path = folded_path,
        });
    }

    std.mem.sort(PreparedEntry, prepared.items, {}, lessThanEntry);
    try validateUniqueAndNonOverlapping(allocator, prepared.items);

    const output_dir_path = std.fs.path.dirname(output_path) orelse ".";
    const output_basename = std.fs.path.basename(output_path);
    if (output_basename.len == 0 or std.mem.eql(u8, output_basename, ".") or std.mem.eql(u8, output_basename, "..")) {
        return error.OutputPathInvalid;
    }

    var output_dir = try std.Io.Dir.cwd().openDir(io, output_dir_path, .{});
    defer output_dir.close(io);
    var staged = try output_dir.createFileAtomic(io, output_basename, .{ .replace = true });
    defer staged.deinit(io);

    var file_buffer: [32 * 1024]u8 = undefined;
    var file_writer = staged.file.writer(io, &file_buffer);
    var hash_buffer: [32 * 1024]u8 = undefined;
    var hashed_writer = std.Io.Writer.Hashed(std.crypto.hash.Blake3).initHasher(
        &file_writer.interface,
        std.crypto.hash.Blake3.init(.{}),
        &hash_buffer,
    );

    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&hashed_writer.writer, &flate_buffer, .gzip, .default);
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &compressor.writer };

    for (prepared.items) |item| {
        var source_buffer: [32 * 1024]u8 = undefined;
        var source_reader = item.file.reader(io, &source_buffer);
        try tar_writer.writeFileStream(item.entry.virtual_path, item.size, &source_reader.interface, .{
            .mode = @intFromEnum(item.entry.mode),
            .mtime = 0,
        });
    }
    try tar_writer.finishPedantically();
    try compressor.finish();
    try hashed_writer.writer.flush();
    try file_writer.interface.flush();

    const bytes = try staged.file.length(io);
    var digest: [32]u8 = undefined;
    hashed_writer.hasher.final(&digest);
    const b3 = try hash.blake3Digest(allocator, digest);
    errdefer allocator.free(b3);

    try staged.replace(io);
    return .{
        .path = try allocator.dupe(u8, output_path),
        .bytes = bytes,
        .b3 = b3,
    };
}

fn lessThanEntry(_: void, a: PreparedEntry, b: PreparedEntry) bool {
    return std.mem.lessThan(u8, a.entry.virtual_path, b.entry.virtual_path);
}

fn validateUniqueAndNonOverlapping(allocator: std.mem.Allocator, entries: []const PreparedEntry) !void {
    for (entries, 0..) |entry, index| {
        if (index == 0) continue;
        const previous = entries[index - 1];
        if (std.mem.eql(u8, entry.entry.virtual_path, previous.entry.virtual_path)) return error.DuplicateVirtualPath;
        if (isPathPrefix(previous.entry.virtual_path, entry.entry.virtual_path)) return error.PathHierarchyConflict;
    }

    // Sorting is by bytewise archive name, not folded name; e.g. `A`, `B`,
    // and `a` are not adjacent. Keep a separate folded-name set so every
    // case-insensitive collision is rejected without disturbing tar order.
    var folded_paths = std.StringHashMap(void).init(allocator);
    defer folded_paths.deinit();
    for (entries) |entry| {
        if (folded_paths.contains(entry.folded_path)) return error.CaseCollision;
        try folded_paths.put(entry.folded_path, {});
    }
}

fn isPathPrefix(prefix: []const u8, path: []const u8) bool {
    return path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/';
}

/// The artifact namespace is deliberately stricter than a host filesystem:
/// ASCII-only components avoid Unicode normalization collisions, while the
/// Windows device/trailing-name rules make one archive valid on every target.
/// This is a transport contract, not a general filename validator.
fn validateVirtualPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\' or std.mem.indexOfScalar(u8, path, 0) != null) {
        return error.InvalidVirtualPath;
    }

    var folded = try allocator.alloc(u8, path.len);
    errdefer allocator.free(folded);

    var component_start: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '\\' or byte == ':' or byte == '<' or byte == '>' or byte == '"' or byte == '|' or byte == '?' or byte == '*' or byte < 0x20 or byte > 0x7e) {
            return error.InvalidVirtualPath;
        }
        if (byte == '/') {
            if (!validateComponent(path[component_start..index])) return error.InvalidVirtualPath;
            component_start = index + 1;
            folded[index] = '/';
        } else {
            if (!isPortableNameByte(byte)) return error.InvalidVirtualPath;
            folded[index] = std.ascii.toLower(byte);
        }
    }
    if (!validateComponent(path[component_start..])) return error.InvalidVirtualPath;
    return folded;
}

fn isPortableNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
}

fn validateComponent(component: []const u8) bool {
    if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    if (component[component.len - 1] == '.' or component[component.len - 1] == ' ') return false;
    return !isWindowsReservedDevice(component);
}

fn isWindowsReservedDevice(component: []const u8) bool {
    const stem = if (std.mem.indexOfScalar(u8, component, '.')) |dot| component[0..dot] else component;
    if (std.ascii.eqlIgnoreCase(stem, "con") or std.ascii.eqlIgnoreCase(stem, "prn") or
        std.ascii.eqlIgnoreCase(stem, "aux") or std.ascii.eqlIgnoreCase(stem, "nul")) return true;
    if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt"))) {
        return stem[3] >= '1' and stem[3] <= '9';
    }
    return false;
}
