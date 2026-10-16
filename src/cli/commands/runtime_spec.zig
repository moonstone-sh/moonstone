const std = @import("std");
pub fn isOfficial(spec: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, spec, '@') orelse spec.len;
    const name = spec[0..at];
    for ([_][]const u8{ "lua", "luajit", "love", "moonstone/lua", "moonstone/luajit", "moonstone/love" }) |runtime| {
        if (std.mem.eql(u8, name, runtime)) return true;
    }
    return false;
}
test "runtime recognition preserves other packages and resolver prefixes" {
    for ([_][]const u8{ "lua@5.4", "moonstone/luajit@2.1", "love@11.5" }) |spec| try std.testing.expect(isOfficial(spec));
    for ([_][]const u8{ "rocks:lua", "path:lua", "org/lua", "luajit-tools" }) |spec| try std.testing.expect(!isOfficial(spec));
}
