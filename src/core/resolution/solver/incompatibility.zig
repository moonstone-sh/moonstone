const std = @import("std");
const term_mod = @import("term.zig");
const Term = term_mod.Term;

/// An incompatibility represents a set of terms that cannot all be true at once.
pub const Incompatibility = struct {
    terms: []const Term,
    cause: Cause,

    pub const Cause = union(enum) {
        root,           // Root project dependency
        dependency,     // Package A depends on Package B
        no_versions,    // No versions of a package exist
        learned: struct {
            conflict: *Incompatibility,
            other: *Incompatibility,
        },
    };

    pub fn clone(self: Incompatibility, allocator: std.mem.Allocator) !*Incompatibility {
        var new_terms = try allocator.alloc(Term, self.terms.len);
        for (self.terms, 0..) |t, i| {
            new_terms[i] = try t.clone(allocator);
        }
        const res = try allocator.create(Incompatibility);
        res.* = .{
            .terms = new_terms,
            .cause = self.cause,
        };
        return res;
    }
};
