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
mkdir -p "${project}/.moonstone/env/bin"

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

cat >"${project}/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "windows-core"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[scripts]
check = "exit /b 0"
TOML

cat >"${project}/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4"
abi = "lua54"
TOML

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
