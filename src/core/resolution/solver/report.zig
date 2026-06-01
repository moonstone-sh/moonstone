const std = @import("std");
const incompatibility_mod = @import("incompatibility.zig");

pub const SolverEvent = enum {
    resolving,      // { "package": "..." }
    propagating,    // { "package": "...", "range": "..." }
    conflict,       // { "learned": "..." }
    backtracking,   // { "level": 1 }
};

pub const SolverCallback = *const fn (context: ?*anyopaque, event: SolverEvent, data: std.json.Value) void;

pub const SolverOptions = struct {
    on_event: ?SolverCallback = null,
    on_event_context: ?*anyopaque = null,
};

pub fn explain(writer: anytype, inc: *incompatibility_mod.Incompatibility, allocator: std.mem.Allocator) anyerror!void {
    switch (inc.cause) {
        .root => {
            try writer.print("the root project depends on {s} ({})", .{ inc.terms[0].name, inc.terms[0].range });
        },
        .dependency => {
            const dep_range = try inc.terms[1].range.complement(allocator);
            defer dep_range.deinit(allocator);
            try writer.print("{s} ({}) depends on {s} ({})", .{ inc.terms[0].name, inc.terms[0].range, inc.terms[1].name, dep_range });
        },
        .no_versions => {
            try writer.print("no versions of {s} match ({})", .{ inc.terms[0].name, inc.terms[0].range });
        },
        .learned => |l| {
            try writer.print("conflict: ", .{});
            try explain(writer, l.conflict, allocator);
            try writer.print(" AND ", .{});
            try explain(writer, l.other, allocator);
        },
    }
}
