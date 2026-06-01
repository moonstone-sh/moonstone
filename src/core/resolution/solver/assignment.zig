const std = @import("std");
const term_mod = @import("term.zig");
const incompatibility_mod = @import("incompatibility.zig");

/// An assignment is a decision or derivation for a package.
pub const Assignment = struct {
    term: term_mod.Term,
    level: u32,
    cause: ?*incompatibility_mod.Incompatibility = null,
};
