const std = @import("std");

pub const VersionScheme = enum { semver, luarocks };

/// Represents a Semantic Version (SemVer 2.0.0).
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    /// Additional numeric upstream components used by LuaRocks (e.g. 2.1.0.6).
    extra: []const u8 = "",
    pre: []const u8 = "",
    build: []const u8 = "",
    precision: u8 = 3,
    revision: bool = false,

    const NumericSplit = struct { num: []const u8, rest: []const u8 };

    fn splitNumericPrefix(text: []const u8) NumericSplit {
        var end: usize = 0;
        while (end < text.len and text[end] >= '0' and text[end] <= '9') {
            end += 1;
        }
        return .{
            .num = if (end > 0) text[0..end] else "0",
            .rest = text[end..],
        };
    }

    pub fn parse(text: []const u8) !Version {
        return parseInternal(text, false);
    }

    /// Parse LuaRocks' more permissive upstream version vocabulary. Callers
    /// must opt into this explicitly so registry SemVer remains strict.
    pub fn parseLuaRocks(text: []const u8) !Version {
        return parseInternal(text, true);
    }

    fn parseInternal(text: []const u8, luarocks_compatible: bool) !Version {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidVersion;

        const clean_text = if (luarocks_compatible and trimmed.len > 1 and (trimmed[0] == 'v' or trimmed[0] == 'V') and std.ascii.isDigit(trimmed[1]))
            trimmed[1..]
        else
            trimmed;

        var it = std.mem.splitScalar(u8, clean_text, '+');
        const main_pre = it.next() orelse return error.InvalidVersion;
        var build = it.next() orelse "";

        var pre_it = std.mem.splitScalar(u8, main_pre, '-');
        const main = pre_it.next() orelse return error.InvalidVersion;
        var pre = pre_it.next() orelse "";

        var has_rock_revision = false;
        if (luarocks_compatible and pre.len > 0 and build.len == 0) {
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
                has_rock_revision = true;
            }
        }

        var main_it = std.mem.splitScalar(u8, main, '.');
        const major_raw = main_it.next() orelse return error.InvalidVersion;
        const major_split = if (luarocks_compatible) splitNumericPrefix(major_raw) else NumericSplit{ .num = major_raw, .rest = "" };

        var precision: u8 = 1;
        const minor_split: NumericSplit = if (main_it.next()) |s| blk: {
            precision = 2;
            break :blk if (luarocks_compatible) splitNumericPrefix(s) else NumericSplit{ .num = s, .rest = "" };
        } else .{ .num = "0", .rest = "" };

        const patch_split: NumericSplit = if (main_it.next()) |s| blk: {
            precision = 3;
            break :blk if (luarocks_compatible) splitNumericPrefix(s) else NumericSplit{ .num = s, .rest = "" };
        } else .{ .num = "0", .rest = "" };
        var extra: []const u8 = "";
        if (luarocks_compatible) {
            var dots: usize = 0;
            var extra_start: ?usize = null;
            for (main, 0..) |c, i| {
                if (c == '.') {
                    dots += 1;
                    if (dots == 3) extra_start = i + 1;
                }
            }
            if (extra_start) |start| {
                if (start < main.len) extra = main[start..];
            }
        }

        var final_pre = pre;
        if (final_pre.len == 0) {
            if (patch_split.rest.len > 0) {
                final_pre = patch_split.rest;
            } else if (minor_split.rest.len > 0) {
                final_pre = minor_split.rest;
            } else if (major_split.rest.len > 0) {
                final_pre = major_split.rest;
            }
        }

        return Version{
            .major = try std.fmt.parseInt(u64, major_split.num, 10),
            .minor = try std.fmt.parseInt(u64, minor_split.num, 10),
            .patch = try std.fmt.parseInt(u64, patch_split.num, 10),
            .extra = extra,
            .pre = final_pre,
            .build = build,
            .precision = precision,
            .revision = has_rock_revision,
        };
    }

    pub fn parseCloned(allocator: std.mem.Allocator, text: []const u8) !Version {
        var v = try parse(text);
        if (v.pre.len > 0) v.pre = try allocator.dupe(u8, v.pre);
        if (v.build.len > 0) v.build = try allocator.dupe(u8, v.build);
        if (v.extra.len > 0) v.extra = try allocator.dupe(u8, v.extra);
        return v;
    }

    pub fn parseLuaRocksCloned(allocator: std.mem.Allocator, text: []const u8) !Version {
        var v = try parseLuaRocks(text);
        if (v.pre.len > 0) v.pre = try allocator.dupe(u8, v.pre);
        if (v.build.len > 0) v.build = try allocator.dupe(u8, v.build);
        if (v.extra.len > 0) v.extra = try allocator.dupe(u8, v.extra);
        return v;
    }

    fn isNumeric(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |c| {
            if (c < '0' or c > '9') return false;
        }
        return true;
    }

    pub fn compareUpstream(self: Version, other: Version) i8 {
        if (self.major != other.major) return if (self.major > other.major) 1 else -1;
        if (self.minor != other.minor) return if (self.minor > other.minor) 1 else -1;
        if (self.patch != other.patch) return if (self.patch > other.patch) 1 else -1;

        // Pre-release comparison
        if (self.pre.len == 0 and other.pre.len > 0) return 1;
        if (self.pre.len > 0 and other.pre.len == 0) return -1;
        if (self.pre.len > 0 and other.pre.len > 0) {
            var it1 = std.mem.splitScalar(u8, self.pre, '.');
            var it2 = std.mem.splitScalar(u8, other.pre, '.');

            while (true) {
                const part1 = it1.next();
                const part2 = it2.next();

                if (part1 == null and part2 == null) break;
                if (part1 == null) return -1;
                if (part2 == null) return 1;

                const is_num1 = isNumeric(part1.?);
                const is_num2 = isNumeric(part2.?);

                if (is_num1 and !is_num2) return -1;
                if (!is_num1 and is_num2) return 1;

                if (is_num1 and is_num2) {
                    const n1 = std.fmt.parseInt(u64, part1.?, 10) catch 0;
                    const n2 = std.fmt.parseInt(u64, part2.?, 10) catch 0;
                    if (n1 < n2) return -1;
                    if (n1 > n2) return 1;
                } else {
                    const cmp = std.mem.order(u8, part1.?, part2.?);
                    if (cmp == .lt) return -1;
                    if (cmp == .gt) return 1;
                }
            }
        }

        return 0;
    }

    pub fn compare(self: Version, other: Version) i8 {
        return self.compareUpstream(other);
    }

    pub fn compareLuaRocks(self: Version, other: Version) i8 {
        const upstream_cmp = self.compareLuaRocksUpstream(other);
        if (upstream_cmp != 0) return upstream_cmp;

        // Build / revision comparison
        if (self.build.len > 0 or other.build.len > 0) {
            if (self.build.len > 0 and other.build.len == 0) return 1;
            if (self.build.len == 0 and other.build.len > 0) return -1;

            var it1 = std.mem.splitScalar(u8, self.build, '.');
            var it2 = std.mem.splitScalar(u8, other.build, '.');

            while (true) {
                const part1 = it1.next();
                const part2 = it2.next();

                if (part1 == null and part2 == null) break;
                if (part1 == null) return -1;
                if (part2 == null) return 1;

                const is_num1 = isNumeric(part1.?);
                const is_num2 = isNumeric(part2.?);

                if (is_num1 and !is_num2) return -1;
                if (!is_num1 and is_num2) return 1;

                if (is_num1 and is_num2) {
                    const n1 = std.fmt.parseInt(u64, part1.?, 10) catch 0;
                    const n2 = std.fmt.parseInt(u64, part2.?, 10) catch 0;
                    if (n1 < n2) return -1;
                    if (n1 > n2) return 1;
                } else {
                    const cmp = std.mem.order(u8, part1.?, part2.?);
                    if (cmp == .lt) return -1;
                    if (cmp == .gt) return 1;
                }
            }
        }

        return 0;
    }

    pub fn compareLuaRocksUpstream(self: Version, other: Version) i8 {
        const self_rolling = self.major == 0 and self.precision == 1 and isLuaRocksRolling(self.pre);
        const other_rolling = other.major == 0 and other.precision == 1 and isLuaRocksRolling(other.pre);
        if (self_rolling or other_rolling) {
            if (self_rolling and !other_rolling) return 1;
            if (!self_rolling and other_rolling) return -1;
            return compareLuaRocksSuffix(self.pre, other.pre);
        }

        if (self.major != other.major) return if (self.major > other.major) 1 else -1;
        if (self.minor != other.minor) return if (self.minor > other.minor) 1 else -1;
        if (self.patch != other.patch) return if (self.patch > other.patch) 1 else -1;
        if (self.extra.len == 0 and other.extra.len > 0) return -1;
        if (self.extra.len > 0 and other.extra.len == 0) return 1;
        if (self.extra.len > 0 and other.extra.len > 0) {
            var a = std.mem.splitScalar(u8, self.extra, '.');
            var b = std.mem.splitScalar(u8, other.extra, '.');
            while (true) {
                const x = a.next();
                const y = b.next();
                if (x == null and y == null) break;
                if (x == null) return -1;
                if (y == null) return 1;
                const nx = std.fmt.parseInt(u64, x.?, 10) catch 0;
                const ny = std.fmt.parseInt(u64, y.?, 10) catch 0;
                if (nx != ny) return if (nx > ny) 1 else -1;
            }
        }
        return compareLuaRocksSuffix(self.pre, other.pre);
    }

    pub fn print(self: Version, writer: anytype) !void {
        try writer.print("{d}", .{self.major});
        if (self.precision >= 2) try writer.print(".{d}", .{self.minor});
        if (self.precision >= 3) try writer.print(".{d}", .{self.patch});
        if (self.pre.len > 0) try writer.print("-{s}", .{self.pre});
        if (self.build.len > 0) {
            if (self.revision) {
                try writer.print("-{s}", .{self.build});
            } else {
                try writer.print("+{s}", .{self.build});
            }
        }
    }

    pub fn clone(self: Version, allocator: std.mem.Allocator) !Version {
        return Version{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .extra = if (self.extra.len > 0) try allocator.dupe(u8, self.extra) else "",
            .pre = if (self.pre.len > 0) try allocator.dupe(u8, self.pre) else "",
            .build = if (self.build.len > 0) try allocator.dupe(u8, self.build) else "",
            .precision = self.precision,
            .revision = self.revision,
        };
    }

    pub fn deinit(self: Version, allocator: std.mem.Allocator) void {
        if (self.pre.len > 0) allocator.free(self.pre);
        if (self.build.len > 0) allocator.free(self.build);
        if (self.extra.len > 0) allocator.free(self.extra);
    }

    pub fn toString(self: Version, allocator: std.mem.Allocator) ![]const u8 {
        const build_prefix = if (self.build.len > 0) (if (self.revision) "-" else "+") else "";

        if (self.precision == 1) {
            return std.fmt.allocPrint(allocator, "{d}{s}{s}{s}{s}", .{
                self.major,
                if (self.pre.len > 0) "-" else "",
                self.pre,
                build_prefix,
                self.build,
            });
        } else if (self.precision == 2) {
            return std.fmt.allocPrint(allocator, "{d}.{d}{s}{s}{s}{s}", .{
                self.major,                        self.minor,
                if (self.pre.len > 0) "-" else "", self.pre,
                build_prefix,                      self.build,
            });
        } else {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}{s}{s}{s}{s}{s}{s}", .{
                self.major,                          self.minor,   self.patch,
                if (self.extra.len > 0) "." else "", self.extra,   if (self.pre.len > 0) "-" else "",
                self.pre,                            build_prefix, self.build,
            });
        }
    }
};

fn isLuaRocksRolling(suffix: []const u8) bool {
    return std.mem.eql(u8, suffix, "dev") or std.mem.eql(u8, suffix, "scm") or std.mem.eql(u8, suffix, "cvs");
}

fn luaRocksTokenRank(token: []const u8) i64 {
    if (std.mem.eql(u8, token, "dev")) return 120_000_000;
    if (std.mem.eql(u8, token, "scm")) return 110_000_000;
    if (std.mem.eql(u8, token, "cvs")) return 100_000_000;
    if (std.mem.eql(u8, token, "rc")) return -1_000;
    if (std.mem.eql(u8, token, "pre")) return -10_000;
    if (std.mem.eql(u8, token, "beta")) return -100_000;
    if (std.mem.eql(u8, token, "alpha")) return -1_000_000;
    return if (token.len > 0) @as(i64, token[0]) * 100 else 0;
}

fn luaRocksSuffixPart(suffix: []const u8) struct { score: i128, rest: []const u8 } {
    if (suffix.len == 0) return .{ .score = 0, .rest = "" };

    var alpha_end: usize = 0;
    while (alpha_end < suffix.len and std.ascii.isAlphabetic(suffix[alpha_end])) alpha_end += 1;
    if (alpha_end > 0) {
        var digit_end = alpha_end;
        while (digit_end < suffix.len and std.ascii.isDigit(suffix[digit_end])) digit_end += 1;
        const numeric = if (digit_end > alpha_end)
            std.fmt.parseInt(u64, suffix[alpha_end..digit_end], 10) catch 0
        else
            0;
        return .{
            .score = @as(i128, luaRocksTokenRank(suffix[0..alpha_end])) * 100_000 + numeric,
            .rest = suffix[digit_end..],
        };
    }

    var digit_end: usize = 0;
    while (digit_end < suffix.len and std.ascii.isDigit(suffix[digit_end])) digit_end += 1;
    if (digit_end > 0) {
        return .{
            .score = @as(i128, std.fmt.parseInt(u64, suffix[0..digit_end], 10) catch 0) * 100_000,
            .rest = suffix[digit_end..],
        };
    }
    return .{ .score = suffix[0], .rest = suffix[1..] };
}

fn compareLuaRocksSuffix(left: []const u8, right: []const u8) i8 {
    var left_rest = left;
    var right_rest = right;
    while (left_rest.len > 0 or right_rest.len > 0) {
        const left_part = luaRocksSuffixPart(left_rest);
        const right_part = luaRocksSuffixPart(right_rest);
        if (left_part.score != right_part.score) return if (left_part.score > right_part.score) 1 else -1;
        left_rest = left_part.rest;
        right_rest = right_part.rest;
    }
    return 0;
}

/// Represents a single interval of versions.
pub const Interval = struct {
    pub fn print(self: Interval, writer: anytype) !void {
        if (self.min == null and self.max == null) {
            try writer.writeAll("*");
            return;
        }

        try writer.writeAll(if (self.include_min) "[" else "(");
        if (self.min) |min| try min.print(writer) else try writer.writeAll("0.0.0");
        try writer.writeAll(", ");
        if (self.max) |max| try max.print(writer) else try writer.writeAll("∞");
        try writer.writeAll(if (self.include_max) "]" else ")");
    }

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
        return self.containsWithScheme(v, .semver);
    }

    pub fn containsWithScheme(self: Interval, v: Version, scheme: VersionScheme) bool {
        if (self.min) |min| {
            const cmp = if (scheme == .luarocks)
                (if (min.revision) v.compareLuaRocks(min) else v.compareLuaRocksUpstream(min))
            else
                v.compare(min);
            if (cmp < 0) return false;
            if (cmp == 0 and !self.include_min) return false;
        }
        if (self.max) |max| {
            const cmp = if (scheme == .luarocks)
                (if (max.revision) v.compareLuaRocks(max) else v.compareLuaRocksUpstream(max))
            else
                v.compare(max);
            if (cmp > 0) return false;
            if (cmp == 0 and !self.include_max) return false;
        }
        return true;
    }

    /// Returns the intersection of two intervals (shallow copy).
    pub fn intersect(self: Interval, other: Interval) ?Interval {
        return self.intersectWithScheme(other, .semver);
    }

    pub fn intersectWithScheme(self: Interval, other: Interval, scheme: VersionScheme) ?Interval {
        var res = Interval{};

        // Min
        if (self.min == null) {
            res.min = other.min;
            res.include_min = other.include_min;
        } else if (other.min == null) {
            res.min = self.min;
            res.include_min = self.include_min;
        } else {
            const cmp = compareForScheme(self.min.?, other.min.?, scheme);
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
            const cmp = compareForScheme(self.max.?, other.max.?, scheme);
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
            const cmp = compareForScheme(res.min.?, res.max.?, scheme);
            if (cmp > 0) return null;
            if (cmp == 0 and (!res.include_min or !res.include_max)) return null;
        }

        return res;
    }

    /// Returns the intersection of two intervals (cloned).
    pub fn intersectClone(self: Interval, other: Interval, allocator: std.mem.Allocator) !?Interval {
        const shallow = self.intersect(other) orelse return null;
        return try shallow.clone(allocator);
    }

    pub fn intersectCloneWithScheme(self: Interval, other: Interval, allocator: std.mem.Allocator, scheme: VersionScheme) !?Interval {
        const shallow = self.intersectWithScheme(other, scheme) orelse return null;
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

fn compareForScheme(left: Version, right: Version, scheme: VersionScheme) i8 {
    return if (scheme == .luarocks) left.compareLuaRocks(right) else left.compare(right);
}

/// Represents a set of allowed versions (disjoint intervals).
pub const VersionRange = struct {
    pub fn print(self: VersionRange, writer: anytype) !void {
        if (self.intervals.len == 0) {
            try writer.writeAll("empty");
            return;
        }
        if (self.intervals.len == 1 and self.intervals[0].min == null and self.intervals[0].max == null) {
            try writer.writeAll("*");
            return;
        }
        for (self.intervals, 0..) |interval, i| {
            if (i > 0) try writer.writeAll(" || ");
            try interval.print(writer);
        }
    }
    intervals: []const Interval,
    excludes: []const Version = &.{},
    scheme: VersionScheme = .semver,

    pub fn any(allocator: std.mem.Allocator) !VersionRange {
        var list = try allocator.alloc(Interval, 1);
        list[0] = Interval{};
        return VersionRange{ .intervals = list, .excludes = &.{}, .scheme = .semver };
    }

    pub fn clone(self: VersionRange, allocator: std.mem.Allocator) !VersionRange {
        const list = try allocator.alloc(Interval, self.intervals.len);
        for (self.intervals, 0..) |interval, i| {
            list[i] = try interval.clone(allocator);
        }
        const ex_list = try allocator.alloc(Version, self.excludes.len);
        for (self.excludes, 0..) |ex, i| {
            ex_list[i] = try ex.clone(allocator);
        }
        return VersionRange{ .intervals = list, .excludes = ex_list, .scheme = self.scheme };
    }

    pub fn deinit(self: VersionRange, allocator: std.mem.Allocator) void {
        for (self.intervals) |interval| {
            var mut_i = interval;
            mut_i.deinit(allocator);
        }
        allocator.free(self.intervals);
        for (self.excludes) |ex| {
            var mut_e = ex;
            mut_e.deinit(allocator);
        }
        allocator.free(self.excludes);
    }

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !VersionRange {
        return parseInternal(allocator, text, .semver);
    }

    pub fn parseLuaRocks(allocator: std.mem.Allocator, text: []const u8) !VersionRange {
        return parseInternal(allocator, text, .luarocks);
    }

    fn parseInternal(allocator: std.mem.Allocator, text: []const u8, scheme: VersionScheme) !VersionRange {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "*")) {
            var result = try any(allocator);
            result.scheme = scheme;
            return result;
        }

        var list = std.ArrayList(Interval).empty;
        errdefer {
            for (list.items) |*i| i.deinit(allocator);
            list.deinit(allocator);
        }
        var excludes = std.ArrayList(Version).empty;
        errdefer {
            for (excludes.items) |*e| e.deinit(allocator);
            excludes.deinit(allocator);
        }

        var current = Interval{};
        errdefer current.deinit(allocator);
        var has_interval = false;
        var idx: usize = 0;

        while (idx < trimmed.len) {
            // Skip whitespace and commas
            while (idx < trimmed.len and (trimmed[idx] == ' ' or trimmed[idx] == '\t' or trimmed[idx] == '\r' or trimmed[idx] == '\n' or trimmed[idx] == ',')) {
                idx += 1;
            }
            if (idx >= trimmed.len) break;

            // Check for operator
            const Op = enum { eq, neq, gte, gt, lte, lt, pcm, caret, tilde, none };
            var op: Op = .none;

            if (std.mem.startsWith(u8, trimmed[idx..], "==")) {
                op = .eq;
                idx += 2;
            } else if (std.mem.startsWith(u8, trimmed[idx..], "~=")) {
                op = .neq;
                idx += 2;
            } else if (std.mem.startsWith(u8, trimmed[idx..], "!=")) {
                op = .neq;
                idx += 2;
            } else if (std.mem.startsWith(u8, trimmed[idx..], ">=")) {
                op = .gte;
                idx += 2;
            } else if (std.mem.startsWith(u8, trimmed[idx..], "<=")) {
                op = .lte;
                idx += 2;
            } else if (std.mem.startsWith(u8, trimmed[idx..], "~>")) {
                op = .pcm;
                idx += 2;
            } else if (trimmed[idx] == '>') {
                op = .gt;
                idx += 1;
            } else if (trimmed[idx] == '<') {
                op = .lt;
                idx += 1;
            } else if (trimmed[idx] == '=') {
                op = .eq;
                idx += 1;
            } else if (trimmed[idx] == '^') {
                op = .caret;
                idx += 1;
            } else if (trimmed[idx] == '~') {
                op = .tilde;
                idx += 1;
            }

            // Skip whitespace between operator and version string
            while (idx < trimmed.len and (trimmed[idx] == ' ' or trimmed[idx] == '\t' or trimmed[idx] == '\r' or trimmed[idx] == '\n')) {
                idx += 1;
            }
            if (idx >= trimmed.len) return error.InvalidRange;

            // Extract version string token
            const ver_start = idx;
            while (idx < trimmed.len and
                trimmed[idx] != ' ' and trimmed[idx] != '\t' and trimmed[idx] != '\r' and trimmed[idx] != '\n' and trimmed[idx] != ',')
            {
                if (idx > ver_start and (trimmed[idx] == '>' or trimmed[idx] == '<' or trimmed[idx] == '=' or trimmed[idx] == '~' or trimmed[idx] == '!' or trimmed[idx] == '^')) {
                    break;
                }
                idx += 1;
            }

            const ver_str = trimmed[ver_start..idx];
            if (ver_str.len == 0) return error.InvalidRange;
            const v = if (scheme == .luarocks)
                try Version.parseLuaRocksCloned(allocator, ver_str)
            else
                try Version.parseCloned(allocator, ver_str);

            switch (op) {
                .eq, .none => {
                    has_interval = true;
                    if (current.min) |*m| m.deinit(allocator);
                    if (current.max) |*m| m.deinit(allocator);
                    current.min = v;
                    current.include_min = true;
                    const partial_equality = scheme == .luarocks or op == .none;
                    if (partial_equality and v.precision == 1 and !v.revision) {
                        current.max = Version{ .major = v.major + 1, .minor = 0, .patch = 0 };
                        current.include_max = false;
                    } else if (partial_equality and v.precision == 2 and !v.revision) {
                        current.max = Version{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
                        current.include_max = false;
                    } else if (scheme == .luarocks and !v.revision) {
                        // LuaRocks equality names an upstream version, not a
                        // particular rock revision. Model that as the whole
                        // upstream-version band so PubGrub can still choose and
                        // lock one concrete published revision.
                        current.max = Version{ .major = v.major, .minor = v.minor, .patch = v.patch + 1 };
                        current.include_max = false;
                    } else {
                        current.max = try v.clone(allocator);
                        current.include_max = true;
                    }
                },
                .neq => {
                    errdefer {
                        var mut_v = v;
                        mut_v.deinit(allocator);
                    }
                    try excludes.append(allocator, v);
                },
                .gte => {
                    has_interval = true;
                    if (current.min) |*m| m.deinit(allocator);
                    current.min = v;
                    current.include_min = true;
                },
                .gt => {
                    has_interval = true;
                    if (current.min) |*m| m.deinit(allocator);
                    current.min = v;
                    current.include_min = false;
                },
                .lte => {
                    has_interval = true;
                    if (current.max) |*m| m.deinit(allocator);
                    current.max = v;
                    current.include_max = true;
                },
                .lt => {
                    has_interval = true;
                    if (current.max) |*m| m.deinit(allocator);
                    current.max = v;
                    current.include_max = false;
                },
                .pcm => {
                    has_interval = true;
                    if (current.min) |*m| m.deinit(allocator);
                    if (current.max) |*m| m.deinit(allocator);
                    current.min = v;
                    current.include_min = true;
                    if (scheme == .luarocks and v.precision >= 3) {
                        // LuaRocks ~> on a fully specified upstream version
                        // accepts all revisions of that version only.
                        current.max = Version{ .major = v.major, .minor = v.minor, .patch = v.patch + 1 };
                    } else if (v.precision >= 2) {
                        current.max = Version{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
                    } else {
                        current.max = Version{ .major = v.major + 1, .minor = 0, .patch = 0 };
                    }
                    current.include_max = false;
                },
                .caret => {
                    has_interval = true;
                    if (current.min) |*m| m.deinit(allocator);
                    if (current.max) |*m| m.deinit(allocator);
                    current.min = v;
                    current.include_min = true;
                    current.max = Version{ .major = v.major + 1, .minor = 0, .patch = 0 };
                    current.include_max = false;
                },
                .tilde => {
                    has_interval = true;
                    if (current.min) |*m| m.deinit(allocator);
                    if (current.max) |*m| m.deinit(allocator);
                    current.min = v;
                    current.include_min = true;
                    current.max = Version{ .major = v.major, .minor = v.minor + 1, .patch = 0 };
                    current.include_max = false;
                },
            }
        }

        if (has_interval or excludes.items.len > 0) {
            try list.append(allocator, current);
            current = Interval{};
        } else {
            return try any(allocator);
        }

        return VersionRange{
            .intervals = try list.toOwnedSlice(allocator),
            .excludes = try excludes.toOwnedSlice(allocator),
            .scheme = scheme,
        };
    }

    pub fn contains(self: VersionRange, v: Version) bool {
        for (self.excludes) |ex| {
            const cmp = if (self.scheme == .luarocks)
                (if (ex.revision) v.compareLuaRocks(ex) else v.compareLuaRocksUpstream(ex))
            else
                v.compare(ex);
            if (cmp == 0) return false;
        }
        for (self.intervals) |i| {
            if (i.containsWithScheme(v, self.scheme)) return true;
        }
        return false;
    }

    pub fn intersect(self: VersionRange, other: VersionRange, allocator: std.mem.Allocator) !VersionRange {
        const result_scheme: VersionScheme = if (self.scheme == .luarocks or other.scheme == .luarocks) .luarocks else .semver;
        var list = std.ArrayList(Interval).empty;
        errdefer {
            for (list.items) |*i| i.deinit(allocator);
            list.deinit(allocator);
        }
        var excludes = std.ArrayList(Version).empty;
        errdefer {
            for (excludes.items) |*e| e.deinit(allocator);
            excludes.deinit(allocator);
        }

        for (self.excludes) |ex| {
            try excludes.append(allocator, try ex.clone(allocator));
        }
        for (other.excludes) |ex| {
            try excludes.append(allocator, try ex.clone(allocator));
        }

        for (self.intervals) |a| {
            for (other.intervals) |b| {
                if (try a.intersectCloneWithScheme(b, allocator, result_scheme)) |res| {
                    try list.append(allocator, res);
                }
            }
        }

        return VersionRange{
            .intervals = try list.toOwnedSlice(allocator),
            .excludes = try excludes.toOwnedSlice(allocator),
            .scheme = result_scheme,
        };
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
        const result_scheme: VersionScheme = if (self.scheme == .luarocks or other.scheme == .luarocks) .luarocks else .semver;
        for (self.intervals) |si| {
            for (other.intervals) |oi| {
                if (si.intersectWithScheme(oi, result_scheme) != null) return false;
            }
        }
        return true;
    }

    pub fn isEmpty(self: VersionRange) bool {
        return self.intervals.len == 0;
    }

    fn compareIntervals(context: void, a: Interval, b: Interval) bool {
        _ = context;
        if (a.min == null and b.min != null) return true;
        if (a.min != null and b.min == null) return false;
        if (a.min != null and b.min != null) {
            const cmp = a.min.?.compare(b.min.?);
            if (cmp < 0) return true;
            if (cmp > 0) return false;
            // same min, inclusive comes before exclusive
            if (a.include_min and !b.include_min) return true;
            if (!a.include_min and b.include_min) return false;
        }
        return false;
    }

    pub fn unionRanges(self: VersionRange, other: VersionRange, allocator: std.mem.Allocator) !VersionRange {
        var list = std.ArrayList(Interval).empty;
        errdefer list.deinit(allocator);

        try list.appendSlice(allocator, self.intervals);
        try list.appendSlice(allocator, other.intervals);
        if (list.items.len <= 1) {
            return VersionRange{ .intervals = try list.toOwnedSlice(allocator), .scheme = self.scheme };
        }

        std.mem.sort(Interval, list.items, {}, compareIntervals);

        var merged = std.ArrayList(Interval).empty;
        errdefer merged.deinit(allocator);

        var current = try list.items[0].clone(allocator);
        for (list.items[1..]) |interval| {
            // Check if interval overlaps or is contiguous with current
            var overlaps = false;
            if (current.max == null) {
                overlaps = true;
            } else if (interval.min == null) {
                overlaps = true;
            } else {
                const cmp = current.max.?.compare(interval.min.?);
                if (cmp > 0) {
                    overlaps = true;
                } else if (cmp == 0) {
                    if (current.include_max or interval.include_min) {
                        overlaps = true;
                    }
                }
            }

            if (overlaps) {
                // Merge interval into current
                if (current.max != null) {
                    if (interval.max == null) {
                        current.max.?.deinit(allocator);
                        current.max = null;
                        current.include_max = interval.include_max;
                    } else {
                        const cmp = current.max.?.compare(interval.max.?);
                        if (cmp < 0) {
                            current.max.?.deinit(allocator);
                            current.max = try interval.max.?.clone(allocator);
                            current.include_max = interval.include_max;
                        } else if (cmp == 0) {
                            current.include_max = current.include_max or interval.include_max;
                        }
                    }
                }
            } else {
                try merged.append(allocator, current);
                current = try interval.clone(allocator);
            }
        }
        try merged.append(allocator, current);
        list.deinit(allocator);
        return VersionRange{ .intervals = try merged.toOwnedSlice(allocator), .scheme = self.scheme };
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
                return VersionRange{ .intervals = try list.toOwnedSlice(allocator), .scheme = self.scheme };
            }
        }

        // Final gap to +inf
        try list.append(allocator, .{
            .min = current_v,
            .include_min = current_include,
            .max = null,
            .include_max = false,
        });

        return VersionRange{ .intervals = try list.toOwnedSlice(allocator), .scheme = self.scheme };
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

test "LuaRocks parsing is explicit and does not change SemVer build precedence" {
    const allocator = std.testing.allocator;

    const semver_revision_like = try Version.parse("1.2.3-1");
    try std.testing.expect(!semver_revision_like.revision);
    try std.testing.expectEqualStrings("1", semver_revision_like.pre);

    const rock = try Version.parseLuaRocks("1.2.3-1");
    try std.testing.expect(rock.revision);
    try std.testing.expectEqualStrings("1", rock.build);

    const build_one = try Version.parse("1.2.3+1");
    const build_two = try Version.parse("1.2.3+2");
    try std.testing.expectEqual(@as(i8, 0), build_one.compare(build_two));
    const rendered = try build_one.toString(allocator);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("1.2.3+1", rendered);

    try std.testing.expectError(error.InvalidCharacter, Version.parse("1.2.3beta1"));
    _ = try Version.parseLuaRocks("1.2.3beta1");
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

    const r3 = try VersionRange.parse(allocator, ">= 0.10, ~= 0.11");
    defer r3.deinit(allocator);
    try std.testing.expect(r3.contains(try Version.parse("0.10.0")));
    try std.testing.expect(!r3.contains(try Version.parse("0.11.0")));
    try std.testing.expect(r3.contains(try Version.parse("0.12.0")));
}

test "range union merging" {
    const allocator = std.testing.allocator;

    const r1 = try VersionRange.parse(allocator, ">= 1.0.0, < 2.0.0");
    defer r1.deinit(allocator);

    const r2 = try VersionRange.parse(allocator, ">= 1.5.0, < 3.0.0");
    defer r2.deinit(allocator);

    const merged = try r1.unionRanges(r2, allocator);
    defer merged.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), merged.intervals.len);

    const min_str = try merged.intervals[0].min.?.toString(allocator);
    defer allocator.free(min_str);
    try std.testing.expectEqualStrings("1.0.0", min_str);

    const max_str = try merged.intervals[0].max.?.toString(allocator);
    defer allocator.free(max_str);
    try std.testing.expectEqualStrings("3.0.0", max_str);
}

test "LuaRocks exact constraint luv == 1.52.1 matches all 1.52.1 revisions and rejects other versions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, "== 1.52.1");
    defer r.deinit(allocator);

    const v1_52_0_0 = try Version.parseLuaRocks("1.52.0-0");
    const v1_52_1_0 = try Version.parseLuaRocks("1.52.1-0");
    const v1_52_1_1 = try Version.parseLuaRocks("1.52.1-1");
    const v1_53_0_0 = try Version.parseLuaRocks("1.53.0-0");

    try std.testing.expect(!r.contains(v1_52_0_0));
    try std.testing.expect(r.contains(v1_52_1_0));
    try std.testing.expect(r.contains(v1_52_1_1));
    try std.testing.expect(!r.contains(v1_53_0_0));

    // Higher rock revision has higher precedence
    try std.testing.expect(v1_52_1_1.compareLuaRocks(v1_52_1_0) > 0);
    try std.testing.expect(v1_52_1_0.compareLuaRocks(v1_52_1_1) < 0);
    try std.testing.expectEqual(@as(i8, 0), v1_52_1_0.compareUpstream(v1_52_1_1));
}

test "LuaRocks compares additional upstream components numerically" {
    const allocator = std.testing.allocator;
    const six = try Version.parseLuaRocks("2.1.0.6-1");
    const ten = try Version.parseLuaRocks("2.1.0.10-1");
    try std.testing.expectEqualStrings("6", six.extra);
    try std.testing.expect(ten.compareLuaRocks(six) > 0);
    const rendered = try six.toString(allocator);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("2.1.0.6-1", rendered);
}

test "LuaRocks constraint foo == 1.2.3 with multiple revisions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, "== 1.2.3");
    defer r.deinit(allocator);

    const v1_2_2_1 = try Version.parseLuaRocks("1.2.2-1");
    const v1_2_3_0 = try Version.parseLuaRocks("1.2.3-0");
    const v1_2_3_1 = try Version.parseLuaRocks("1.2.3-1");
    const v1_2_3_2 = try Version.parseLuaRocks("1.2.3-2");
    const v1_2_4_0 = try Version.parseLuaRocks("1.2.4-0");

    try std.testing.expect(!r.contains(v1_2_2_1));
    try std.testing.expect(r.contains(v1_2_3_0));
    try std.testing.expect(r.contains(v1_2_3_1));
    try std.testing.expect(r.contains(v1_2_3_2));
    try std.testing.expect(!r.contains(v1_2_4_0));

    try std.testing.expect(v1_2_3_2.compareLuaRocks(v1_2_3_1) > 0);
    try std.testing.expect(v1_2_3_1.compareLuaRocks(v1_2_3_0) > 0);
}

test "LuaRocks constraint foo >= 1.2 with multiple revisions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, ">= 1.2");
    defer r.deinit(allocator);

    const v1_1_9_1 = try Version.parseLuaRocks("1.1.9-1");
    const v1_2_0_0 = try Version.parseLuaRocks("1.2.0-0");
    const v1_2_0_1 = try Version.parseLuaRocks("1.2.0-1");
    const v1_2_1_0 = try Version.parseLuaRocks("1.2.1-0");
    const v1_3_0_0 = try Version.parseLuaRocks("1.3.0-0");

    try std.testing.expect(!r.contains(v1_1_9_1));
    try std.testing.expect(r.contains(v1_2_0_0));
    try std.testing.expect(r.contains(v1_2_0_1));
    try std.testing.expect(r.contains(v1_2_1_0));
    try std.testing.expect(r.contains(v1_3_0_0));
}

test "LuaRocks constraint foo >= 1.2, < 2.0 with multiple revisions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, ">= 1.2, < 2.0");
    defer r.deinit(allocator);

    const v1_1_9_1 = try Version.parseLuaRocks("1.1.9-1");
    const v1_2_0_0 = try Version.parseLuaRocks("1.2.0-0");
    const v1_2_0_1 = try Version.parseLuaRocks("1.2.0-1");
    const v1_9_9_1 = try Version.parseLuaRocks("1.9.9-1");
    const v2_0_0_0 = try Version.parseLuaRocks("2.0.0-0");
    const v2_0_0_1 = try Version.parseLuaRocks("2.0.0-1");

    try std.testing.expect(!r.contains(v1_1_9_1));
    try std.testing.expect(r.contains(v1_2_0_0));
    try std.testing.expect(r.contains(v1_2_0_1));
    try std.testing.expect(r.contains(v1_9_9_1));
    try std.testing.expect(!r.contains(v2_0_0_0));
    try std.testing.expect(!r.contains(v2_0_0_1));
}

test "LuaRocks constraint foo ~> 1.2 with multiple revisions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, "~> 1.2");
    defer r.deinit(allocator);

    const v1_1_9_1 = try Version.parseLuaRocks("1.1.9-1");
    const v1_2_0_0 = try Version.parseLuaRocks("1.2.0-0");
    const v1_2_0_1 = try Version.parseLuaRocks("1.2.0-1");
    const v1_9_9_1 = try Version.parseLuaRocks("1.9.9-1");
    const v2_0_0_0 = try Version.parseLuaRocks("2.0.0-0");

    try std.testing.expect(!r.contains(v1_1_9_1));
    try std.testing.expect(r.contains(v1_2_0_0));
    try std.testing.expect(r.contains(v1_2_0_1));
    try std.testing.expect(!r.contains(v1_9_9_1));
    try std.testing.expect(!r.contains(v2_0_0_0));
}

test "LuaRocks constraint foo ~> 1.2.3 with multiple revisions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, "~> 1.2.3");
    defer r.deinit(allocator);

    const v1_2_2_1 = try Version.parseLuaRocks("1.2.2-1");
    const v1_2_3_0 = try Version.parseLuaRocks("1.2.3-0");
    const v1_2_3_1 = try Version.parseLuaRocks("1.2.3-1");
    const v1_2_9_1 = try Version.parseLuaRocks("1.2.9-1");
    const v1_3_0_0 = try Version.parseLuaRocks("1.3.0-0");

    try std.testing.expect(!r.contains(v1_2_2_1));
    try std.testing.expect(r.contains(v1_2_3_0));
    try std.testing.expect(r.contains(v1_2_3_1));
    try std.testing.expect(!r.contains(v1_2_9_1));
    try std.testing.expect(!r.contains(v1_3_0_0));
}

test "LuaRocks constraint foo ~> 1 with multiple revisions" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, "~> 1");
    defer r.deinit(allocator);

    const v0_9_9_1 = try Version.parseLuaRocks("0.9.9-1");
    const v1_0_0_0 = try Version.parseLuaRocks("1.0.0-0");
    const v1_52_1_0 = try Version.parseLuaRocks("1.52.1-0");
    const v1_52_1_1 = try Version.parseLuaRocks("1.52.1-1");
    const v2_0_0_0 = try Version.parseLuaRocks("2.0.0-0");

    try std.testing.expect(!r.contains(v0_9_9_1));
    try std.testing.expect(r.contains(v1_0_0_0));
    try std.testing.expect(r.contains(v1_52_1_0));
    try std.testing.expect(r.contains(v1_52_1_1));
    try std.testing.expect(!r.contains(v2_0_0_0));
}

test "LuaRocks constraint with exact revision foo == 1.2.3-1" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, "== 1.2.3-1");
    defer r.deinit(allocator);

    const v1_2_3_0 = try Version.parseLuaRocks("1.2.3-0");
    const v1_2_3_1 = try Version.parseLuaRocks("1.2.3-1");
    const v1_2_3_2 = try Version.parseLuaRocks("1.2.3-2");

    try std.testing.expect(!r.contains(v1_2_3_0));
    try std.testing.expect(r.contains(v1_2_3_1));
    try std.testing.expect(!r.contains(v1_2_3_2));
}

test "LuaRocks constraint excluded revision ~= 1.2.3-1" {
    const allocator = std.testing.allocator;
    const r = try VersionRange.parseLuaRocks(allocator, ">= 1.2.0, ~= 1.2.3-1");
    defer r.deinit(allocator);

    const v1_2_3_0 = try Version.parseLuaRocks("1.2.3-0");
    const v1_2_3_1 = try Version.parseLuaRocks("1.2.3-1");
    const v1_2_3_2 = try Version.parseLuaRocks("1.2.3-2");

    try std.testing.expect(r.contains(v1_2_3_0));
    try std.testing.expect(!r.contains(v1_2_3_1));
    try std.testing.expect(r.contains(v1_2_3_2));
}
