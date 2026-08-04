const std = @import("std");
const manifest_mod = @import("../domain/manifest.zig");
const script_mod = @import("../domain/script.zig");

const Line = struct { start: usize, end: usize };

const ScriptsSection = struct {
    header_index: usize,
    section_end: usize,
    body_start: usize,
    body_end: usize,
};

const Block = struct {
    name: []const u8,
    start: usize,
    entry_start: usize,
    end: usize,
};

pub const Policy = manifest_mod.MoonstoneToml.Tidy;

pub const UnattachedComment = struct {
    line: usize,
};

/// Reorders `[scripts]` entries lexicographically without reconstructing the
/// manifest. A consecutive run of comment-only lines directly above an entry
/// belongs to that entry and moves with it. Floating source gaps remain in
/// their original table slot and can be reported with `unattachedComments`.
pub fn tidyScripts(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const lines = try indexLines(allocator, source);
    defer allocator.free(lines);
    const policy = try parsePolicy(source, lines);
    if (policy.scripts == .preserve) return allocator.dupe(u8, source);
    return tidyScriptsWithLines(allocator, source, lines);
}

fn tidyScriptsAfterMutation(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const lines = try indexLines(allocator, source);
    defer allocator.free(lines);
    const policy = try parsePolicy(source, lines);
    if (!policy.on_script_mutation or policy.scripts == .preserve) return allocator.dupe(u8, source);
    return tidyScriptsWithLines(allocator, source, lines);
}

fn tidyScriptsWithLines(allocator: std.mem.Allocator, source: []const u8, lines: []const Line) ![]u8 {
    const section = findScriptsSection(source, lines) orelse return allocator.dupe(u8, source);

    const blocks = try collectBlocks(allocator, source, lines, section);
    defer allocator.free(blocks);
    if (blocks.len < 2) return allocator.dupe(u8, source);

    const sorted = try allocator.dupe(Block, blocks);
    defer allocator.free(sorted);
    std.mem.sort(Block, sorted, {}, struct {
        fn lessThan(_: void, left: Block, right: Block) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);

    var unchanged = true;
    for (blocks, sorted) |left, right| if (!std.mem.eql(u8, left.name, right.name)) {
        unchanged = false;
        break;
    };
    if (unchanged) return allocator.dupe(u8, source);

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.writeAll(source[0..section.body_start]);
    try output.writer.writeAll(source[section.body_start..blocks[0].start]);
    for (sorted, 0..) |block, index| {
        try output.writer.writeAll(source[block.start..block.end]);
        const gap_start = blocks[index].end;
        const gap_end = if (index + 1 < blocks.len) blocks[index + 1].start else section.body_end;
        try output.writer.writeAll(source[gap_start..gap_end]);
    }
    try output.writer.writeAll(source[section.body_end..]);
    try output.writer.flush();
    return allocator.dupe(u8, output.writer.buffer[0..output.writer.end]);
}

/// Returns comment-only source lines that have no immediately adjacent script
/// subject. Tied leading comments are deliberately excluded from this list.
pub fn unattachedComments(allocator: std.mem.Allocator, source: []const u8) ![]UnattachedComment {
    const lines = try indexLines(allocator, source);
    defer allocator.free(lines);
    const section = findScriptsSection(source, lines) orelse return allocator.alloc(UnattachedComment, 0);
    const blocks = try collectBlocks(allocator, source, lines, section);
    defer allocator.free(blocks);
    if (blocks.len == 0) return allocator.alloc(UnattachedComment, 0);

    var diagnostics = std.ArrayList(UnattachedComment).empty;
    defer diagnostics.deinit(allocator);
    try collectCommentsInRange(allocator, &diagnostics, source, lines, section.body_start, blocks[0].start);
    for (blocks, 0..) |block, index| {
        const gap_end = if (index + 1 < blocks.len) blocks[index + 1].start else section.body_end;
        try collectCommentsInRange(allocator, &diagnostics, source, lines, block.end, gap_end);
    }
    return diagnostics.toOwnedSlice(allocator);
}

/// Replaces or adds one script without serializing unrelated manifest domains.
/// The updated `[scripts]` section is then put in its canonical lexical order.
pub fn setScript(allocator: std.mem.Allocator, source: []const u8, name: []const u8, command: []const u8) ![]u8 {
    if (!script_mod.isValidName(name)) return error.InvalidScriptName;
    if (command.len == 0) return error.InvalidScriptCommand;

    const lines = try indexLines(allocator, source);
    defer allocator.free(lines);
    const section = findScriptsSection(source, lines);
    if (section == null) return appendScriptsSection(allocator, source, name, command);

    const blocks = try collectBlocks(allocator, source, lines, section.?);
    defer allocator.free(blocks);
    for (blocks) |block| if (std.mem.eql(u8, block.name, name)) {
        const replacement = try renderAssignment(allocator, name, command, inlineComment(source[block.entry_start..block.end]));
        defer allocator.free(replacement);
        const edited = try replaceRange(allocator, source, block.entry_start, block.end, replacement);
        defer allocator.free(edited);
        return tidyScriptsAfterMutation(allocator, edited);
    };

    const assignment = try renderAssignment(allocator, name, command, null);
    defer allocator.free(assignment);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.writeAll(source[0..section.?.body_end]);
    if (section.?.body_end > section.?.body_start and source[section.?.body_end - 1] != '\n') try output.writer.writeByte('\n');
    try output.writer.writeAll(assignment);
    try output.writer.writeByte('\n');
    try output.writer.writeAll(source[section.?.body_end..]);
    try output.writer.flush();

    const edited = try allocator.dupe(u8, output.writer.buffer[0..output.writer.end]);
    defer allocator.free(edited);
    return tidyScriptsAfterMutation(allocator, edited);
}

/// Removes an entry and its directly attached leading comment block. Detached
/// section notes and all unrelated manifest content remain untouched.
pub fn removeScript(allocator: std.mem.Allocator, source: []const u8, name: []const u8) ![]u8 {
    const lines = try indexLines(allocator, source);
    defer allocator.free(lines);
    const section = findScriptsSection(source, lines) orelse return error.ScriptNotFound;
    const blocks = try collectBlocks(allocator, source, lines, section);
    defer allocator.free(blocks);
    for (blocks) |block| if (std.mem.eql(u8, block.name, name)) {
        const edited = try replaceRange(allocator, source, block.start, block.end, "");
        defer allocator.free(edited);
        return tidyScriptsAfterMutation(allocator, edited);
    };
    return error.ScriptNotFound;
}

fn appendScriptsSection(allocator: std.mem.Allocator, source: []const u8, name: []const u8, command: []const u8) ![]u8 {
    const assignment = try renderAssignment(allocator, name, command, null);
    defer allocator.free(assignment);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.writeAll(source);
    if (source.len > 0 and source[source.len - 1] != '\n') try output.writer.writeByte('\n');
    if (source.len > 0) try output.writer.writeByte('\n');
    try output.writer.writeAll("[scripts]\n");
    try output.writer.writeAll(assignment);
    try output.writer.writeByte('\n');
    try output.writer.flush();
    return allocator.dupe(u8, output.writer.buffer[0..output.writer.end]);
}

fn renderAssignment(allocator: std.mem.Allocator, name: []const u8, command: []const u8, trailing: ?[]const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.print("{s} = ", .{name});
    try writeTomlCommand(&output.writer, command);
    if (trailing) |comment| {
        try output.writer.writeByte(' ');
        try output.writer.writeAll(std.mem.trimStart(u8, comment, " \t"));
    }
    try output.writer.flush();
    return allocator.dupe(u8, output.writer.buffer[0..output.writer.end]);
}

fn writeTomlCommand(writer: *std.Io.Writer, value: []const u8) !void {
    if (std.mem.indexOfScalar(u8, value, '\n') != null and !std.mem.startsWith(u8, value, "\n") and std.mem.indexOf(u8, value, "\"\"\"") == null) {
        try writer.writeAll("\"\"\"\n");
        try writer.writeAll(value);
        if (!std.mem.endsWith(u8, value, "\n")) try writer.writeByte('\n');
        return writer.writeAll("\"\"\"");
    }
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

fn replaceRange(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, replacement: []const u8) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.writeAll(source[0..start]);
    try output.writer.writeAll(replacement);
    try output.writer.writeAll(source[end..]);
    try output.writer.flush();
    return allocator.dupe(u8, output.writer.buffer[0..output.writer.end]);
}

fn collectBlocks(allocator: std.mem.Allocator, source: []const u8, lines: []const Line, section: ScriptsSection) ![]Block {
    var blocks = std.ArrayList(Block).empty;
    defer blocks.deinit(allocator);
    var line_index = section.header_index + 1;
    while (line_index < section.section_end) {
        const line = lines[line_index];
        const name = scriptName(lineSlice(source, line)) orelse {
            line_index += 1;
            continue;
        };
        const end = try assignmentEnd(source, line);
        var start = line.start;
        var comment_index = line_index;
        while (comment_index > section.header_index + 1 and isCommentLine(lineSlice(source, lines[comment_index - 1]))) : (comment_index -= 1) {
            start = lines[comment_index - 1].start;
        }
        try blocks.append(allocator, .{ .name = name, .start = start, .entry_start = line.start, .end = end });
        while (line_index < section.section_end and lines[line_index].start < end) : (line_index += 1) {}
    }
    return blocks.toOwnedSlice(allocator);
}

fn assignmentEnd(source: []const u8, line: Line) !usize {
    const raw_line = source[line.start..line.end];
    const equals = std.mem.indexOfScalar(u8, raw_line, '=') orelse return error.InvalidScriptCommand;
    const value = std.mem.trimStart(u8, raw_line[equals + 1 ..], " \t");
    if (!(std.mem.startsWith(u8, value, "\"\"\"") or std.mem.startsWith(u8, value, "'''"))) return line.end;
    const delimiter = value[0..3];
    const first = line.start + equals + 1 + (raw_line[equals + 1 ..].len - value.len);
    const closing = std.mem.indexOfPos(u8, source, first + 3, delimiter) orelse return error.InvalidScriptCommand;
    const after = closing + delimiter.len;
    return if (std.mem.indexOfScalarPos(u8, source, after, '\n')) |newline| newline + 1 else source.len;
}

fn inlineComment(entry: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfScalar(u8, entry, '\n') orelse entry.len;
    const line = entry[0..line_end];
    var quote: ?u8 = null;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (quote) |active| {
            if (active == '"' and escaped) {
                escaped = false;
                continue;
            }
            if (active == '"' and byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == active) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '#') return line[index..];
    }
    return null;
}

fn indexLines(allocator: std.mem.Allocator, source: []const u8) ![]Line {
    var lines = std.ArrayList(Line).empty;
    var start: usize = 0;
    for (source, 0..) |byte, index| if (byte == '\n') {
        try lines.append(allocator, .{ .start = start, .end = index + 1 });
        start = index + 1;
    };
    if (start < source.len) try lines.append(allocator, .{ .start = start, .end = source.len });
    return lines.toOwnedSlice(allocator);
}

fn collectCommentsInRange(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(UnattachedComment),
    source: []const u8,
    lines: []const Line,
    start: usize,
    end: usize,
) !void {
    for (lines, 0..) |line, index| {
        if (line.start < start or line.start >= end) continue;
        if (isCommentLine(lineSlice(source, line))) try diagnostics.append(allocator, .{ .line = index + 1 });
    }
}

fn findScriptsSection(source: []const u8, lines: []const Line) ?ScriptsSection {
    for (lines, 0..) |line, index| if (std.mem.eql(u8, std.mem.trim(u8, lineSlice(source, line), " \t"), "[scripts]")) {
        const section_end = findSectionEnd(source, lines, index + 1);
        return .{
            .header_index = index,
            .section_end = section_end,
            .body_start = line.end,
            .body_end = if (section_end < lines.len) lines[section_end].start else source.len,
        };
    };
    return null;
}

fn parsePolicy(source: []const u8, lines: []const Line) !Policy {
    var policy = Policy{};
    var active = false;
    for (lines) |line| {
        const trimmed = std.mem.trim(u8, lineSlice(source, line), " \t");
        if (trimmed.len > 1 and trimmed[0] == '[') {
            active = std.mem.eql(u8, trimmed, "[manifest.tidy]");
            continue;
        }
        if (!active or trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..equals], " \t");
        const value_with_comment = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");
        const value = if (inlineComment(value_with_comment)) |comment|
            std.mem.trim(u8, value_with_comment[0 .. value_with_comment.len - comment.len], " \t")
        else
            value_with_comment;
        if (std.mem.eql(u8, key, "scripts")) {
            const raw = tomlString(value) orelse return error.InvalidManifestTidyPolicy;
            policy.scripts = manifest_mod.MoonstoneToml.TidyScriptOrder.fromString(raw) orelse return error.InvalidManifestTidyPolicy;
        } else if (std.mem.eql(u8, key, "on_script_mutation")) {
            if (std.mem.eql(u8, value, "true")) {
                policy.on_script_mutation = true;
            } else if (std.mem.eql(u8, value, "false")) {
                policy.on_script_mutation = false;
            } else return error.InvalidManifestTidyPolicy;
        }
    }
    return policy;
}

fn tomlString(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn findSectionEnd(source: []const u8, lines: []const Line, start: usize) usize {
    for (lines[start..], start..) |line, index| {
        const trimmed = std.mem.trim(u8, lineSlice(source, line), " \t");
        if (trimmed.len > 1 and trimmed[0] == '[') return index;
    }
    return lines.len;
}

fn lineSlice(source: []const u8, line: Line) []const u8 {
    return std.mem.trim(u8, source[line.start..line.end], "\r\n");
}

fn isCommentLine(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "#");
}

fn scriptName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) return null;
    const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const name = std.mem.trim(u8, trimmed[0..equals], " \t");
    return if (script_mod.isValidName(name)) name else null;
}

test "tidy scripts moves consecutive leading comments with their entry" {
    const source =
        "[scripts]\n" ++
        "# Zebra command.\n" ++
        "# It belongs to zebra.\n" ++
        "zebra = \"z\" # tail\n" ++
        "\n" ++
        "# Alpha command.\n" ++
        "alpha = \"a\"\n";
    const actual = try tidyScripts(std.testing.allocator, source);
    defer std.testing.allocator.free(actual);
    const expected =
        "[scripts]\n" ++
        "# Alpha command.\n" ++
        "alpha = \"a\"\n" ++
        "# Zebra command.\n" ++
        "# It belongs to zebra.\n" ++
        "zebra = \"z\" # tail\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, actual);
}

test "set script preserves its tied comments and canonicalizes multiline commands" {
    const source =
        "[scripts]\n" ++
        "# Zebra stays attached.\n" ++
        "zebra = \"old\" # retained\n" ++
        "alpha = \"alpha\"\n";
    const actual = try setScript(std.testing.allocator, source, "zebra", "echo one\necho two");
    defer std.testing.allocator.free(actual);
    const expected =
        "[scripts]\n" ++
        "alpha = \"alpha\"\n" ++
        "# Zebra stays attached.\n" ++
        "zebra = \"\"\"\n" ++
        "echo one\n" ++
        "echo two\n" ++
        "\"\"\" # retained\n";
    try std.testing.expectEqualStrings(expected, actual);
}

test "remove script removes its directly attached comments only" {
    const source =
        "[scripts]\n" ++
        "# Section note.\n" ++
        "\n" ++
        "# Alpha note.\n" ++
        "alpha = \"a\"\n" ++
        "zebra = \"z\"\n";
    const actual = try removeScript(std.testing.allocator, source, "alpha");
    defer std.testing.allocator.free(actual);
    const expected =
        "[scripts]\n" ++
        "# Section note.\n" ++
        "\n" ++
        "zebra = \"z\"\n";
    try std.testing.expectEqualStrings(expected, actual);
}

test "tidy anchors floating comments and reports them" {
    const source =
        "[scripts]\n" ++
        "zebra = \"z\"\n" ++
        "\n" ++
        "# Shared development note.\n" ++
        "\n" ++
        "alpha = \"a\"\n";
    const actual = try tidyScripts(std.testing.allocator, source);
    defer std.testing.allocator.free(actual);
    const expected =
        "[scripts]\n" ++
        "alpha = \"a\"\n" ++
        "\n" ++
        "# Shared development note.\n" ++
        "\n" ++
        "zebra = \"z\"\n";
    try std.testing.expectEqualStrings(expected, actual);

    const diagnostics = try unattachedComments(std.testing.allocator, source);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqual(@as(usize, 4), diagnostics[0].line);
}

test "script tidy policy can preserve author ordering or disable automatic tidy" {
    const manual_source =
        "[manifest.tidy]\n" ++
        "scripts = \"preserve\" # keep author order\n" ++
        "\n" ++
        "[scripts]\n" ++
        "zebra = \"z\"\n" ++
        "alpha = \"a\"\n";
    const manually_tidied = try tidyScripts(std.testing.allocator, manual_source);
    defer std.testing.allocator.free(manually_tidied);
    try std.testing.expectEqualStrings(manual_source, manually_tidied);

    const mutation_source =
        "[manifest.tidy]\n" ++
        "on_script_mutation = false\n" ++
        "\n" ++
        "[scripts]\n" ++
        "zebra = \"z\"\n";
    const updated = try setScript(std.testing.allocator, mutation_source, "alpha", "a");
    defer std.testing.allocator.free(updated);
    const expected =
        "[manifest.tidy]\n" ++
        "on_script_mutation = false\n" ++
        "\n" ++
        "[scripts]\n" ++
        "zebra = \"z\"\n" ++
        "alpha = \"a\"\n";
    try std.testing.expectEqualStrings(expected, updated);
}
