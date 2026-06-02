#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${PROJECT_ROOT}/testing-suite/lua-tools"
TOOLS_HOME="${MOONSTONE_TOOLS_HOME:-/tmp/moonstone-testing-tools-home}"

if [[ -x "${PROJECT_ROOT}/zig-out/bin/moon" ]]; then
    MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
else
    MOON_BIN="$(command -v moon || true)"
fi

if [[ -z "${MOON_BIN}" ]]; then
    echo "ERROR: moon binary not found. Run 'zig build' or install Moonstone." >&2
    exit 1
fi

if [[ "${1:-}" == "help" ]]; then
    cat <<'EOF'
moon-tools commands:
  generate-mock-rocks <dir> <port> [--mode MODE]
  generate-sandbox
  registry-builder
  registry-verify
  fetch-registry-artifacts
EOF
    exit 0
fi

mkdir -p "${TOOLS_HOME}"
cd "${TOOLS_DIR}"
export HOME="${TOOLS_HOME}"
export MOONSTONE_HOME="${TOOLS_HOME}"
export MOONSTONE_CONFIG="${TOOLS_HOME}/config"
export MOONSTONE_DATA="${TOOLS_HOME}/data"
export MOONSTONE_CACHE="${TOOLS_HOME}/cache"

SYNC_MARKER="${TOOLS_HOME}/lua-tools-sync.marker"
SYNC_KEY="$(cksum moonstone.toml)"
if [[ ! -x .moonstone/env/bin/lua || ! -f "${SYNC_MARKER}" || "$(cat "${SYNC_MARKER}")" != "${SYNC_KEY}" ]]; then
    env -u MOONSTONE_LUAROCKS_URL -u MOONSTONE_REGISTRY_PATH "${MOON_BIN}" sync
    printf '%s\n' "${SYNC_KEY}" > "${SYNC_MARKER}"
fi

exec "${MOON_BIN}" run tool -- "$@"
