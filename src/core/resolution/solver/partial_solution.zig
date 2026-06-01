const std = @import("std");
const term_mod = @import("term.zig");
const incompatibility_mod = @import("incompatibility.zig");
const assignment_mod = @import("assignment.zig");

pub const PartialSolution = struct {
    assignments: std.ArrayListUnmanaged(assignment_mod.Assignment),
    decision_level: u32 = 0,

    pub fn init() PartialSolution {
        return .{ .assignments = .empty };
    }

    pub fn deinit(self: *PartialSolution, allocator: std.mem.Allocator) void {
        self.assignments.deinit(allocator);
    }

    pub fn findAssignment(self: PartialSolution, name: []const u8) ?assignment_mod.Assignment {
        var i = self.assignments.items.len;
        while (i > 0) {
            i -= 1;
            const as = self.assignments.items[i];
            if (std.mem.eql(u8, as.term.name, name)) return as;
        }
        return null;
    }

    pub fn isSatisfied(self: PartialSolution, term: term_mod.Term) bool {
        if (self.findAssignment(term.name)) |as| {
            return as.term.range.isSubsetOf(term.range);
        }
        return false;
    }

    pub fn isContradicted(self: PartialSolution, term: term_mod.Term) bool {
        if (self.findAssignment(term.name)) |as| {
            return as.term.range.isDisjoint(term.range);
        }
        return false;
    }
};
