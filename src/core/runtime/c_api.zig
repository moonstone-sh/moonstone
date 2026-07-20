const std = @import("std");

pub const Profile = enum {
    unknown,
    puc_lua_51,
    puc_lua_52,
    puc_lua_53,
    puc_lua_54,
    luajit_21,

    pub fn compilerDefine(self: Profile) ?[]const u8 {
        return switch (self) {
            .luajit_21 => "-DMOONSTONE_LUA_CAPI_LUAJIT_21=1",
            else => null,
        };
    }
};

pub fn fromRuntime(runtime_name: []const u8, lua_api: ?[]const u8, lua_abi: []const u8) Profile {
    if (std.ascii.endsWithIgnoreCase(runtime_name, "luajit")) return .luajit_21;
    if (std.ascii.indexOfIgnoreCase(runtime_name, "luajit") != null) return .luajit_21;

    const api = lua_api orelse lua_abi;
    if (std.mem.eql(u8, api, "5.1") or std.mem.eql(u8, api, "lua51") or std.mem.eql(u8, api, "lua-5.1")) return .puc_lua_51;
    if (std.mem.eql(u8, api, "5.2") or std.mem.eql(u8, api, "lua52") or std.mem.eql(u8, api, "lua-5.2")) return .puc_lua_52;
    if (std.mem.eql(u8, api, "5.3") or std.mem.eql(u8, api, "lua53") or std.mem.eql(u8, api, "lua-5.3")) return .puc_lua_53;
    if (std.mem.eql(u8, api, "5.4") or std.mem.eql(u8, api, "lua54") or std.mem.eql(u8, api, "lua-5.4")) return .puc_lua_54;
    return .unknown;
}

test "LuaJIT runtime identity wins over its Lua 5.1 ABI" {
    try std.testing.expectEqual(Profile.luajit_21, fromRuntime("moonstone/luajit", null, "lua51"));
}

test "PUC Lua API resolves without a runtime implementation override" {
    try std.testing.expectEqual(Profile.puc_lua_54, fromRuntime("moonstone/lua", "5.4", "lua54"));
}
