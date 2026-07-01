#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

if [[ ! -x "${MOON_BIN}" ]]; then
    echo "ERROR: moon binary not found at ${MOON_BIN}"
    echo "Run: zig build"
    exit 1
fi

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

cat > "${MOONSTONE_CONFIG}/config.toml" << EOF
store = "${MOONSTONE_DATA}/store/v0"
index = "${MOONSTONE_DATA}/index/v0"
cache = "${MOONSTONE_CACHE}"
downloads = "${MOONSTONE_CACHE}/downloads"
shims = "${MOONSTONE_DATA}/v0/shims"

[registries.synthetic]
path = "${SCRIPT_DIR}/registry"
priority = 100
EOF

PASS=0
FAIL=0

run_cmd() {
    local label="$1"
    shift
    echo ""
    echo "━━━ ${label} ━━━"
    if "$@"; then
        echo "  ✓ ${label}"
        ((PASS+=1))
    else
        echo "  ✗ ${label}"
        ((FAIL+=1))
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Flow 1: Local live link
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Flow 1: Local live link"
echo "═══════════════════════════════════════════════════════════════════"

run_cmd "register my-lib" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-lib" && moon link'

run_cmd "consume my-lib in my-app" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon add link:my-lib --no-sync'

run_cmd "install my-app with live link" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon sync'

run_cmd "check env has live symlink" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && test -L .moonstone/env/share/lua/5.4/my_lib/init.lua || test -d .moonstone/env/share/lua/5.4/my_lib'

# ═══════════════════════════════════════════════════════════════════
# Flow 2: Registry install (requires working resolver + materializer)
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Flow 2: Registry install"
echo "═══════════════════════════════════════════════════════════════════"

# Reset my-app
rm -rf "${SCRIPT_DIR}/my-app/.moonstone"
cat > "${SCRIPT_DIR}/my-app/moonstone.toml" << 'EOF'
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
EOF

run_cmd "use lua 5.4" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon interpreter set lua@5.4 --no-sync'

run_cmd "add inspect" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon add inspect --no-sync'

run_cmd "install from registry" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon sync'

# ═══════════════════════════════════════════════════════════════════
# Flow 3: Artifact-mode local link
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Flow 3: Artifact-mode local link"
echo "═══════════════════════════════════════════════════════════════════"

# Reset my-app again
rm -rf "${SCRIPT_DIR}/my-app/.moonstone"
cat > "${SCRIPT_DIR}/my-app/moonstone.toml" << 'EOF'
[package]
name = "my-app"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]
EOF

run_cmd "register my-lib" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-lib" && moon link --force'

run_cmd "add link:my-lib" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon add link:my-lib --no-sync'

run_cmd "install with artifact link" \
    bash -c 'cd "'"${SCRIPT_DIR}"'/my-app" && moon sync'

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
