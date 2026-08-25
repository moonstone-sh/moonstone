const std = @import("std");
const builtin = @import("builtin");

var enabled: bool = false;
var start_ns: i64 = 0;

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

pub fn now() i64 {
    return timestampNs();
}

fn msSince(from_ns: i64) i64 {
    return @divTrunc(timestampNs() - from_ns, 1_000_000);
}

fn timestampNs() i64 {
    if (comptime builtin.os.tag == .windows) {
        var counter: std.os.windows.LARGE_INTEGER = 0;
        var frequency: std.os.windows.LARGE_INTEGER = 0;
        if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
        if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency == 0) return 0;
        return scalePerformanceCounterNs(counter, frequency);
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
        return (@as(i64, ts.sec) * 1_000_000_000) + @as(i64, ts.nsec);
    }
}

/// QueryPerformanceCounter values can be large enough that multiplying by one
/// billion overflows i64 before the frequency division. Perform the conversion
/// in i128 so profiling initialization is safe on long-running Windows hosts.
fn scalePerformanceCounterNs(counter: i64, frequency: i64) i64 {
    const nanoseconds: i128 = @divTrunc(@as(i128, counter) * std.time.ns_per_s, @as(i128, frequency));
    return std.math.cast(i64, nanoseconds) orelse std.math.maxInt(i64);
}

test "performance counter scaling avoids intermediate overflow" {
    try std.testing.expectEqual(
        @as(i64, 10 * std.time.ns_per_s),
        scalePerformanceCounterNs(10 * std.time.ns_per_s, std.time.ns_per_s),
    );
}

pub fn mark(comptime label: []const u8) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s}\n", .{ msSince(start_ns), label });
}

pub fn span(comptime label: []const u8, span_start_ns: i64) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s} duration_ms={}\n", .{ msSince(start_ns), label, msSince(span_start_ns) });
}

pub fn spanCount(comptime label: []const u8, span_start_ns: i64, count_name: []const u8, count: usize) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s} duration_ms={} {s}={}\n", .{ msSince(start_ns), label, msSince(span_start_ns), count_name, count });
}

pub fn finish(comptime label: []const u8) void {
    if (!enabled) return;
    std.debug.print("[moon profile +{}ms] {s} total_ms={}\n", .{ msSince(start_ns), label, msSince(start_ns) });
}
