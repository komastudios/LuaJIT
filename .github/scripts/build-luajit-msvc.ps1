#!/usr/bin/env pwsh
# Build LuaJIT on Windows with MSVC. Expects the MSVC environment to already
# be primed (INCLUDE/LIB/PATH set) — use ilammy/msvc-dev-cmd before invoking.
#
# Deterministic-build flags are injected via the `CL` and `LINK` environment
# variables (set at the workflow-step level in .github/workflows/unity.yml);
# cl.exe and link.exe prepend their contents to every invocation, so
# msvcbuild.bat picks them up without modification.
#
# Produces the artifact layout consumed by AutobahnRacer/download_plugins.ps1:
#   dist/bin/luajit.dll
#   dist/lib/luajit.lib            (import lib for the dll)
#   dist/lib/luajit-static.lib     (fully static archive)
#   dist/include/{lua.h,lualib.h,lauxlib.h,luaconf.h,luajit.h}

[CmdletBinding()]
param(
    [string]$Stage = (Join-Path (Get-Location) "dist")
)

$ErrorActionPreference = "Stop"

if (-not $env:INCLUDE) {
    throw "MSVC environment is not active (INCLUDE is unset). Run ilammy/msvc-dev-cmd first."
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Src      = Join-Path $RepoRoot "src"

New-Item -ItemType Directory -Force -Path $Stage,(Join-Path $Stage "bin"),(Join-Path $Stage "lib"),(Join-Path $Stage "include") | Out-Null

Push-Location $Src
try {
    # Patch msvcbuild.bat's LJLIB variable to pass /Brepro to lib.exe. The
    # upstream script's static-archive step runs lib.exe directly, which does
    # NOT read the `LINK` env var — so the /Brepro we set at the workflow
    # level only reaches link.exe (DLL + import-lib builds), leaving the
    # static archive with per-run timestamps. The fix: regex-replace LJLIB's
    # definition in a sibling copy of the batch file and invoke that.
    $patchedBat = "msvcbuild-reprobuild.bat"
    (Get-Content "msvcbuild.bat" -Raw) `
        -replace '@set LJLIB=lib /nologo /nodefaultlib', '@set LJLIB=lib /nologo /nodefaultlib /Brepro' `
        | Set-Content -Path $patchedBat -NoNewline -Encoding ASCII

    try {
        Write-Host "=== Pass 1: dynamic build (lua51.dll + import lib) ==="
        & cmd /c $patchedBat
        if ($LASTEXITCODE -ne 0) { throw "msvcbuild.bat (dynamic) failed" }

        # Stash dynamic outputs under unique names so the static pass can't clobber them.
        Copy-Item -Force "lua51.dll" (Join-Path $Stage "bin/luajit.dll")
        Copy-Item -Force "lua51.lib" (Join-Path $Stage "lib/luajit.lib")

        # Wipe leftover outputs from pass 1 so pass 2 starts clean.
        Remove-Item -Force -ErrorAction SilentlyContinue `
            "lua51.dll","lua51.lib","lua51.exp","luajit.exe","*.pdb","*.ilk"

        Write-Host "=== Pass 2: static build (luajit-static.lib) ==="
        & cmd /c "$patchedBat static"
        if ($LASTEXITCODE -ne 0) { throw "msvcbuild.bat (static) failed" }

        # In static mode msvcbuild.bat writes the static archive as lua51.lib.
        if (-not (Test-Path "lua51.lib")) { throw "static build did not produce lua51.lib" }
        Copy-Item -Force "lua51.lib" (Join-Path $Stage "lib/luajit-static.lib")

        # Stage headers.
        foreach ($h in "lua.h","lualib.h","lauxlib.h","luaconf.h","luajit.h") {
            Copy-Item -Force $h (Join-Path $Stage "include" $h)
        }
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $patchedBat
    }
}
finally {
    Pop-Location
}

Write-Host "--- staged artifact tree ($Stage) ---"
Get-ChildItem -Recurse -File $Stage | ForEach-Object { $_.FullName }

Write-Host "=== Smoke tests ==="
$TestsSrc   = Join-Path $RepoRoot "tests"
$TestsBuild = Join-Path (Get-Location) "tests-build"
if (Test-Path $TestsBuild) { Remove-Item -Recurse -Force $TestsBuild }
& cmake -S $TestsSrc -B $TestsBuild -G Ninja -DCMAKE_BUILD_TYPE=Release "-DSTAGE_DIR=$Stage"
if ($LASTEXITCODE -ne 0) { throw "cmake configure (tests) failed" }
& cmake --build $TestsBuild --config Release
if ($LASTEXITCODE -ne 0) { throw "cmake build (tests) failed" }
& ctest --test-dir $TestsBuild --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "ctest failed" }
