#!/usr/bin/env bash
# Build LuaJIT for one target and stage it into $STAGE (default: dist/)
# in the layout consumed by AutobahnRacer/download_plugins.ps1.
#
# Required env: TARGET       one of the target names enumerated below
# Optional env: STAGE        output directory (default: dist)
#               NDK_BIN      override NDK toolchain bin dir for Android targets
#               SOURCE_DATE_EPOCH  passed through for deterministic archives

set -euo pipefail

SRC="$(cd "$(dirname "$0")/../.." && pwd)/src"
STAGE="${STAGE:-$(pwd)/dist}"
NAME_STATIC="libluajit-static.a"

die() { echo "build-luajit.sh: $*" >&2; exit 1; }

nproc_portable() {
    if command -v nproc >/dev/null 2>&1; then nproc
    else sysctl -n hw.ncpu 2>/dev/null || echo 4
    fi
}

stage_headers() {
    mkdir -p "$STAGE/include"
    install -m 644 "$SRC/lua.h" "$SRC/lualib.h" "$SRC/lauxlib.h" \
                   "$SRC/luaconf.h" "$SRC/luajit.h" "$STAGE/include/"
}

# For the emscripten-wasm target: stage headers from the vendored Lua 5.1.5
# tree instead of LuaJIT (LuaJIT has no WASM backend). Vanilla Lua 5.1.x is
# API+ABI compatible with LuaJIT, so downstream P/Invoke code keeps working
# against the same symbol names (lua_newstate, luaL_openlibs, etc).
stage_headers_vendored_lua() {
    local LUASRC="$1"
    mkdir -p "$STAGE/include"
    install -m 644 "$LUASRC/lua.h" "$LUASRC/lualib.h" "$LUASRC/lauxlib.h" \
                   "$LUASRC/luaconf.h" "$STAGE/include/"
}

# Common XCFLAGS for reproducibility (GCC/Clang only).
# Siblings pass -ffile-prefix-map via CMake; replicate here.
REPRO_XCFLAGS="-ffile-prefix-map=$(cd "$SRC/.." && pwd)=."

J="$(nproc_portable)"

# Build + run the smoke tests against the freshly staged artifact.
# Called only for native-host targets where the test binary can actually
# be linked and executed on the CI runner (not Android/iOS/Emscripten).
run_smoke_tests() {
    local REPO_ROOT TESTS_SRC TESTS_BUILD
    REPO_ROOT="$(cd "$SRC/.." && pwd)"
    TESTS_SRC="$REPO_ROOT/tests"
    TESTS_BUILD="$(pwd)/tests-build"

    rm -rf "$TESTS_BUILD"
    cmake -S "$TESTS_SRC" -B "$TESTS_BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DSTAGE_DIR="$STAGE"
    cmake --build "$TESTS_BUILD" --config Release --parallel
    ctest --test-dir "$TESTS_BUILD" --output-on-failure
}

case "${TARGET:?TARGET env var is required}" in

    linux-x64)
        make -C "$SRC" clean
        make -C "$SRC" -j"$J" BUILDMODE=mixed \
            XCFLAGS="$REPRO_XCFLAGS"
        mkdir -p "$STAGE/lib"
        cp "$SRC/libluajit.so" "$STAGE/lib/libluajit.so"
        cp "$SRC/libluajit.a"  "$STAGE/lib/$NAME_STATIC"
        stage_headers
        run_smoke_tests
        ;;

    macos-universal)
        # Two separate builds (LuaJIT can only target one arch per make run),
        # then lipo-merge into a single universal artifact.
        export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.13}"
        for ARCH in arm64 x86_64; do
            make -C "$SRC" clean
            make -C "$SRC" -j"$J" BUILDMODE=mixed \
                TARGET_FLAGS="-arch $ARCH" \
                XCFLAGS="$REPRO_XCFLAGS"
            mkdir -p "build-$ARCH"
            # On Darwin the file is named libluajit.so but is a Mach-O dylib.
            cp "$SRC/libluajit.so" "build-$ARCH/libluajit.dylib"
            cp "$SRC/libluajit.a"  "build-$ARCH/libluajit.a"
        done
        mkdir -p "$STAGE/lib"
        lipo -create build-arm64/libluajit.dylib build-x86_64/libluajit.dylib \
             -output "$STAGE/lib/libluajit.dylib"
        lipo -create build-arm64/libluajit.a build-x86_64/libluajit.a \
             -output "$STAGE/lib/$NAME_STATIC"
        stage_headers
        run_smoke_tests
        ;;

    windows-x64-mingw)
        # Runs inside MSYS2 mingw64 shell; TARGET_SYS auto-detects Windows.
        make -C "$SRC" clean
        make -C "$SRC" -j"$J" BUILDMODE=dynamic \
            XCFLAGS="$REPRO_XCFLAGS"
        mkdir -p "$STAGE/bin" "$STAGE/lib"
        cp "$SRC/lua51.dll" "$STAGE/bin/luajit.dll"
        # MinGW also emits an import lib (libluajit-5.1.dll.a) — not consumed, skip.
        # Static build: second pass.
        make -C "$SRC" clean
        make -C "$SRC" -j"$J" BUILDMODE=static \
            XCFLAGS="$REPRO_XCFLAGS"
        cp "$SRC/libluajit.a" "$STAGE/lib/$NAME_STATIC"
        stage_headers
        run_smoke_tests
        ;;

    android-arm64|android-armv7|android-x86|android-x86_64)
        : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"
        NDK_BIN="${NDK_BIN:-$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin}"
        [ -x "$NDK_BIN/llvm-ar" ] || die "NDK toolchain not found at $NDK_BIN"

        case "$TARGET" in
            android-arm64)   CC_WRAPPER="aarch64-linux-android21-clang"   ; HOST_CC_OPT="gcc"       ;;
            android-x86_64)  CC_WRAPPER="x86_64-linux-android21-clang"    ; HOST_CC_OPT="gcc"       ;;
            android-armv7)   CC_WRAPPER="armv7a-linux-androideabi16-clang"; HOST_CC_OPT="gcc -m32"  ;;
            android-x86)     CC_WRAPPER="i686-linux-android16-clang"      ; HOST_CC_OPT="gcc -m32"  ;;
        esac

        make -C "$SRC" clean
        make -C "$SRC" -j"$J" BUILDMODE=static \
            HOST_CC="$HOST_CC_OPT" \
            CROSS= \
            STATIC_CC="$NDK_BIN/$CC_WRAPPER" \
            DYNAMIC_CC="$NDK_BIN/$CC_WRAPPER -fPIC" \
            TARGET_LD="$NDK_BIN/$CC_WRAPPER" \
            TARGET_AR="$NDK_BIN/llvm-ar rcus" \
            TARGET_STRIP="$NDK_BIN/llvm-strip" \
            TARGET_SYS=Linux \
            XCFLAGS="$REPRO_XCFLAGS"
        mkdir -p "$STAGE/lib"
        cp "$SRC/libluajit.a" "$STAGE/lib/$NAME_STATIC"
        stage_headers
        ;;

    emscripten-wasm)
        # LuaJIT has no WASM backend (per-arch assembly VM). Build vendored
        # vanilla Lua 5.1.5 instead — ABI-compatible with LuaJIT at the
        # lua_* symbol level, so downstream P/Invoke code still links.
        command -v emcc  >/dev/null 2>&1 || die "emcc not on PATH (emsdk not activated)"
        command -v emar  >/dev/null 2>&1 || die "emar not on PATH"

        LUAVENDOR="$(cd "$SRC/.." && pwd)/vendor/lua5.1/src"
        [ -f "$LUAVENDOR/lua.h" ] || die "vendored Lua sources not found at $LUAVENDOR"

        BUILD_DIR="$(pwd)/build-wasm"
        rm -rf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"

        # Library sources only: exclude standalone programs that contain main().
        LUA_LIB_SRC=$(cd "$LUAVENDOR" && ls *.c | grep -Ev '^(lua|luac|print)\.c$')

        (
            cd "$BUILD_DIR"
            # -DLUA_USE_POSIX enables the small handful of POSIX features
            # Lua's stdlibs expect (popen, gmtime_r, etc.) which Emscripten
            # provides via musl.
            for src in $LUA_LIB_SRC; do
                emcc -O2 -Wall -DLUA_USE_POSIX \
                    "$REPRO_XCFLAGS" \
                    -I"$LUAVENDOR" \
                    -c "$LUAVENDOR/$src" -o "${src%.c}.o"
            done
            emar rcs libluajit-static.a *.o
        )

        mkdir -p "$STAGE/lib"
        cp "$BUILD_DIR/libluajit-static.a" "$STAGE/lib/$NAME_STATIC"
        stage_headers_vendored_lua "$LUAVENDOR"
        ;;

    ios-arm64)
        SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
        CLANG="$(xcrun --sdk iphoneos -f clang)"
        IOS_FLAGS="-arch arm64 -isysroot $SDK_PATH -miphoneos-version-min=12.0"
        export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.13}"

        make -C "$SRC" clean
        make -C "$SRC" -j"$J" BUILDMODE=static \
            HOST_CC="cc" \
            CROSS= \
            STATIC_CC="$CLANG" \
            DYNAMIC_CC="$CLANG -fPIC" \
            TARGET_LD="$CLANG" \
            TARGET_AR="$(xcrun --sdk iphoneos -f ar) rcus" \
            TARGET_STRIP="$(xcrun --sdk iphoneos -f strip)" \
            TARGET_SYS=iOS \
            TARGET_FLAGS="$IOS_FLAGS" \
            XCFLAGS="$REPRO_XCFLAGS"
        mkdir -p "$STAGE/lib"
        cp "$SRC/libluajit.a" "$STAGE/lib/$NAME_STATIC"
        stage_headers
        ;;

    *)
        die "unknown TARGET: $TARGET"
        ;;
esac

echo "--- staged artifact tree ($STAGE) ---"
find "$STAGE" -type f | sort
