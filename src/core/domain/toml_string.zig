//! Quoted TOML basic strings for handwritten serializers.
pub fn write(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20 or byte == 0x7f) try writer.print("\\u{x:0>4}", .{@as(u16, byte)}) else try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

pub fn field(writer: anytype, key: []const u8, value: []const u8) !void {
    try writer.print("{s} = ", .{key});
    try write(writer, value);
    try writer.writeByte('\n');
}
