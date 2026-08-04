const std = @import("std");

pub const ScriptDefinition = struct {
    name: []const u8,
    command: []const u8,

    pub fn deinit(self: *ScriptDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
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
