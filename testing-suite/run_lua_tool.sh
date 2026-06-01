#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${PROJECT_ROOT}/testing-suite/lua-tools"

if [[ "${1:-}" == "generate-mock-rocks" ]]; then
    shift
    exec python3 "${PROJECT_ROOT}/testing-suite/generate-mock-rocks.py" "$@"
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

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/install_synthetic.sh"
fi

MARKER="${MOONSTONE_HOME}/.lua-tools-installed"
if [[ ! -f "${MARKER}" || "${TOOLS_DIR}/moonstone.toml" -nt "${MARKER}" || ! -f "${TOOLS_DIR}/moonstone.lock" || ! -d "${TOOLS_DIR}/.moonstone/env" ]]; then
    (
        cd "${TOOLS_DIR}"
        moon use lua@5.4
        moon add rocks:dkjson --no-install
        moon add rocks:luafilesystem --no-install
        moon add rocks:luasocket --no-install
        moon install >/dev/null
    )
    mkdir -p "$(dirname "${MARKER}")"
    touch "${MARKER}"
fi

cd "${TOOLS_DIR}"
exec moon run tool -- "$@"
