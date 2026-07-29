#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

# ──────────────
# 1. Validate moon binary exists
# ──────────────
if [[ ! -x "${MOON_BIN}" ]]; then
    echo "ERROR: moon binary not found at ${MOON_BIN}"
    echo "Run: zig build"
    exit 1
fi

# ──────────────
# 2. Set up disposable environment
# ──────────────
export MOONSTONE_HOME="/tmp/moonstone-synthetic-home"
export MOONSTONE_CONFIG="${MOONSTONE_HOME}/config"
export MOONSTONE_DATA="${MOONSTONE_HOME}/data"
export MOONSTONE_CACHE="${MOONSTONE_HOME}/cache"
export MOONSTONE_REGISTRY_PATH="${SCRIPT_DIR}/registry"
export XDG_CONFIG_HOME="${MOONSTONE_HOME}/xdg-config"
export XDG_DATA_HOME="${MOONSTONE_HOME}/xdg-data"
export XDG_CACHE_HOME="${MOONSTONE_HOME}/xdg-cache"
export PATH="${MOON_BIN%/*}:${PATH}"

rm -rf "${MOONSTONE_HOME}"
mkdir -p "${MOONSTONE_CONFIG}/links"
mkdir -p "${MOONSTONE_DATA}/store/v0"
mkdir -p "${MOONSTONE_DATA}/index/v0"
mkdir -p "${MOONSTONE_DATA}/tmp"
mkdir -p "${MOONSTONE_CACHE}/downloads"
mkdir -p "${MOONSTONE_DATA}/v0/shims"
mkdir -p "${XDG_CONFIG_HOME}"
mkdir -p "${XDG_DATA_HOME}"
mkdir -p "${XDG_CACHE_HOME}"

# ──────────────
# 3. Write minimal config.toml
# ──────────────
cat > "${MOONSTONE_CONFIG}/config.toml" << EOF
store = "${MOONSTONE_DATA}/store/v0"
index = "${MOONSTONE_DATA}/index/v0"
cache = "${MOONSTONE_CACHE}"
downloads = "${MOONSTONE_CACHE}/downloads"
shims = "${MOONSTONE_DATA}/v0/shims"

EOF

# ──────────────
# 4. Print banner
# ──────────────
cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║                 MOONSTONE SYNTHETIC PLAYGROUND                     ║
╠══════════════════════════════════════════════════════════════════╣
║  Environment is isolated under /tmp/moonstone-synthetic-home       ║
║  Never touches ~/.moonstone, global registries, or real store.   ║
╚══════════════════════════════════════════════════════════════════╝
BANNER

echo ""
echo "  moon binary:  ${MOON_BIN}"
echo "  MOONSTONE_HOME: ${MOONSTONE_HOME}"
echo "  PATH updated:   ${MOON_BIN%/*}"
echo ""
echo "  Available test projects:"
echo "    ${SCRIPT_DIR}/my-lib    (library package)"
echo "    ${SCRIPT_DIR}/my-app    (consumer app)"
echo ""
echo "  Registry (local):"
echo "    ${SCRIPT_DIR}/registry/"
echo ""
echo "  Quick start:"
echo "    cd ${SCRIPT_DIR}/my-lib && moon link"
echo "    cd ${SCRIPT_DIR}/my-app && moon add link:my-lib"
echo "    cd ${SCRIPT_DIR}/my-app && moon sync"
echo ""
echo "  Run integration tests:"
echo "    cd ${SCRIPT_DIR} && ./RUN_SYNTHETIC_TESTS.sh"
echo ""

# ──────────────
# 5. Shell integration
# ──────────────
if command -v moon >/dev/null 2>&1; then
    echo "  moon --version: $(moon --version 2>/dev/null || echo 'N/A')"
    echo ""
fi

# Drop into a subshell so the env vars survive
exec bash --rcfile <(
    echo 'export PS1="\[\e[36m\][synthetic]\[\e[0m\] $ "'
    echo "export PATH=\"${PATH}\""
    echo "export MOONSTONE_HOME=\"${MOONSTONE_HOME}\""
    echo "export MOONSTONE_CONFIG=\"${MOONSTONE_CONFIG}\""
    echo "export MOONSTONE_DATA=\"${MOONSTONE_DATA}\""
    echo "export MOONSTONE_CACHE=\"${MOONSTONE_CACHE}\""
    echo "export MOONSTONE_REGISTRY_PATH=\"${MOONSTONE_REGISTRY_PATH}\""
    echo "export PROJECT_ROOT=\"${PROJECT_ROOT}\""
    echo "export SCRIPT_DIR=\"${SCRIPT_DIR}\""
    echo "cd \"${SCRIPT_DIR}\""
) -i
