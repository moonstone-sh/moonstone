const std = @import("std");

const MyStruct = struct {
    x: u32 = 42,
    pub fn format(
        self: MyStruct,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = self; _ = fmt; _ = options;
        try writer.print("Formatted!", .{});
    }
};

pub fn main() !void {
    const s = MyStruct{};
    std.debug.print("Value: {}\n", .{s});
}
