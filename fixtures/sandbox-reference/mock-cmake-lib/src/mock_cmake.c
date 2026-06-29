#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>

static int hello(lua_State *L) {
    lua_pushstring(L, "hello from cmake module");
    return 1;
}

int luaopen_mock_cmake(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, hello);
    lua_setfield(L, -2, "hello");
    return 1;
}
