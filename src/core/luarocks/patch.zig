const std = @import("std");
const builtin = @import("builtin");

var staging_counter: std.atomic.Value(u64) = .init(0);

/// Portable representation of the inline unified diffs LuaRocks stores in
/// `build.patches`. This deliberately has no process or filesystem behavior:
/// parsing and applying source transformations are independently auditable.
pub const LineKind = enum { context, add, remove };

pub const HunkLine = struct {
    kind: LineKind,
    text: []const u8,

    fn deinit(self: HunkLine, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []const HunkLine,

    fn deinit(self: Hunk, allocator: std.mem.Allocator) void {
        for (self.lines) |line| line.deinit(allocator);
        allocator.free(self.lines);
    }
};

pub const FilePatch = struct {
    old_path: []const u8,
    new_path: []const u8,
    hunks: []const Hunk,

    fn deinit(self: FilePatch, allocator: std.mem.Allocator) void {
        allocator.free(self.old_path);
        allocator.free(self.new_path);
        for (self.hunks) |hunk| hunk.deinit(allocator);
        allocator.free(self.hunks);
    }
};

pub const Patch = struct {
    files: []const FilePatch,

    pub fn deinit(self: Patch, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
    }
};

/// Converts a unified-diff filename into a lexical path relative to the source
/// root. LuaRocks applies conventional patches with one leading `a/` or `b/`
/// segment removed. This does not perform filesystem traversal; callers still
/// need a no-follow directory walk before applying it to untrusted sources.
pub fn relativePath(path: []const u8, strip_components: usize) ![]const u8 {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return error.UnsafePatchPath;
    var relative = path;
    var stripped: usize = 0;
    while (stripped < strip_components) : (stripped += 1) {
        const separator = std.mem.indexOfScalar(u8, relative, '/') orelse return error.UnsafePatchPath;
        relative = relative[separator + 1 ..];
    }
    if (relative.len == 0) return error.UnsafePatchPath;
    var segments = std.mem.tokenizeScalar(u8, relative, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.UnsafePatchPath;
    }
    return relative;
}

const SourceLines = struct {
    lines: []const []const u8,
    newline: []const u8,
    trailing_newline: bool,

    fn deinit(self: SourceLines, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }
};

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

fn patchPath(header: []const u8, prefix: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, header, prefix)) return error.InvalidUnifiedDiff;
    const payload = header[prefix.len..];
    const end = std.mem.indexOfAny(u8, payload, "\t ") orelse payload.len;
    if (end == 0) return error.InvalidUnifiedDiff;
    return payload[0..end];
}

fn parseRange(value: []const u8) !struct { start: usize, count: usize } {
    var parts = std.mem.splitScalar(u8, value, ',');
    const start_text = parts.next() orelse return error.InvalidUnifiedDiff;
    const start = try std.fmt.parseInt(usize, start_text, 10);
    const count = if (parts.next()) |count_text| try std.fmt.parseInt(usize, count_text, 10) else 1;
    if (parts.next() != null) return error.InvalidUnifiedDiff;
    return .{ .start = start, .count = count };
}

fn parseHunkHeader(line: []const u8) !struct { old_start: usize, old_count: usize, new_start: usize, new_count: usize } {
    if (!std.mem.startsWith(u8, line, "@@ -")) return error.InvalidUnifiedDiff;
    const closing = std.mem.indexOf(u8, line, " @@") orelse return error.InvalidUnifiedDiff;
    const ranges = line[4..closing];
    var parts = std.mem.splitScalar(u8, ranges, ' ');
    const old = try parseRange(parts.next() orelse return error.InvalidUnifiedDiff);
    const new_text = parts.next() orelse return error.InvalidUnifiedDiff;
    if (!std.mem.startsWith(u8, new_text, "+")) return error.InvalidUnifiedDiff;
    const new = try parseRange(new_text[1..]);
    return .{ .old_start = old.start, .old_count = old.count, .new_start = new.start, .new_count = new.count };
}

fn splitSourceLines(allocator: std.mem.Allocator, source: []const u8) !SourceLines {
    const newline = if (std.mem.indexOf(u8, source, "\r\n") != null) "\r\n" else if (std.mem.indexOfScalar(u8, source, '\n') != null) "\n" else if (std.mem.indexOfScalar(u8, source, '\r') != null) "\r" else "\n";
    const trailing_newline = std.mem.endsWith(u8, source, newline);
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(allocator);

    var start: usize = 0;
    var index: usize = 0;
    while (index < source.len) {
        const newline_len: usize = if (std.mem.startsWith(u8, source[index..], newline)) newline.len else 0;
        if (newline_len == 0) {
            index += 1;
            continue;
        }
        try lines.append(allocator, source[start..index]);
        index += newline_len;
        start = index;
    }
    if (start < source.len) try lines.append(allocator, source[start..]);
    return .{ .lines = try lines.toOwnedSlice(allocator), .newline = newline, .trailing_newline = trailing_newline };
}

fn appendLine(output: *std.ArrayList(u8), allocator: std.mem.Allocator, line: []const u8, newline: []const u8, append_newline: bool) !void {
    try output.appendSlice(allocator, line);
    if (append_newline) try output.appendSlice(allocator, newline);
}

/// Applies modification hunks to one source file using exact context matching.
/// It intentionally rejects create/delete patches and no-newline markers until
/// the filesystem layer can represent those semantics without data loss.
pub fn applyFile(allocator: std.mem.Allocator, source: []const u8, file: FilePatch) ![]u8 {
    if (std.mem.eql(u8, file.old_path, "/dev/null") or std.mem.eql(u8, file.new_path, "/dev/null")) return error.UnsupportedPatchCreateDelete;
    const source_lines = try splitSourceLines(allocator, source);
    defer source_lines.deinit(allocator);

    var output_lines = std.ArrayList([]const u8).empty;
    defer output_lines.deinit(allocator);
    var source_index: usize = 0;
    for (file.hunks) |hunk| {
        if (hunk.old_start == 0) return error.UnsupportedPatchCreateDelete;
        const hunk_start = hunk.old_start - 1;
        if (hunk_start < source_index or hunk_start > source_lines.lines.len) return error.PatchHunkMismatch;
        try output_lines.appendSlice(allocator, source_lines.lines[source_index..hunk_start]);
        source_index = hunk_start;

        var observed_old: usize = 0;
        var observed_new: usize = 0;
        for (hunk.lines) |line| {
            switch (line.kind) {
                .context => {
                    if (source_index >= source_lines.lines.len or !std.mem.eql(u8, source_lines.lines[source_index], line.text)) return error.PatchHunkMismatch;
                    try output_lines.append(allocator, source_lines.lines[source_index]);
                    source_index += 1;
                    observed_old += 1;
                    observed_new += 1;
                },
                .remove => {
                    if (source_index >= source_lines.lines.len or !std.mem.eql(u8, source_lines.lines[source_index], line.text)) return error.PatchHunkMismatch;
                    source_index += 1;
                    observed_old += 1;
                },
                .add => {
                    try output_lines.append(allocator, line.text);
                    observed_new += 1;
                },
            }
        }
        if (observed_old != hunk.old_count or observed_new != hunk.new_count) return error.InvalidUnifiedDiff;
    }
    try output_lines.appendSlice(allocator, source_lines.lines[source_index..]);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (output_lines.items, 0..) |line, index| {
        const append_newline = index + 1 < output_lines.items.len or source_lines.trailing_newline;
        try appendLine(&output, allocator, line, source_lines.newline, append_newline);
    }
    return try output.toOwnedSlice(allocator);
}

/// Applies one ordinary modification patch beneath an already-selected source
/// root. Target files are opened without following symlinks and through the
/// root handle; replacement happens through a sibling temporary file and
/// rename. Create/delete patches are deliberately excluded from this API.
pub fn applyFileAtRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_root: []const u8,
    file: FilePatch,
) !void {
    if (std.mem.eql(u8, file.old_path, "/dev/null") or std.mem.eql(u8, file.new_path, "/dev/null")) {
        return error.UnsupportedPatchCreateDelete;
    }
    const old_relative = try relativePath(file.old_path, 1);
    const new_relative = try relativePath(file.new_path, 1);
    if (!std.mem.eql(u8, old_relative, new_relative)) return error.UnsupportedPatchRename;

    var root = try std.Io.Dir.cwd().openDir(io, source_root, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    var source_file = try root.openFile(io, old_relative, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer source_file.close(io);
    var source_reader = source_file.reader(io, &.{});
    const source = source_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return source_reader.err.?,
        else => return err,
    };
    defer allocator.free(source);
    const patched = try applyFile(allocator, source, file);
    defer allocator.free(patched);

    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.moonstone-patch-{d}", .{ old_relative, staging_counter.fetchAdd(1, .monotonic) });
    defer allocator.free(temporary_path);
    var temporary_file = try root.createFile(io, temporary_path, .{
        .exclusive = true,
        .resolve_beneath = true,
    });
    errdefer root.deleteFile(io, temporary_path) catch {};
    try temporary_file.writeStreamingAll(io, patched);
    temporary_file.close(io);
    try root.rename(temporary_path, root, old_relative, io);
}

/// Parses ordinary unified diffs with `---`, `+++`, and `@@` records. The
/// source applicator will separately validate root containment, hunk matching,
/// and format-3 create/delete behavior before this becomes resolver-visible.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Patch {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var source_lines = std.mem.splitScalar(u8, source, '\n');
    while (source_lines.next()) |line| try lines.append(allocator, trimLine(line));

    var files = std.ArrayList(FilePatch).empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }

    var index: usize = 0;
    while (index < lines.items.len) {
        const old_header = lines.items[index];
        if (!std.mem.startsWith(u8, old_header, "--- ")) {
            index += 1;
            continue;
        }
        index += 1;
        if (index >= lines.items.len) return error.InvalidUnifiedDiff;
        const new_header = lines.items[index];
        index += 1;

        const old_path = try allocator.dupe(u8, try patchPath(old_header, "--- "));
        errdefer allocator.free(old_path);
        const new_path = try allocator.dupe(u8, try patchPath(new_header, "+++ "));
        errdefer allocator.free(new_path);

        var hunks = std.ArrayList(Hunk).empty;
        errdefer {
            for (hunks.items) |hunk| hunk.deinit(allocator);
            hunks.deinit(allocator);
        }
        while (index < lines.items.len) {
            const line = lines.items[index];
            if (std.mem.startsWith(u8, line, "--- ")) break;
            if (!std.mem.startsWith(u8, line, "@@ -")) {
                index += 1;
                continue;
            }
            const range = try parseHunkHeader(line);
            index += 1;
            var hunk_lines = std.ArrayList(HunkLine).empty;
            errdefer {
                for (hunk_lines.items) |item| item.deinit(allocator);
                hunk_lines.deinit(allocator);
            }
            while (index < lines.items.len) {
                const hunk_line = lines.items[index];
                if (std.mem.startsWith(u8, hunk_line, "@@ -") or std.mem.startsWith(u8, hunk_line, "--- ")) break;
                index += 1;
                if (hunk_line.len == 0) continue;
                if (hunk_line[0] == '\\') return error.UnsupportedPatchNoNewline;
                const kind: LineKind = switch (hunk_line[0]) {
                    ' ' => .context,
                    '+' => .add,
                    '-' => .remove,
                    else => return error.InvalidUnifiedDiff,
                };
                try hunk_lines.append(allocator, .{ .kind = kind, .text = try allocator.dupe(u8, hunk_line[1..]) });
            }
            try hunks.append(allocator, .{ .old_start = range.old_start, .old_count = range.old_count, .new_start = range.new_start, .new_count = range.new_count, .lines = try hunk_lines.toOwnedSlice(allocator) });
        }
        if (hunks.items.len == 0) return error.InvalidUnifiedDiff;
        try files.append(allocator, .{ .old_path = old_path, .new_path = new_path, .hunks = try hunks.toOwnedSlice(allocator) });
    }
    if (files.items.len == 0) return error.InvalidUnifiedDiff;
    return .{ .files = try files.toOwnedSlice(allocator) };
}

test "parses a standard unified diff hunk" {
    var patch = try parse(
        std.testing.allocator,
        "--- a/src/greeting.lua\n" ++
            "+++ b/src/greeting.lua\n" ++
            "@@ -1,2 +1,2 @@\n" ++
            " return 'hello'\n" ++
            "-return 'old'\n" ++
            "+return 'new'\n",
    );
    defer patch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), patch.files.len);
    try std.testing.expectEqualStrings("a/src/greeting.lua", patch.files[0].old_path);
    try std.testing.expectEqual(@as(usize, 3), patch.files[0].hunks[0].lines.len);
    try std.testing.expectEqual(LineKind.add, patch.files[0].hunks[0].lines[2].kind);
}

test "rejects an incomplete unified diff" {
    try std.testing.expectError(error.InvalidUnifiedDiff, parse(std.testing.allocator, "--- a/file\n+++ b/file\n"));
}

test "preserves multiple hunks and files" {
    var patch = try parse(
        std.testing.allocator,
        "--- a/first.lua\n" ++
            "+++ b/first.lua\n" ++
            "@@ -1 +1 @@\n" ++
            "-one\n" ++
            "+ONE\n" ++
            "@@ -3 +3 @@\n" ++
            "-three\n" ++
            "+THREE\n" ++
            "--- a/second.lua\n" ++
            "+++ b/second.lua\n" ++
            "@@ -1 +1 @@\n" ++
            "-two\n" ++
            "+TWO\n",
    );
    defer patch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), patch.files.len);
    try std.testing.expectEqual(@as(usize, 2), patch.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 1), patch.files[1].hunks.len);
}

test "applies exact hunks and preserves CRLF" {
    var patch = try parse(
        std.testing.allocator,
        "--- a/greeting.lua\n" ++
            "+++ b/greeting.lua\n" ++
            "@@ -1,2 +1,2 @@\n" ++
            " hello\n" ++
            "-world\n" ++
            "+moonstone\n",
    );
    defer patch.deinit(std.testing.allocator);
    const output = try applyFile(std.testing.allocator, "hello\r\nworld\r\n", patch.files[0]);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello\r\nmoonstone\r\n", output);
}

test "rejects a mismatched source hunk" {
    var patch = try parse(
        std.testing.allocator,
        "--- a/greeting.lua\n" ++
            "+++ b/greeting.lua\n" ++
            "@@ -1 +1 @@\n" ++
            "-old\n" ++
            "+new\n",
    );
    defer patch.deinit(std.testing.allocator);
    try std.testing.expectError(error.PatchHunkMismatch, applyFile(std.testing.allocator, "other\n", patch.files[0]));
}

test "normalizes conventional patch paths without allowing traversal" {
    try std.testing.expectEqualStrings("src/greeting.lua", try relativePath("a/src/greeting.lua", 1));
    try std.testing.expectError(error.UnsafePatchPath, relativePath("a/../secret.lua", 1));
    try std.testing.expectError(error.UnsafePatchPath, relativePath("/etc/passwd", 1));
    try std.testing.expectError(error.UnsafePatchPath, relativePath("a\\src\\greeting.lua", 1));
}

test "rejects no-final-newline markers until their byte semantics are implemented" {
    try std.testing.expectError(error.UnsupportedPatchNoNewline, parse(
        std.testing.allocator,
        "--- a/greeting.lua\n" ++
            "+++ b/greeting.lua\n" ++
            "@@ -1 +1 @@\n" ++
            "-old\n" ++
            "+new\n" ++
            "\\ No newline at end of file\n",
    ));
}

test "applies an ordinary patch beneath an isolated source root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, "greeting.lua", "return 'old'\n");
    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var patch = try parse(
        allocator,
        "--- a/greeting.lua\n" ++
            "+++ b/greeting.lua\n" ++
            "@@ -1 +1 @@\n" ++
            "-return 'old'\n" ++
            "+return 'new'\n",
    );
    defer patch.deinit(allocator);
    try applyFileAtRoot(allocator, io, root_path, patch.files[0]);

    const content = try tmp.dir.readFileAlloc(io, "greeting.lua", allocator, 4096);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("return 'new'\n", content);
}

test "refuses a symlinked patch target" {
    if (comptime builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, "outside.lua", "return 'old'\n");
    try tmp.dir.symLink(io, "outside.lua", "greeting.lua", .{});
    const root_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_path);

    var patch = try parse(
        allocator,
        "--- a/greeting.lua\n" ++
            "+++ b/greeting.lua\n" ++
            "@@ -1 +1 @@\n" ++
            "-return 'old'\n" ++
            "+return 'new'\n",
    );
    defer patch.deinit(allocator);
    try std.testing.expectError(error.NotLink, applyFileAtRoot(allocator, io, root_path, patch.files[0]));
    const outside = try tmp.dir.readFileAlloc(io, "outside.lua", allocator, 4096);
    defer allocator.free(outside);
    try std.testing.expectEqualStrings("return 'old'\n", outside);
}
