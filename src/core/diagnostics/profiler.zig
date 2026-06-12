const std = @import("std");

var enabled: bool = false;
var start_ns: i128 = 0;

pub fn init(env: *std.process.Environ.Map) void {
    enabled = isEnabled(env);
    start_ns = timestampNs();
    if (enabled) {
        std.debug.print("[moon profile +0ms] process.start\n", .{});
    }
}

fn isEnabled(env: *std.process.Environ.Map) bool {
    const value = env.get("MOONSTONE_PROFILE") orelse env.get("MOON_PROFILE") orelse return false;
    return !(std.mem.eql(u8, value, "") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "off"));
}

pub fn active() bool {
    return enabled;
}

pub fn now() i128 {
    return timestampNs();
}

fn msSince(from_ns: i128) i128 {
    return @divTrunc(timestampNs() - from_ns, 1_000_000);
}

fn timestampNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return (@as(i128, ts.sec) * 1_000_000_000) + @as(i128, ts.nsec);
}

pub fn mark(comptime label: []const u8) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s}\n", .{ msSince(start_ns), label });
}

pub fn span(comptime label: []const u8, span_start_ns: i128) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s} duration_ms={}\n", .{ msSince(start_ns), label, msSince(span_start_ns) });
}

pub fn spanCount(comptime label: []const u8, span_start_ns: i128, count_name: []const u8, count: usize) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s} duration_ms={} {s}={}\n", .{ msSince(start_ns), label, msSince(span_start_ns), count_name, count });
}

pub fn finish(comptime label: []const u8) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s} total_ms={}\n", .{ msSince(start_ns), label, msSince(start_ns) });
}
