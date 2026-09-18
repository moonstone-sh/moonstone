#!/usr/bin/env bash
set -euo pipefail

# Test: `moon exec --global -- <tool> <relative-path>` must resolve that
# relative path against the CALLER's real current directory, not against
# moonstone's own internal global-tools bookkeeping project.
#
# Regression: exec.zig's --global handling (global_tools.zig's enterProject)
# changes the WHOLE PROCESS's CWD to the global-tools bookkeeping directory
# before resolving the tool's environment, then replaces the current process
# image with the child (`std.process.replace`, an execve-style call that
# never returns and has no `cwd` option -- it inherits whatever the CURRENT
# process CWD is at that exact moment). Since that CWD was never restored
# before the child actually ran, a relative positional argument the user
# typed (e.g. `hydronium-create ./my-app`) silently resolved against
# ~/.local/share/moonstone/projects/global-tools instead of the directory
# the user was actually standing in -- with no error, just files landing in
# the wrong place while the tool's own success message echoed the path
# verbatim and looked correct.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

WORKDIR="$(mktemp -d /tmp/moonstone-exec-global-relative-cwd.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

# A minimal tool that writes a marker file to whatever relative path it's
# given, exactly mirroring how a real scaffolding tool like hydronium-create
# resolves its own positional directory argument against its process CWD.
mkdir -p "${WORKDIR}/tool/src"
cat > "${WORKDIR}/tool/moonstone.toml" <<'TOML'
manifest_version = 2

[package]
name = "relative-writer-tool"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4.6"
abi = "5.4"
TOML

cat > "${WORKDIR}/tool/src/main.lua" <<'LUA'
local target = arg[1]
local f = assert(io.open(target, "w"))
f:write("marker\n")
f:close()
print("wrote " .. target)
LUA

(cd "${WORKDIR}/tool" && "${MOON_BIN}" link >/dev/null)

# The "caller": a clean directory standing in for wherever the user's real
# shell actually is when they run `moon exec --global`.
mkdir -p "${WORKDIR}/caller"

(cd "${WORKDIR}/caller" && "${MOON_BIN}" add --global --tool "link:relative-writer-tool" >/dev/null)

(cd "${WORKDIR}/caller" && "${MOON_BIN}" exec --global -- relative-writer-tool ./marker.txt >/dev/null)

if [[ ! -f "${WORKDIR}/caller/marker.txt" ]]; then
    echo "Fail: expected ./marker.txt to be created in the caller's own directory (${WORKDIR}/caller)" >&2
    echo "Actual caller directory contents:" >&2
    ls -la "${WORKDIR}/caller" >&2
    # Surface where it actually landed, if findable, to make the failure obvious.
    found="$(find "${MOONSTONE_DATA:-$HOME/.local/share/moonstone}" -maxdepth 6 -iname 'marker.txt' 2>/dev/null | head -1)"
    if [[ -n "${found}" ]]; then
        echo "Found it instead at: ${found}" >&2
    fi
    exit 1
fi

echo "━━━ ✓ moon exec --global resolves relative arguments against the caller's CWD ━━━"
