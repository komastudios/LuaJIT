# Smoke tests for a staged LuaJIT-unity CI artifact.
#
# Two executables:
#   test_luajit_static  — statically links the prebuilt libluajit-static
#   test_luajit_shared  — dlopen/LoadLibraryA's the prebuilt shared library
#                         (only built when a shared lib exists in STAGE_DIR)
#
# Invocation (see .github/scripts/build-luajit.sh):
#   cmake -S tests -B tests-build -G Ninja -DSTAGE_DIR=/abs/path/to/dist
#   cmake --build tests-build --config Release
#   ctest --test-dir tests-build --output-on-failure
#
# STAGE_DIR is the directory build-luajit.sh just populated: it must contain
# include/{lua.h,...} and lib/{libluajit-static.*[, libluajit.*]} (and on
# Windows bin/luajit.dll for the shared runtime).

cmake_minimum_required(VERSION 3.21)
project(luajit_tests LANGUAGES C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT STAGE_DIR)
    message(FATAL_ERROR "STAGE_DIR is required (pass -DSTAGE_DIR=/abs/path/to/dist)")
endif()
get_filename_component(STAGE_DIR "${STAGE_DIR}" ABSOLUTE)
message(STATUS "STAGE_DIR = ${STAGE_DIR}")

# ---- Resolve staged artifacts ------------------------------------------------
set(LUAJIT_INCLUDE_DIR "${STAGE_DIR}/include")
if(NOT EXISTS "${LUAJIT_INCLUDE_DIR}/lua.h")
    message(FATAL_ERROR "lua.h not found at ${LUAJIT_INCLUDE_DIR}")
endif()

# MSVC names the static archive luajit-static.lib; everywhere else it's
# libluajit-static.a. Providing both stems covers both prefix conventions.
find_library(LUAJIT_STATIC_LIB
    NAMES luajit-static libluajit-static
    PATHS "${STAGE_DIR}/lib"
    NO_DEFAULT_PATH
    REQUIRED)
message(STATUS "static library: ${LUAJIT_STATIC_LIB}")

# Shared library runtime (optional — absent on Android/iOS/WebGL artifacts).
if(WIN32)
    find_file(LUAJIT_SHARED_RUNTIME
        NAMES luajit.dll
        PATHS "${STAGE_DIR}/bin"
        NO_DEFAULT_PATH)
elseif(APPLE)
    find_file(LUAJIT_SHARED_RUNTIME
        NAMES libluajit.dylib
        PATHS "${STAGE_DIR}/lib"
        NO_DEFAULT_PATH)
else()
    find_file(LUAJIT_SHARED_RUNTIME
        NAMES libluajit.so
        PATHS "${STAGE_DIR}/lib"
        NO_DEFAULT_PATH)
endif()
message(STATUS "shared runtime:  ${LUAJIT_SHARED_RUNTIME}")

# ---- test_luajit_static ------------------------------------------------------
add_executable(test_luajit_static test_luajit_static.c)
target_include_directories(test_luajit_static PRIVATE "${LUAJIT_INCLUDE_DIR}")
target_link_libraries(test_luajit_static PRIVATE "${LUAJIT_STATIC_LIB}")

# LuaJIT's static build depends on libm (and libdl on Linux for package.loadlib).
if(UNIX AND NOT APPLE)
    target_link_libraries(test_luajit_static PRIVATE m dl)
elseif(APPLE)
    target_link_libraries(test_luajit_static PRIVATE m)
endif()

add_test(NAME test_luajit_static COMMAND test_luajit_static)

# ---- test_luajit_shared ------------------------------------------------------
if(LUAJIT_SHARED_RUNTIME)
    add_executable(test_luajit_shared test_luajit_shared.c)
    if(UNIX)
        target_link_libraries(test_luajit_shared PRIVATE ${CMAKE_DL_LIBS})
    endif()
    add_test(NAME test_luajit_shared
             COMMAND test_luajit_shared "${LUAJIT_SHARED_RUNTIME}")
endif()

include(CTest)
