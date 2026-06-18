const std = @import("std");

const lua_State = opaque {};
const lua_Integer = isize;
const lua_CFunction = *const fn (*lua_State) callconv(.c) c_int;

const LUA_TTABLE = 5;
const LUA_TFUNCTION = 6;

extern fn luaL_checklstring(L: *lua_State, arg: c_int, len: *usize) [*:0]const u8;
extern fn luaL_checkinteger(L: *lua_State, arg: c_int) lua_Integer;
extern fn luaL_checktype(L: *lua_State, arg: c_int, t: c_int) void;

extern fn lua_callk(L: *lua_State, nargs: c_int, nresults: c_int, ctx: isize, k: ?*anyopaque) void;
extern fn lua_createtable(L: *lua_State, narr: c_int, nrec: c_int) void;
extern fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
extern fn lua_pushcclosure(L: *lua_State, f: lua_CFunction, n: c_int) void;
extern fn lua_pushfstring(L: *lua_State, fmt: [*:0]const u8, ...) [*:0]const u8;
extern fn lua_pushinteger(L: *lua_State, n: lua_Integer) void;
extern fn lua_pushstring(L: *lua_State, s: [*:0]const u8) void;
extern fn lua_pushvalue(L: *lua_State, idx: c_int) void;
extern fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
extern fn lua_settop(L: *lua_State, idx: c_int) void;

fn helloFromZig(L: *lua_State) callconv(.c) c_int {
    var name_len: usize = 0;
    const name = luaL_checklstring(L, 1, &name_len);
    _ = lua_pushfstring(L, "Hello %s, from Zig!", name);
    return 1;
}

fn callLua(L: *lua_State) callconv(.c) c_int {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    lua_pushstring(L, "hello from Zig");
    lua_callk(L, 1, 1, 0, null);
    return 1;
}

fn newState(L: *lua_State) callconv(.c) c_int {
    const initial = luaL_checkinteger(L, 1);
    lua_createtable(L, 0, 1);
    lua_pushinteger(L, initial);
    lua_setfield(L, -2, "count");
    return 1;
}

fn increment(L: *lua_State) callconv(.c) c_int {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "count");
    const next = luaL_checkinteger(L, -1) + 1;
    lua_settop(L, 1);
    lua_pushinteger(L, next);
    lua_setfield(L, 1, "count");
    lua_pushinteger(L, next);
    return 1;
}

fn count(L: *lua_State) callconv(.c) c_int {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "count");
    return 1;
}

fn setFunction(L: *lua_State, name: [*:0]const u8, function: lua_CFunction) void {
    lua_pushcclosure(L, function, 0);
    lua_setfield(L, -2, name);
}

export fn luaopen_{{module_name}}_native(L: *lua_State) c_int {
    lua_createtable(L, 0, 5);
    setFunction(L, "hello_from_zig", helloFromZig);
    setFunction(L, "call_lua", callLua);
    setFunction(L, "new_state", newState);
    setFunction(L, "increment", increment);
    setFunction(L, "count", count);
    return 1;
}
