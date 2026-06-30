import os

filepath = "src/core/domain/semver.zig"
with open(filepath, "r") as f:
    content = f.read()

# Replace Interval format
interval_format_old = """    pub fn format(
        self: Interval,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;"""
interval_format_new = """    pub fn print(self: Interval, writer: anytype) !void {"""
content = content.replace(interval_format_old, interval_format_new)

# Replace VersionRange format
range_format_old = """    pub fn format(
        self: VersionRange,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;"""
range_format_new = """    pub fn print(self: VersionRange, writer: anytype) !void {"""
content = content.replace(range_format_old, range_format_new)

# Replace interval prints inside VersionRange
content = content.replace("try writer.print(\"{}\", .{interval});", "try interval.print(writer);")

# Replace Interval min/max prints
content = content.replace("try writer.print(\"{}\", .{min})", "try min.print(writer)")
content = content.replace("try writer.print(\"{}\", .{max})", "try max.print(writer)")

# Replace Version format
version_format_old = """    pub fn format(
        self: Version,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;"""
version_format_new = """    pub fn print(self: Version, writer: anytype) !void {"""
content = content.replace(version_format_old, version_format_new)

with open(filepath, "w") as f:
    f.write(content)
