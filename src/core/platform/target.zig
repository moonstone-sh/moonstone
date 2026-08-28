const std = @import("std");
const builtin = @import("builtin");

pub const supported_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "riscv64-linux-gnu",
    "x86_64-macos",
    "aarch64-macos",
    "x86_64-windows-gnu",
    "aarch64-windows-gnu",
    "x86_64-windows-msvc",
    "aarch64-windows-msvc",
    "x86_64-freebsd",
    "aarch64-freebsd",
};

/// The first multi-profile release intentionally accepts a bounded target
/// vocabulary. These are the identities Moonstone can persist, inspect, and
/// replay without accepting arbitrary Zig triples it cannot yet materialize.
pub fn validate(target: []const u8) !void {
    for (supported_targets) |candidate| {
        if (std.mem.eql(u8, candidate, target)) return;
    }
    return error.UnsupportedTarget;
}

pub fn isHost(target: []const u8) bool {
    const comptime_host = comptime hostTargetLiteral();
    return std.mem.eql(u8, target, comptime_host);
}

pub fn hostTargetLiteral() []const u8 {
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => @compileError("Moonstone only supports x86_64, aarch64, and riscv64 hosts"),
    };
    const os = switch (builtin.os.tag) {
        .linux => "linux-gnu",
        .macos => "macos",
        .windows => switch (builtin.abi) {
            .gnu => "windows-gnu",
            .msvc => "windows-msvc",
            else => @compileError("Moonstone only supports GNU and MSVC Windows targets"),
        },
        .freebsd => "freebsd",
        else => @compileError("Moonstone does not support this host operating system"),
    };
    return arch ++ "-" ++ os;
}

/// Canonical concrete identity for the host realization. The architecture and
/// operating-system switches are evaluated from Zig's compile-time target, so
/// unsupported platform branches are not shipped in the executable.
pub fn hostTarget(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, hostTargetLiteral());
}

test "host target has a concrete architecture and operating system" {
    const target = try hostTarget(std.testing.allocator);
    defer std.testing.allocator.free(target);
    try std.testing.expect(std.mem.indexOfScalar(u8, target, '-') != null);
    try std.testing.expect(!std.mem.eql(u8, target, "native"));
}

test "RISC-V Linux is an accepted target profile" {
    try validate("riscv64-linux-gnu");
}
