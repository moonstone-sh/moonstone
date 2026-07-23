const std = @import("std");

/// Registry aliases and namespace handles share one deliberately narrow grammar.
/// They are safe to use before the `:` target separator and as registry directory
/// identifiers without requiring escaping or normalization.
pub fn isValid(value: []const u8) bool {
    if (value.len == 0 or value.len > 40) return false;
    if (!isAlphanumericLower(value[0])) return false;
    if (value.len > 1 and !isAlphanumericLower(value[value.len - 1])) return false;

    for (value) |char| {
        if (!isAlphanumericLower(char) and char != '-') return false;
    }
    return true;
}

fn isAlphanumericLower(char: u8) bool {
    return std.ascii.isLower(char) or std.ascii.isDigit(char);
}

test "accepts registry-safe names" {
    try std.testing.expect(isValid("acme"));
    try std.testing.expect(isValid("moonstone-sh-acme"));
    try std.testing.expect(isValid("a1"));
}

test "rejects unsafe registry names" {
    try std.testing.expect(!isValid("Acme"));
    try std.testing.expect(!isValid("acme_rocks"));
    try std.testing.expect(!isValid("acme:"));
    try std.testing.expect(!isValid("-acme"));
    try std.testing.expect(!isValid("acme-"));
    try std.testing.expect(!isValid(""));
}
