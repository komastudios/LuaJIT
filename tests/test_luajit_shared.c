/* Smoke test against the prebuilt shared library loaded at runtime via
 * dlopen/LoadLibraryA. Resolves the minimum Lua 5.1 C API needed to eval
 * `return 1 + 2` by symbol name, runs it, tears down. The absolute path to
 * the shared library is passed as argv[1]. */

#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
#  include <windows.h>
   typedef HMODULE lib_t;
   static lib_t      lib_open(const char *p) { return LoadLibraryA(p); }
   static void      *lib_sym(lib_t h, const char *s) { return (void*)GetProcAddress(h, s); }
   static void       lib_close(lib_t h) { FreeLibrary(h); }
   static const char *lib_err(void) {
       static char buf[64];
       snprintf(buf, sizeof(buf), "GetLastError=%lu", (unsigned long)GetLastError());
       return buf;
   }
#else
#  include <dlfcn.h>
   typedef void *lib_t;
   static lib_t      lib_open(const char *p) { return dlopen(p, RTLD_NOW | RTLD_LOCAL); }
   static void      *lib_sym(lib_t h, const char *s) { return dlsym(h, s); }
   static void       lib_close(lib_t h) { dlclose(h); }
   static const char *lib_err(void) { const char *e = dlerror(); return e ? e : "(null)"; }
#endif

/* Opaque handle + minimal function pointer signatures. */
typedef struct lua_State lua_State;
typedef lua_State *(*fn_newstate_t)(void);
typedef void       (*fn_openlibs_t)(lua_State*);
typedef int        (*fn_loadstring_t)(lua_State*, const char*);
typedef int        (*fn_pcall_t)(lua_State*, int, int, int);
typedef double     (*fn_tonumber_t)(lua_State*, int);
typedef int        (*fn_isnumber_t)(lua_State*, int);
typedef void       (*fn_close_t)(lua_State*);

#define RESOLVE(var, name) do {                                              \
    *(void**)&var = lib_sym(h, name);                                        \
    if (!var) {                                                              \
        fprintf(stderr, "symbol '%s' not found: %s\n", name, lib_err());     \
        lib_close(h);                                                        \
        return 1;                                                            \
    }                                                                        \
} while (0)

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <shared-library-path>\n", argv[0]);
        return 2;
    }

    lib_t h = lib_open(argv[1]);
    if (!h) {
        fprintf(stderr, "cannot open %s: %s\n", argv[1], lib_err());
        return 1;
    }

    fn_newstate_t   fn_newstate;
    fn_openlibs_t   fn_openlibs;
    fn_loadstring_t fn_loadstring;
    fn_pcall_t      fn_pcall;
    fn_tonumber_t   fn_tonumber;
    fn_isnumber_t   fn_isnumber;
    fn_close_t      fn_close;

    RESOLVE(fn_newstate,   "luaL_newstate");
    RESOLVE(fn_openlibs,   "luaL_openlibs");
    RESOLVE(fn_loadstring, "luaL_loadstring");
    RESOLVE(fn_pcall,      "lua_pcall");
    RESOLVE(fn_tonumber,   "lua_tonumber");
    RESOLVE(fn_isnumber,   "lua_isnumber");
    RESOLVE(fn_close,      "lua_close");

    lua_State *L = fn_newstate();
    if (!L) {
        fprintf(stderr, "luaL_newstate returned NULL\n");
        lib_close(h);
        return 1;
    }
    fn_openlibs(L);

    if (fn_loadstring(L, "return 1 + 2") != 0) {
        fprintf(stderr, "luaL_loadstring failed\n");
        fn_close(L); lib_close(h); return 1;
    }
    if (fn_pcall(L, 0, 1, 0) != 0) {
        fprintf(stderr, "lua_pcall failed\n");
        fn_close(L); lib_close(h); return 1;
    }
    if (!fn_isnumber(L, -1)) {
        fprintf(stderr, "result not a number\n");
        fn_close(L); lib_close(h); return 1;
    }

    double got = fn_tonumber(L, -1);
    if (got != 3.0) {
        fprintf(stderr, "expected 3.0, got %g\n", got);
        fn_close(L); lib_close(h); return 1;
    }

    fprintf(stdout, "shared test OK: 1 + 2 = %g (loaded %s)\n", got, argv[1]);
    fn_close(L);
    lib_close(h);
    return 0;
}
