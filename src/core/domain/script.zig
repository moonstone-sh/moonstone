const std = @import("std");

pub const ScriptDefinition = struct {
    name: []const u8,
    command: []const u8,
    shell: bool = false,
    /// Set when this script was declared as a structured, per-platform step
    /// (e.g. `build.posix.sh = "..."`) and resolved to the variant matching
    /// the host platform at parse time. `null` for a plain `name = "command"`
    /// declaration.
    platform: ?[]const u8 = null,

    pub fn deinit(self: *ScriptDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        if (self.platform) |platform| allocator.free(platform);
    }

    pub fn validate(self: ScriptDefinition) !void {
        if (!isValidName(self.name)) return error.InvalidScriptName;
        if (self.command.len == 0) return error.InvalidScriptCommand;
    }
};

pub fn isValidName(value: []const u8) bool {
    if (value.len == 0 or value.len > 80) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

test "script names remain table-key-safe" {
    try std.testing.expect(isValidName("build"));
    try std.testing.expect(isValidName("build-release_2"));
    try std.testing.expect(!isValidName("build.release"));
}

/// A portable argv grammar, not a shell: quotes group text, and backslashes
/// escape quotes/whitespace only. Other backslashes remain Windows path data.
pub fn commandArgv(allocator: std.mem.Allocator, command: []const u8) ![][]const u8 {
    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |item| allocator.free(item);
        result.deinit(allocator);
    }
    var token = std.ArrayList(u8).empty;
    defer token.deinit(allocator);
    var quote: ?u8 = null;
    var started = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == 0) return error.InvalidScriptCommand;
        if (c == '\\' and i + 1 < command.len and quote != '\'') {
            const next = command[i + 1];
            if (next == '"' or next == '\'' or (quote == null and (next == ' ' or next == '\t'))) {
                try token.append(allocator, next);
                started = true;
                i += 1;
                continue;
            }
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try token.append(allocator, c);
            }
            started = true;
        } else if (c == '"' or c == '\'') {
            quote = c;
            started = true;
        } else if (c == ' ' or c == '\t') {
            if (started) {
                try appendToken(allocator, &result, token.items);
                token.clearRetainingCapacity();
                started = false;
            }
        } else {
            if (std.mem.indexOfScalar(u8, ";&|<>`$\r\n", c) != null) return error.ScriptRequiresExplicitShell;
            try token.append(allocator, c);
            started = true;
        }
    }
    if (quote != null) return error.UnclosedScriptQuote;
    if (started) try appendToken(allocator, &result, token.items);
    if (result.items.len == 0 or result.items[0].len == 0) return error.InvalidScriptCommand;
    for (result.items) |item| {
        if (std.mem.eql(u8, item, "$@") or std.mem.eql(u8, item, "$*") or std.mem.eql(u8, item, "%*")) return error.ScriptArgumentsForwardAutomatically;
    }
    if (std.mem.indexOfScalar(u8, result.items[0], '=') != null) return error.ScriptRequiresExplicitShell;
    return result.toOwnedSlice(allocator);
}

fn appendToken(allocator: std.mem.Allocator, result: *std.ArrayList([]const u8), token: []const u8) !void {
    const owned = try allocator.dupe(u8, token);
    errdefer allocator.free(owned);
    try result.append(allocator, owned);
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |item| allocator.free(item);
    allocator.free(argv);
}

test "portable script argv preserves empty arguments quotes and Windows paths" {
    const a = std.testing.allocator;
    const argv = try commandArgv(a, "lua \"build file.lua\" '' \"a\\\"b\" C:\\tools\\lua.exe");
    defer freeArgv(a, argv);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("build file.lua", argv[1]);
    try std.testing.expectEqualStrings("", argv[2]);
    try std.testing.expectEqualStrings("a\"b", argv[3]);
    try std.testing.expectEqualStrings("C:\\tools\\lua.exe", argv[4]);
    try std.testing.expectError(error.ScriptRequiresExplicitShell, commandArgv(a, "echo hello && echo bye"));
    try std.testing.expectError(error.ScriptArgumentsForwardAutomatically, commandArgv(a, "lua build.lua '$@'"));
    try std.testing.expectError(error.UnclosedScriptQuote, commandArgv(a, "lua 'bad"));
}
