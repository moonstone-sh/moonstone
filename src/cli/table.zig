const std = @import("std");

pub fn terminalWidth(env: *std.process.Environ.Map) usize {
    if (env.get("COLUMNS")) |raw| {
        return std.fmt.parseUnsigned(usize, raw, 10) catch 100;
    }
    return 100;
}

pub fn fitWidths(total_width: usize, minimums: []const usize, flex: []const bool, out: []usize) void {
    var used: usize = 0;
    var flex_count: usize = 0;
    for (minimums, 0..) |min, i| {
        out[i] = min;
        used += min;
        if (i + 1 < minimums.len) used += 2;
        if (flex[i]) flex_count += 1;
    }
    if (total_width <= used or flex_count == 0) return;
    var extra = total_width - used;
    var i: usize = 0;
    while (extra > 0) : (i = (i + 1) % out.len) {
        if (!flex[i]) continue;
        out[i] += 1;
        extra -= 1;
    }
}

pub fn printRow(stdout: *std.Io.Writer, widths: []const usize, values: []const []const u8) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try stdout.print("  ", .{});
        try printCell(stdout, value, widths[i]);
    }
    try stdout.print("\n", .{});
}

pub fn printRule(stdout: *std.Io.Writer, widths: []const usize) !void {
    var total: usize = 0;
    for (widths, 0..) |width, i| total += width + if (i == 0) @as(usize, 0) else @as(usize, 2);
    var i: usize = 0;
    while (i < total) : (i += 1) try stdout.print("-", .{});
    try stdout.print("\n", .{});
}

fn printCell(stdout: *std.Io.Writer, value: []const u8, width: usize) !void {
    if (width == 0) return;
    if (value.len <= width) {
        try stdout.print("{s}", .{value});
        var pad = width - value.len;
        while (pad > 0) : (pad -= 1) try stdout.print(" ", .{});
        return;
    }
    if (width == 1) {
        try stdout.print("…", .{});
        return;
    }
    try stdout.print("{s}…", .{value[0 .. width - 1]});
}
