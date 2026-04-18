/* Smoke test against the statically-linked prebuilt LuaJIT (or vanilla Lua
 * 5.1.5 for the WebGL artifact). Creates a VM, evaluates a trivial script,
 * verifies the result, tears down. Uses only plain Lua 5.1 API so it compiles
 * against either interpreter. */

#include <stdio.h>
#include <stdlib.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

static int die(lua_State *L, const char *what) {
    fprintf(stderr, "%s: %s\n", what, lua_tostring(L, -1));
    lua_close(L);
    return 1;
}

int main(void) {
    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "luaL_newstate failed\n");
        return 1;
    }
    luaL_openlibs(L);

    if (luaL_loadstring(L, "return 1 + 2") != 0) return die(L, "load");
    if (lua_pcall(L, 0, 1, 0) != 0)              return die(L, "pcall");

    if (!lua_isnumber(L, -1)) {
        fprintf(stderr, "result not a number\n");
        lua_close(L);
        return 1;
    }

    lua_Number got = lua_tonumber(L, -1);
    if (got != 3) {
        fprintf(stderr, "expected 3, got %g\n", (double)got);
        lua_close(L);
        return 1;
    }

    fprintf(stdout, "static test OK: 1 + 2 = %g (%s)\n",
            (double)got, LUA_RELEASE);
    lua_close(L);
    return 0;
}
