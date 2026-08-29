#!/usr/bin/env bash
set -euo pipefail

readonly REPO=/moonstone
readonly MOON="${REPO}/zig-out/bin/moon.exe"

usage() {
    cat <<'USAGE'
Usage: tests/windows/run-wine.sh [core]

Runs a Windows-specific Moonstone contract through Wine.  This is deliberately
separate from core.ps1: the latter remains the native Windows contract while
this harness makes its executable, environment projection, launcher lookup,
and DLL-loader coverage reproducible from macOS and Linux.
USAGE
}

suite="${1:-core}"
case "${suite}" in
    core) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

prefix_root="$(mktemp -d)"
trap 'rm -rf "${prefix_root}"' EXIT

export WINEDEBUG=-all
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEARCH=win64
export WINEPREFIX="${prefix_root}/wine-prefix"
# Keep human CLI output deterministic in this CI/local compatibility harness.
export MOONSTONE_NO_PROGRESS=1

if command -v wine64 >/dev/null 2>&1; then
    readonly WINE_BIN=wine64
else
    readonly WINE_BIN=wine
fi

wine_run() {
    xvfb-run -a "${WINE_BIN}" "$@"
}

# Initialize the 64-bit prefix once. Minimal Wine installations can emit a
# harmless syswow64/rundll32 warning while still creating a valid win64 prefix;
# retain the log only when initialization genuinely fails.
wine_boot_log="${prefix_root}/wineboot.log"
if ! xvfb-run -a wineboot -u >"${wine_boot_log}" 2>&1; then
    cat "${wine_boot_log}" >&2
    exit 1
fi

windows_path() {
    winepath -w "$1"
}

# Keep project files on Wine's host-backed Z: drive.  This lets Zig's file I/O
# access the fixture directly while Moonstone's Windows CWD wrapper handles the
# drive path correctly.
work="${prefix_root}/work"
mkdir -p "${work}"
project="${work}/project"
mkdir -p "${project}"

export MOONSTONE_HOME="$(windows_path "${work}/moonstone-home")"
export MOONSTONE_DATA="$(windows_path "${work}/moonstone-data")"
export MOONSTONE_CACHE="$(windows_path "${work}/moonstone-cache")"
export MOONSTONE_CONFIG="$(windows_path "${work}/moonstone-config")"
export USERPROFILE="$(windows_path "${work}/home")"
export HOME="${USERPROFILE}"

project_win="$(windows_path "${project}")"
cp "${MOON}" "${work}/moon.exe"
moon_win="$(windows_path "${work}/moon.exe")"

wine_moon() {
    wine_run "${moon_win}" "$@"
}

# Wine does not ship Git. This is the exact optional-tool absence seen by a
# fresh Windows Moonstone user: init must leave a usable project and succeed.
init_output="$(wine_moon init "${project_win}" --name windows-core --kind script --interpreter lua@5.4 --no-sync)"
[[ "${init_output}" == *"skipped Git initialization"* ]] || {
    echo "moon init did not report nonfatal missing Git" >&2
    exit 1
}

# Stage a runtime in the local immutable store so sync performs a real Windows
# runtime projection without relying on public-network registry availability.
# native-loader-probe.exe loads nativeprobe.dll from beside the launcher; when
# symlink creation is denied, the projection fallback must copy that sibling.
runtime_hash='b3:1111111111111111111111111111111111111111111111111111111111111111'
runtime_store="${work}/moonstone-data/store/v0/b3/11/11/111111111111111111111111111111111111111111111111111111111111-lua-5.4.9"
mkdir -p "${runtime_store}/files/bin"
cp /opt/wine-probes/native-loader-probe.exe "${runtime_store}/files/bin/lua.exe"
cp /opt/wine-probes/nativeprobe.dll "${runtime_store}/files/bin/nativeprobe.dll"
cat >"${runtime_store}/manifest.toml" <<TOML
[artifact]
name = "moonstone/lua"
version = "5.4.9"
kind = "runtime"
source_hash = ""
recipe_hash = ""
artifact_hash = "${runtime_hash}"
target = "x86_64-windows-gnu"

[origin]
resolver = "moonstone"
source = ""

[compat]
runtime_version = "lua@5.4.9"
lua_abi = "lua54"
interpreter_artifact_hash = ""

[provides]
runtime = [{ name = "lua", version = "5.4.9", abi = "lua54" }]
bin = [{ name = "lua", path = "bin/lua.exe" }]
TOML
wine_moon index rebuild

cat >"${project}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "windows-core"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.9"
abi = "5.4"

[scripts]
check = "lua"
TOML

wine_moon -C "${project_win}" sync --offline
test -f "${project}/.moonstone/env/bin/lua.exe"
test -f "${project}/.moonstone/env/bin/nativeprobe.dll"
wine_moon -C "${project_win}" run check

# A symlinked launcher loads the DLL from the store; a copied launcher needs
# the fallback's local copy. Assert the latter whenever Wine/native Windows did
# not create a reparse-point projection.
if ! test -L "${project}/.moonstone/env/bin/lua.exe"; then
    test -f "${project}/.moonstone/env/bin/nativeprobe.dll"
fi

manifest="$(wine_moon -C "${project_win}" manifest export --json)"
[[ "${manifest}" == *'"windows-core"'* ]] || {
    echo "manifest export through -C failed" >&2
    exit 1
}

scripts="$(wine_moon "--directory=${project_win}" manifest script list --json)"
[[ "${scripts}" == *'"check"'* ]] || {
    echo "script inspection through --directory failed" >&2
    exit 1
}

environment="$(wine_moon -C "${project_win}" env --json)"
[[ "${environment}" == *'?.dll'* ]] || {
    echo "Windows Lua C module projection did not use .dll paths" >&2
    exit 1
}

wine_moon -C "${project_win}" run check
wine_moon -C "${project_win}" exec cmd /d /s /c 'exit /b 0'

cmd_exe="$(winepath -u 'C:\\windows\\system32\\cmd.exe')"
cp "${cmd_exe}" "${project}/.moonstone/env/bin/probe.exe"
wine_moon -C "${project_win}" exec probe /d /s /c 'exit /b 0'

cat >"${project}/.moonstone/env/bin/live-tool.cmd" <<'CMD'
@echo off
exit /b 0
CMD
wine_moon -C "${project_win}" exec live-tool

cat >"${project}/.moonstone/env/bin/live-tool-bat.bat" <<'BAT'
@echo off
exit /b 0
BAT
wine_moon -C "${project_win}" exec live-tool-bat

native_library_dir="${project}/.moonstone/env/lib/native"
mkdir -p "${native_library_dir}"
cp /opt/wine-probes/nativeprobe.dll "${native_library_dir}/nativeprobe.dll"
cp /opt/wine-probes/native-loader-probe.exe "${project}/.moonstone/env/bin/native-loader-probe.exe"

native_environment="$(wine_moon -C "${project_win}" env --json)"
[[ "${native_environment}" == *'lib\\native'* || "${native_environment}" == *'lib/native'* ]] || {
    echo "native library environment path was not exposed" >&2
    exit 1
}
native_output="$(wine_moon -C "${project_win}" exec native-loader-probe)"
[[ "${native_output}" == *'native loader projected'* ]] || {
    echo "native DLL was not visible through Moonstone PATH projection" >&2
    exit 1
}

echo 'PASS: Moonstone Wine core CLI, projection, launcher, and native DLL loader smoke test'
