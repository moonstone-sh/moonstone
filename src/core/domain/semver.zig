const std = @import("std");

/// Represents a Semantic Version (SemVer 2.0.0).
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    pre: []const u8 = "",
    build: []const u8 = "",
    precision: u8 = 3,

    pub fn parse(text: []const u8) !Version {
        var it = std.mem.splitScalar(u8, text, '+');
        const main_pre = it.next() orelse return error.InvalidVersion;
        var build = it.next() orelse "";

        var pre_it = std.mem.splitScalar(u8, main_pre, '-');
        const main = pre_it.next() orelse return error.InvalidVersion;
        var pre = pre_it.next() orelse "";

        if (pre.len > 0 and build.len == 0) {
            var numeric_revision = true;
            for (pre) |c| {
                if (c < '0' or c > '9') {
                    numeric_revision = false;
                    break;
                }
            }
            if (numeric_revision) {
                build = pre;
                pre = "";
            }
        }

        var main_it = std.mem.splitScalar(u8, main, '.');
        const major_str = main_it.next() orelse return error.InvalidVersion;
        
        var precision: u8 = 1;
        const minor_str = if (main_it.next()) |s| blk: {
            precision = 2;
            break :blk s;
        } else "0";
        const patch_str = if (main_it.next()) |s| blk: {
            precision = 3;
            break :blk s;
        } else "0";

        return Version{
            .major = try std.fmt.parseInt(u64, major_str, 10),
            .minor = try std.fmt.parseInt(u64, minor_str, 10),
            .patch = try std.fmt.parseInt(u64, patch_str, 10),
            .pre = pre,
            .build = build,
            .precision = precision,
        };
    }

    pub fn parseCloned(allocator: std.mem.Allocator, text: []const u8) !Version {
        var v = try parse(text);
        if (v.pre.len > 0) v.pre = try allocator.dupe(u8, v.pre);
        if (v.build.len > 0) v.build = try allocator.dupe(u8, v.build);
        return v;
    }

    pub fn compare(self: Version, other: Version) i8 {
        if (self.major != other.major) return if (self.major > other.major) 1 else -1;
        if (self.minor != other.minor) return if (self.minor > other.minor) 1 else -1;
        if (self.patch != other.patch) return if (self.patch > other.patch) 1 else -1;

        // Pre-release comparison
        if (self.pre.len == 0 and other.pre.len > 0) return 1;
        if (self.pre.len > 0 and other.pre.len == 0) return -1;
        if (self.pre.len > 0 and other.pre.len > 0) {
            // Very simplified pre-release comparison (lexicographical)
            return switch (std.mem.order(u8, self.pre, other.pre)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }

        return 0;
    }

    pub fn format(
        self: Version,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d}", .{self.major});
        if (self.precision >= 2) try writer.print(".{d}", .{self.minor});
        if (self.precision >= 3) try writer.print(".{d}", .{self.patch});
        if (self.pre.len > 0) try writer.print("-{s}", .{self.pre});
        if (self.build.len > 0) try writer.print("+{s}", .{self.build});
    }

    pub fn clone(self: Version, allocator: std.mem.Allocator) !Version {
        return Version{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (self.pre.len > 0) try allocator.dupe(u8, self.pre) else "",
            .build = if (self.build.len > 0) try allocator.dupe(u8, self.build) else "",
            .precision = self.precision,
        };
    }

    pub fn deinit(self: Version, allocator: std.mem.Allocator) void {
        if (self.pre.len > 0) allocator.free(self.pre);
        if (self.build.len > 0) allocator.free(self.build);
    }

    pub fn toString(self: Version, allocator: std.mem.Allocator) ![]const u8 {
        if (self.precision == 1) {
            return std.fmt.allocPrint(allocator, "{d}{s}{s}{s}{s}", .{
                self.major,
                if (self.pre.len > 0) "-" else "", self.pre,
                if (self.build.len > 0) "+" else "", self.build,
            });
        } else if (self.precision == 2) {
            return std.fmt.allocPrint(allocator, "{d}.{d}{s}{s}{s}{s}", .{
                self.major, self.minor,
                if (self.pre.len > 0) "-" else "", self.pre,
                if (self.build.len > 0) "+" else "", self.build,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}{s}{s}{s}{s}", .{
                self.major, self.minor, self.patch,
                if (self.pre.len > 0) "-" else "", self.pre,
                if (self.build.len > 0) "+" else "", self.build,
            });
        }
    }
};

/// Represents a single interval of versions.
pub const Interval = struct {
    min: ?Version = null,
    max: ?Version = null,
    include_min: bool = true,
    include_max: bool = false,

    pub fn clone(self: Interval, allocator: std.mem.Allocator) !Interval {
        return Interval{
            .min = if (self.min) |m| try m.clone(allocator) else null,
            .max = if (self.max) |m| try m.clone(allocator) else null,
            .include_min = self.include_min,
            .include_max = self.include_max,
        };
    }

    pub fn deinit(self: *Interval, allocator: std.mem.Allocator) void {
        if (self.min) |*m| m.deinit(allocator);
        if (self.max) |*m| m.deinit(allocator);
    }

    pub fn isAny(self: Interval) bool {
        return self.min == null and self.max == null;
    }

    pub fn contains(self: Interval, v: Version) bool {
        if (self.min) |min| {
            const cmp = v.compare(min);
            if (cmp < 0) return false;
            if (cmp == 0 and !self.include_min) return false;
        }
        if (self.max) |max| {
            const cmp = v.compare(max);
            if (cmp > 0) return false;
            if (cmp == 0 and !self.include_max) return false;
        }
        return true;
    }

    /// Returns the intersection of two intervals (shallow copy).
    pub fn intersect(self: Interval, other: Interval) ?Interval {
        var res = Interval{};

        // Min
        if (self.min == null) {
            res.min = other.min;
            res.include_min = other.include_min;
        } else if (other.min == null) {
            res.min = self.min;
            res.include_min = self.include_min;
        } else {
            const cmp = self.min.?.compare(other.min.?);
            if (cmp > 0) {
                res.min = self.min;
                res.include_min = self.include_min;
            } else if (cmp < 0) {
                res.min = other.min;
                res.include_min = other.include_min;
            } else {
                res.min = self.min;
                res.include_min = self.include_min and other.include_min;
            }
        }

        // Max
        if (self.max == null) {
            res.max = other.max;
            res.include_max = other.include_max;
        } else if (other.max == null) {
            res.max = self.max;
            res.include_max = self.include_max;
        } else {
            const cmp = self.max.?.compare(other.max.?);
            if (cmp < 0) {
                res.max = self.max;
                res.include_max = self.include_max;
            } else if (cmp > 0) {
                res.max = other.max;
                res.include_max = other.include_max;
            } else {
                res.max = self.max;
                res.include_max = self.include_max and other.include_max;
            }
        }

        // Validate
        if (res.min != null and res.max != null) {
            const cmp = res.min.?.compare(res.max.?);
            if (cmp > 0) return null;
            if (cmp == 0 and (!res.include_min or !res.include_max)) return null;
        }

        return res;
    }

    /// Returns the intersection of two intervals (cloned).
    pub fn intersectClone(self: Interval, other: Interval, allocator: std.mem.Allocator) !?Interval {
        var res = try self.clone(allocator);
        errdefer res.deinit(allocator);
        
        const other_clone = try other.clone(allocator);
        defer { var mut_o = other_clone; mut_o.deinit(allocator); }
        
        // This is inefficient but safe for now.
        // Better: implement cloning directly in intersection logic.
        const shallow = self.intersect(other) orelse return null;
        return try shallow.clone(allocator);
    }

    pub fn isSubsetOf(self: Interval, other: Interval) bool {
        // self is subset of other if [self.min, self.max] is within [other.min, other.max]
        if (other.min) |omin| {
            if (self.min) |smin| {
                const cmp = smin.compare(omin);
                if (cmp < 0) return false;
                if (cmp == 0 and !self.include_min and other.include_min) {} // ok
                if (cmp == 0 and self.include_min and !other.include_min) return false;
            } else return false; // self.min is -inf, other.min is not
        }
        if (other.max) |omax| {
            if (self.max) |smax| {
                const cmp = smax.compare(omax);
                if (cmp > 0) return false;
                if (cmp == 0 and self.include_max and !other.include_max) return false;
            } else return false; // self.max is +inf, other.max is not
        }
        return true;
    }

    pub fn isDisjoint(self: Interval, other: Interval) bool {
        return self.intersect(other) == null;
    }
    };

    /// Represents a set of allowed versions (disjoint intervals).
    pub const VersionRange = struct {
        intervals: []const Interval,

        pub fn any(allocator: std.mem.Allocator) !VersionRange {
            var list = try allocator.alloc(Interval, 1);
            list[0] = Interval{};
            return VersionRange{ .intervals = list };
        }

        pub fn clone(self: VersionRange, allocator: std.mem.Allocator) !VersionRange {
            const list = try allocator.alloc(Interval, self.intervals.len);
            for (self.intervals, 0..) |interval, i| {
                list[i] = try interval.clone(allocator);
            }
            return VersionRange{ .intervals = list };
        }

        pub fn deinit(self: VersionRange, allocator: std.mem.Allocator) void {
            for (self.intervals) |interval| {
                var mut_i = interval;
                mut_i.deinit(allocator);
            }
            allocator.free(self.intervals);
        }
        pub fn parse(allocator: std.mem.Allocator, text: []const u8) !VersionRange {
            if (std.mem.eql(u8, text, "*") or text.len == 0) return try any(allocator);
            var list = std.ArrayList(Interval).empty;
            errdefer list.deinit(allocator);
            if (std.mem.startsWith(u8, text, "^")) {
                const v = try Version.parseCloned(allocator, text[1..]);
                const next_major = Version{ .major = v.major + 1, .minor = 0, .patch = 0 };
                try list.append(allocator, .{ .min = v, .max = next_major });
            } else if (std.mem.startsWith(u8, text, "~")) {
                const v = try Version.parseCloned(allocator, text[1..]);
                const next_minor = Version{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
                try list.append(allocator, .{ .min = v, .max = next_minor });
            } else if (std.mem.indexOf(u8, text, " ") != null or std.mem.indexOf(u8, text, ">") != null or std.mem.indexOf(u8, text, "<") != null) {
                var it = std.mem.tokenizeAny(u8, text, " ,");
                var current = Interval{};
                while (it.next()) |token| {
                    if (std.mem.eql(u8, token, ">=")) {
                        current.min = try Version.parseCloned(allocator, it.next() orelse return error.InvalidRange);
                        current.include_min = true;
                    } else if (std.mem.eql(u8, token, ">")) {
                        current.min = try Version.parseCloned(allocator, it.next() orelse return error.InvalidRange);
                        current.include_min = false;
                    } else if (std.mem.eql(u8, token, "<=")) {
                        current.max = try Version.parseCloned(allocator, it.next() orelse return error.InvalidRange);
                        current.include_max = true;
                    } else if (std.mem.eql(u8, token, "<")) {
                        current.max = try Version.parseCloned(allocator, it.next() orelse return error.InvalidRange);
                        current.include_max = false;
                    } else {
                        const v = try Version.parseCloned(allocator, token);
                        current.min = v;
                        current.max = v;
                        current.include_min = true;
                        current.include_max = true;
                    }
                }
                try list.append(allocator, current);
            } else {
                const v = try Version.parseCloned(allocator, text);
                if (v.precision == 3) {
                    try list.append(allocator, .{ .min = v, .max = v, .include_min = true, .include_max = true });
                } else if (v.precision == 2) {
                    const next_minor = Version{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
                    try list.append(allocator, .{ .min = v, .max = next_minor, .include_min = true, .include_max = false });
                } else {
                    const next_major = Version{ .major = v.major + 1, .minor = 0, .patch = 0 };
                    try list.append(allocator, .{ .min = v, .max = next_major, .include_min = true, .include_max = false });
                }
            }

            return VersionRange{ .intervals = try list.toOwnedSlice(allocator) };
        }

    pub fn contains(self: VersionRange, v: Version) bool {
        for (self.intervals) |i| {
            if (i.contains(v)) return true;
        }
        return false;
    }

    pub fn intersect(self: VersionRange, other: VersionRange, allocator: std.mem.Allocator) !VersionRange {
        var list = std.ArrayList(Interval).empty;
        errdefer {
            for (list.items) |*i| i.deinit(allocator);
            list.deinit(allocator);
        }

        for (self.intervals) |a| {
            for (other.intervals) |b| {
                if (try a.intersectClone(b, allocator)) |res| {
                    try list.append(allocator, res);
                }
            }
        }

        return VersionRange{ .intervals = try list.toOwnedSlice(allocator) };
    }

    pub fn isSubsetOf(self: VersionRange, other: VersionRange) bool {
        // self is subset of other if every interval in self is a subset of SOME interval in other
        // This is simplified but mostly correct for disjoint intervals
        for (self.intervals) |si| {
            var found = false;
            for (other.intervals) |oi| {
                if (si.isSubsetOf(oi)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    pub fn isDisjoint(self: VersionRange, other: VersionRange) bool {
        for (self.intervals) |si| {
            for (other.intervals) |oi| {
                if (!si.isDisjoint(oi)) return false;
            }
        }
        return true;
    }

    pub fn isEmpty(self: VersionRange) bool {
        return self.intervals.len == 0;
    }

    pub fn unionRanges(self: VersionRange, other: VersionRange, allocator: std.mem.Allocator) !VersionRange {
        var list = std.ArrayList(Interval).empty;
        errdefer list.deinit(allocator);

        try list.appendSlice(allocator, self.intervals);
        try list.appendSlice(allocator, other.intervals);

        // This is a naive union (just concatenates).
        // Ideally we would merge overlapping intervals.
        return VersionRange{ .intervals = try list.toOwnedSlice(allocator) };
    }

    pub fn complement(self: VersionRange, allocator: std.mem.Allocator) !VersionRange {
        if (self.isEmpty()) return try any(allocator);

        var list = std.ArrayList(Interval).empty;
        errdefer {
            for (list.items) |*i| i.deinit(allocator);
            list.deinit(allocator);
        }

        var current_v = Version{ .major = 0, .minor = 0, .patch = 0 };
        var current_include = true;

        for (self.intervals) |i| {
            if (i.min) |min| {
                const cmp = current_v.compare(min);
                if (cmp < 0 or (cmp == 0 and current_include and !i.include_min)) {
                    // Gap exists
                    try list.append(allocator, .{
                        .min = try current_v.clone(allocator),
                        .include_min = current_include,
                        .max = try min.clone(allocator),
                        .include_max = !i.include_min,
                    });
                }
            } else {
                // Interval starts from -inf, so no gap at beginning
            }

            if (i.max) |max| {
                current_v = try max.clone(allocator);
                current_include = !i.include_max;
            } else {
                // Interval goes to +inf, no more gaps
                return VersionRange{ .intervals = try list.toOwnedSlice(allocator) };
            }
        }

        // Final gap to +inf
        try list.append(allocator, .{
            .min = current_v,
            .include_min = current_include,
            .max = null,
            .include_max = false,
        });

        return VersionRange{ .intervals = try list.toOwnedSlice(allocator) };
    }


    };

/// Backward compatibility helper for existing codebase
pub fn matches(version_text: []const u8, range_text: []const u8) bool {
    const v = Version.parse(version_text) catch return false;
    // We use a fixed stack allocator for this simple check to avoid complicated lifetime management
    var buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const r = VersionRange.parse(fba.allocator(), range_text) catch return false;
    return r.contains(v);
}

test "version parsing" {
    const v = try Version.parse("1.2.3-alpha+build.1");
    try std.testing.expectEqual(@as(u64, 1), v.major);
    try std.testing.expectEqual(@as(u64, 2), v.minor);
    try std.testing.expectEqual(@as(u64, 3), v.patch);
    try std.testing.expectEqualStrings("alpha", v.pre);
    try std.testing.expectEqualStrings("build.1", v.build);
}

test "version comparison" {
    const v1 = try Version.parse("1.2.3");
    const v2 = try Version.parse("1.2.4");
    const v3 = try Version.parse("1.3.0");
    const v4 = try Version.parse("1.2.3-alpha");

    try std.testing.expect(v1.compare(v2) < 0);
    try std.testing.expect(v2.compare(v1) > 0);
    try std.testing.expect(v1.compare(v1) == 0);
    try std.testing.expect(v3.compare(v2) > 0);
    try std.testing.expect(v4.compare(v1) < 0);
}

test "interval intersection" {
    const v1 = try Version.parse("1.0.0");
    const v2 = try Version.parse("2.0.0");
    const v3 = try Version.parse("3.0.0");
    const v4 = try Version.parse("4.0.0");

    const iv1 = Interval{ .min = v1, .max = v3 }; // [1, 3)
    const iv2 = Interval{ .min = v2, .max = v4 }; // [2, 4)

    const res = iv1.intersect(iv2).?;
    try std.testing.expectEqual(v2, res.min.?);
    try std.testing.expectEqual(v3, res.max.?);
}

test "range parsing and contains" {
    const allocator = std.testing.allocator;

    const r1 = try VersionRange.parse(allocator, "^1.2.3");
    defer r1.deinit(allocator);
    try std.testing.expect(r1.contains(try Version.parse("1.2.3")));
    try std.testing.expect(r1.contains(try Version.parse("1.5.0")));
    try std.testing.expect(!r1.contains(try Version.parse("2.0.0")));

    const r2 = try VersionRange.parse(allocator, ">= 1.0.0, < 2.0.0");
    defer r2.deinit(allocator);
    try std.testing.expect(r2.contains(try Version.parse("1.5.0")));
    try std.testing.expect(!r2.contains(try Version.parse("2.0.0")));
}
