import re

with open("src/core/domain/semver.zig", "r") as f:
    content = f.read()

interval_format = """
    pub fn format(
        self: Interval,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.min == null and self.max == null) {
            try writer.writeAll("*");
            return;
        }
        
        try writer.writeAll(if (self.include_min) "[" else "(");
        if (self.min) |min| try writer.print("{}", .{min}) else try writer.writeAll("0.0.0");
        try writer.writeAll(", ");
        if (self.max) |max| try writer.print("{}", .{max}) else try writer.writeAll("∞");
        try writer.writeAll(if (self.include_max) "]" else ")");
    }
"""

content = content.replace("pub const Interval = struct {", "pub const Interval = struct {\n" + interval_format)

range_format = """
    pub fn format(
        self: VersionRange,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
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
            try writer.print("{}", .{interval});
        }
    }
"""

content = content.replace("pub const VersionRange = struct {", "pub const VersionRange = struct {\n" + range_format)

with open("src/core/domain/semver.zig", "w") as f:
    f.write(content)
