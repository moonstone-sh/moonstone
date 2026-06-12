const std = @import("std");
const semver = @import("../../domain/semver.zig");
const package_provider = @import("../provider/package_provider.zig");
const root = @import("../root.zig");

const term_mod = @import("term.zig");
const incompatibility_mod = @import("incompatibility.zig");
const assignment_mod = @import("assignment.zig");
const report_mod = @import("report.zig");
const partial_solution_mod = @import("partial_solution.zig");

const Term = term_mod.Term;
const Incompatibility = incompatibility_mod.Incompatibility;
const Assignment = assignment_mod.Assignment;

/// The internal state of the PubGrub solver.
pub const Solver = struct {
    allocator: std.mem.Allocator,
    provider: package_provider.PackageProvider,
    options: report_mod.SolverOptions,
    
    arena: std.heap.ArenaAllocator,
    incompatibilities: std.ArrayListUnmanaged(*Incompatibility),
    solution: partial_solution_mod.PartialSolution,

    pub fn init(allocator: std.mem.Allocator, p: package_provider.PackageProvider, options: report_mod.SolverOptions) Solver {
        return .{
            .allocator = allocator,
            .provider = p,
            .options = options,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .incompatibilities = .empty,
            .solution = partial_solution_mod.PartialSolution.init(),
        };
    }

    fn emit(self: Solver, event: report_mod.SolverEvent, data_map: anytype) void {
        if (self.options.on_event) |cb| {
            _ = data_map;
            cb(self.options.on_event_context, event, .null);
        }
    }

    pub fn deinit(self: *Solver) void {
        self.solution.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn solve(self: *Solver, targets: []const Term) !std.StringArrayHashMapUnmanaged(root.ResolveResult) {
        const arena = self.arena.allocator();

        for (targets) |t| {
            var root_terms = try arena.alloc(Term, 1);
            const negated_range = try t.range.complement(arena);
            root_terms[0] = try t.clone(arena);
            root_terms[0].range = negated_range;
            
            const root_inc = try arena.create(Incompatibility);
            root_inc.* = .{
                .terms = root_terms,
                .cause = .root,
            };

            try self.incompatibilities.append(arena, root_inc);
        }


        while (true) {
            const conflict = try self.propagate();
            if (conflict) |c| {
                self.emit(.conflict, .{});
                const backtrack_level = try self.resolveConflict(c);
                if (backtrack_level < 0) {
                    return error.NoSolution;
                }
                self.emit(.backtracking, .{});
                
                while (self.solution.assignments.items.len > 0) {
                    const as = self.solution.assignments.getLast();
                    if (as.level > @as(u32, @intCast(backtrack_level))) {
                        _ = self.solution.assignments.pop().?;
                    } else break;
                }
                self.solution.decision_level = @intCast(backtrack_level);
                continue;
            }

            if (try self.decide()) |next_pkg| {
                _ = next_pkg;
                continue;
            } else {
                // Done! Extract solution.
                var sol = std.StringArrayHashMapUnmanaged(root.ResolveResult).empty;
                errdefer {
                    var sit = sol.iterator();
                    while (sit.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        entry.value_ptr.deinit(self.allocator);
                    }
                    sol.deinit(self.allocator);
                }

                for (self.solution.assignments.items) |as| {
                    if (as.term.range.intervals.len == 1 and as.term.range.intervals[0].min != null and as.term.range.intervals[0].max != null and
                        as.term.range.intervals[0].min.?.compare(as.term.range.intervals[0].max.?) == 0) {
                        
                        const v = as.term.range.intervals[0].min.?;
                        const v_str = try v.toString(self.allocator);
                        defer self.allocator.free(v_str);
                        const req = package_provider.ArtifactRequest{
                            .name = as.term.name,
                            .version = v_str,
                            .resolver = as.term.resolver,
                        };
                        if (try self.provider.getArtifact(req)) |art| {
                            var cloned = try art.clone(self.allocator);
                            errdefer cloned.deinit(self.allocator);
                            try sol.put(self.allocator, try self.allocator.dupe(u8, as.term.name), cloned);
                        } else {
                            return error.ArtifactNotFound;
                        }
                    }
                }
                return sol;
            }
        }
    }

    fn propagate(self: *Solver) !?*Incompatibility {
        const arena = self.arena.allocator();
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < self.incompatibilities.items.len) : (i += 1) {
                const inc = self.incompatibilities.items[i];
                
                var contradicted_term: ?usize = null;
                var satisfied_count: usize = 0;

                for (inc.terms, 0..) |term, j| {
                    if (self.solution.isSatisfied(term)) {
                        satisfied_count += 1;
                    } else if (self.solution.isContradicted(term)) {
                        contradicted_term = j;
                    }
                }
                
                if (satisfied_count == inc.terms.len) {

                    return inc;
                }

                if (satisfied_count == inc.terms.len - 1 and contradicted_term == null) {
                    for (inc.terms) |term| {


                        if (!self.solution.isSatisfied(term)) {
                            const negated_range = try term.range.complement(arena);

                            try self.solution.assignments.append(arena, .{
                                .term = .{
                                    .name = try arena.dupe(u8, term.name),
                                    .range = negated_range,
                                    .registry = if (term.registry) |r| try arena.dupe(u8, r) else null,
                                    .resolver = term.resolver,
                                },
                                .level = self.solution.decision_level,
                                .cause = inc,
                            });
                            self.emit(.propagating, .{});
                            changed = true;
                            break;
                        }
                    }
                }
            }
        }
        return null;
    }


    fn decide(self: *Solver) !?[]const u8 {
        const arena = self.arena.allocator();
        var seen = std.StringArrayHashMapUnmanaged(void).empty;
        defer seen.deinit(arena);

        var i = self.solution.assignments.items.len;
        while (i > 0) {
            i -= 1;
            const as = self.solution.assignments.items[i];
            if (seen.contains(as.term.name)) continue;
            try seen.put(arena, as.term.name, {});

            if (as.term.range.intervals.len != 1 or as.term.range.intervals[0].min == null or as.term.range.intervals[0].max == null or
                as.term.range.intervals[0].min.?.compare(as.term.range.intervals[0].max.?) != 0) {
                
                const versions = try self.provider.getVersions(as.term.name);
                defer arena.free(versions);
                self.emit(.resolving, .{});

                var best: ?semver.Version = null;
                for (versions) |v| {
                    if (as.term.range.contains(v)) {
                        if (best == null or v.compare(best.?) > 0) best = v;
                    }
                }

                if (best) |v| {
                    self.solution.decision_level += 1;
                    const exact_intervals = try arena.alloc(semver.Interval, 1);
                    exact_intervals[0] = .{
                        .min = try v.clone(arena),
                        .max = try v.clone(arena),
                        .include_min = true,
                        .include_max = true,
                    };
                    const exact_range = semver.VersionRange{ .intervals = exact_intervals };

                        try self.solution.assignments.append(arena, .{
                            .term = .{
                                .name = try arena.dupe(u8, as.term.name),
                                .range = exact_range,
                                .registry = if (as.term.registry) |r| try arena.dupe(u8, r) else null,
                                .resolver = as.term.resolver,
                            },
                            .level = self.solution.decision_level,
                        });

                    const deps = try self.provider.getDependencies(as.term.name, v);
                    defer {
                        arena.free(deps);
                    }

                    for (deps) |d| {
                        var terms = try arena.alloc(Term, 2);
                        terms[0] = Term{
                            .name = try arena.dupe(u8, as.term.name),
                            .range = try exact_range.clone(arena),
                            .registry = if (as.term.registry) |r| try arena.dupe(u8, r) else null,
                            .resolver = as.term.resolver,
                        };
                        terms[1] = Term{
                            .name = try arena.dupe(u8, d.name),
                            .range = try d.range.complement(arena),
                            .registry = if (d.registry) |r| try arena.dupe(u8, r) else null,
                            .resolver = d.resolver,
                        };
                        const inc = try arena.create(Incompatibility);
                        inc.* = .{
                            .terms = terms,
                            .cause = .dependency,
                        };
                        try self.incompatibilities.append(arena, inc);
                    }
                    
                    return as.term.name;
                } else {
                    const inc = try arena.create(Incompatibility);
                    var terms = try arena.alloc(Term, 1);
                    terms[0] = Term{
                        .name = try arena.dupe(u8, as.term.name),
                        .range = try as.term.range.clone(arena),
                    };
                    inc.* = .{ .terms = terms, .cause = .no_versions };
                    try self.incompatibilities.append(arena, inc);
                    return error.NoSolution;
                }
            }
        }
        return null;
    }

    fn resolveConflict(self: *Solver, conflict: *Incompatibility) !i32 {
        const arena = self.arena.allocator();
        var current = try conflict.clone(arena);
        
        while (true) {
            var highest_level: u32 = 0;
            var second_highest_level: u32 = 0;
            var term_at_highest_level: ?usize = null;
            var count_at_highest_level: usize = 0;

            for (current.terms, 0..) |term, i| {
                const as = self.solution.findAssignment(term.name) orelse continue;
                if (as.level > highest_level) {
                    second_highest_level = highest_level;
                    highest_level = as.level;
                    term_at_highest_level = i;
                    count_at_highest_level = 1;
                } else if (as.level == highest_level) {
                    count_at_highest_level += 1;
                } else if (as.level > second_highest_level) {
                    second_highest_level = as.level;
                }
            }

            if (highest_level == 0) {
                return -1;
            }
            if (count_at_highest_level == 1) {
                try self.incompatibilities.append(arena, current);
                return @intCast(second_highest_level);
            }

            const as = self.solution.findAssignment(current.terms[term_at_highest_level.?].name).?;
            const cause = as.cause orelse {
                return -1;
            };

            const merged = try self.mergeIncompatibilities(current, cause, current.terms[term_at_highest_level.?].name);
            current = merged;
        }
    }

    fn mergeIncompatibilities(self: *Solver, a: *Incompatibility, b: *Incompatibility, name: []const u8) !*Incompatibility {
        const arena = self.arena.allocator();
        var map = std.StringArrayHashMapUnmanaged(semver.VersionRange).empty;
        defer map.deinit(arena);

        inline for (&.{ a, b }) |inc| {
            for (inc.terms) |t| {
                if (map.get(t.name)) |existing| {
                    const intersection = try existing.intersect(t.range, arena);
                    try map.put(arena, t.name, intersection);
                } else {
                    try map.put(arena, try arena.dupe(u8, t.name), try t.range.clone(arena));
                }
            }
        }
        
        if (map.get(name)) |range| {
            if (range.intervals.len == 1 and range.intervals[0].isAny()) {
                _ = map.swapRemove(name);
            }
        }

        var res_terms = try arena.alloc(Term, map.count());
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            res_terms[i] = Term{
                .name = entry.key_ptr.*,
                .range = entry.value_ptr.*,
            };
            i += 1;
        }

        const res = try arena.create(Incompatibility);
        res.* = .{
            .terms = res_terms,
            .cause = .{ .learned = .{ .conflict = try a.clone(arena), .other = try b.clone(arena) } },
        };
        return res;
    }
};

const MockProvider = struct {
    allocator: std.mem.Allocator,
    versions: std.StringArrayHashMapUnmanaged([]const semver.Version),
    deps: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(semver.Version, []const Term)),

    pub fn init(allocator: std.mem.Allocator) MockProvider {
        return .{
            .allocator = allocator,
            .versions = .empty,
            .deps = .empty,
        };
    }

    pub fn deinit(self: *MockProvider) void {
        var vit = self.versions.iterator();
        while (vit.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.versions.deinit(self.allocator);

        var dit = self.deps.iterator();
        while (dit.next()) |entry| {
            var vit2 = entry.value_ptr.iterator();
            while (vit2.next()) |entry2| {
                for (entry2.value_ptr.*) |t| {
                    var mut_t = t;
                    mut_t.deinit(self.allocator);
                }
                self.allocator.free(entry2.value_ptr.*);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.deps.deinit(self.allocator);
    }

    pub fn get_provider(self: *MockProvider) package_provider.PackageProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .getVersions = getVersions,
                .getDependencies = getDependencies,
                .getArtifact = getArtifact,
            },
        };
    }

    fn getVersions(ctx: *anyopaque, name: []const u8) anyerror![]const semver.Version {
        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        if (self.versions.get(name)) |v| {
            return try self.allocator.dupe(semver.Version, v);
        }
        return error.PackageNotFound;
    }

    fn getDependencies(ctx: *anyopaque, name: []const u8, version: semver.Version) anyerror![]const Term {
        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        if (self.deps.get(name)) |vmap| {
            if (vmap.get(version)) |dt| {
                var res = try self.allocator.alloc(Term, dt.len);
                for (dt, 0..) |t, i| {
                    res[i] = try t.clone(self.allocator);
                }
                return res;
            }
        }
        return &.{};
    }

    fn getArtifact(ctx: *anyopaque, request: package_provider.ArtifactRequest) anyerror!?root.ResolveResult {
        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        const v_str = try self.allocator.dupe(u8, request.version);
        return root.ResolveResult{
            .name = try self.allocator.dupe(u8, request.name),
            .version = v_str,
            .kind = .lib,
            .artifact_hash = try self.allocator.dupe(u8, "mock-hash"),
            .origin = .{ .artifact_hash = try self.allocator.dupe(u8, "mock-hash") },
        };
    }
};

test "simple conflict" {
    const allocator = std.testing.allocator;
    var mp = MockProvider.init(allocator);
    defer mp.deinit();

    const v1 = try semver.Version.parse("1.0.0");
    try mp.versions.put(allocator, "A", blk: {
        var v = try allocator.alloc(semver.Version, 1);
        v[0] = v1;
        break :blk v;
    });

    const b_v1 = try semver.Version.parse("1.0.0");
    const b_v2 = try semver.Version.parse("2.0.0");
    try mp.versions.put(allocator, "B", blk: {
        var v = try allocator.alloc(semver.Version, 2);
        v[0] = b_v1;
        v[1] = b_v2;
        break :blk v;
    });

    var a_deps = std.AutoArrayHashMapUnmanaged(semver.Version, []const Term).empty;
    try a_deps.put(allocator, v1, blk: {
        var t = try allocator.alloc(Term, 2);
        t[0] = Term{ .name = try allocator.dupe(u8, "B"), .range = try semver.VersionRange.parse(allocator, "1.0.0") };
        t[1] = Term{ .name = try allocator.dupe(u8, "B"), .range = try semver.VersionRange.parse(allocator, "2.0.0") };
        break :blk t;
    });
    try mp.deps.put(allocator, "A", a_deps);

    var solver = Solver.init(allocator, mp.get_provider(), .{});
    defer solver.deinit();

    const range = try semver.VersionRange.parse(allocator, "1.0.0");
    defer range.deinit(allocator);

    const res = solver.solve(&.{Term{ .name = "A", .range = range }});
    try std.testing.expectError(error.NoSolution, res);
}
