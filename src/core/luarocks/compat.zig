const std = @import("std");
const c_api = @import("../runtime/c_api.zig");

pub const AppliedRecipe = struct {
    key: []const u8,
    value: []const u8,
};

const SourcePatchRule = struct {
    package_name: []const u8,
    runtime: c_api.Profile,
    source_file: []const u8,
    source_guard: []const u8,
    replacement: []const u8,
    recipe: AppliedRecipe,
};

const rules = [_]SourcePatchRule{
    .{
        .package_name = "lua-cjson",
        .runtime = .luajit_21,
        .source_file = "lua_cjson.c",
        .source_guard = "#if !defined(LUA_VERSION_NUM) || LUA_VERSION_NUM < 502",
        .replacement = "#if 0 /* Moonstone: LuaJIT already provides luaL_setfuncs. */",
        .recipe = .{
            .key = "MOONSTONE_COMPAT_LUA_CJSON_LUAJIT",
            .value = "1",
        },
    },
};

pub fn apply(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_name: []const u8,
    runtime: c_api.Profile,
    source_dir: []const u8,
) !?AppliedRecipe {
    if (matching_rule(package_name, runtime)) |rule| {
        const source_path = try std.fs.path.join(allocator, &.{ source_dir, rule.source_file });
        defer allocator.free(source_path);
        const source = std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer allocator.free(source);

        const patched = (try patch_source(allocator, source, rule)) orelse return null;
        defer allocator.free(patched);

        const source_file = try std.Io.Dir.cwd().createFile(io, source_path, .{});
        try source_file.writeStreamingAll(io, patched);
        source_file.close(io);
        return rule.recipe;
    }

    return null;
}

fn matching_rule(package_name: []const u8, runtime: c_api.Profile) ?SourcePatchRule {
    for (rules) |rule| {
        if (std.ascii.eqlIgnoreCase(package_name, rule.package_name) and runtime == rule.runtime) return rule;
    }
    return null;
}

fn patch_source(allocator: std.mem.Allocator, source: []const u8, rule: SourcePatchRule) !?[]u8 {
    if (std.mem.indexOf(u8, source, rule.source_guard) == null) return null;
    return try std.mem.replaceOwned(u8, allocator, source, rule.source_guard, rule.replacement);
}

test "legacy lua-cjson recipe disables its duplicate Lua 5.1 auxiliary API shim" {
    const allocator = std.testing.allocator;
    const source =
        "#if !defined(LUA_VERSION_NUM) || LUA_VERSION_NUM < 502\n" ++
        "static void luaL_setfuncs(void) {}\n" ++
        "#endif\n";
    const patched = (try patch_source(allocator, source, rules[0])).?;
    defer allocator.free(patched);

    try std.testing.expect(std.mem.indexOf(u8, patched, "LuaJIT already provides luaL_setfuncs") != null);
}

test "lua-cjson compatibility recipe is limited to LuaJIT 2.1" {
    try std.testing.expect(matching_rule("lua-cjson", .luajit_21) != null);
    try std.testing.expect(matching_rule("lua-cjson", .puc_lua_51) == null);
}
