#!/usr/bin/env bash
set -euo pipefail

# This script prepares the environment for synthetic tests.
# It sets up a disposable MOONSTONE_HOME and populates basic config.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
export SANDBOX_DIR="${PROJECT_ROOT}/fixtures/sandbox"

if [[ ! -x "${MOON_BIN}" ]]; then
    echo "ERROR: moon binary not found at ${MOON_BIN}"
    echo "Run: zig build"
    exit 1
fi

export MOONSTONE_HOME="/tmp/moonstone-synthetic-home"
export HOME="${MOONSTONE_HOME}"
export MOONSTONE_CONFIG="${MOONSTONE_HOME}/config"
export MOONSTONE_DATA="${MOONSTONE_HOME}/data"
export MOONSTONE_CACHE="${MOONSTONE_HOME}/cache"
export MOONSTONE_REGISTRY_PATH="${SANDBOX_DIR}/registry"
export XDG_CONFIG_HOME="${MOONSTONE_HOME}/xdg-config"
export XDG_DATA_HOME="${MOONSTONE_HOME}/xdg-data"
export XDG_CACHE_HOME="${MOONSTONE_HOME}/xdg-cache"
export PATH="${MOON_BIN%/*}:${PATH}"

ensure_mock_luarocks_archive() {
    local fixture_dir="${PROJECT_ROOT}/fixtures/sandbox-reference/mock-luarocks"
    local source_dir="${fixture_dir}/fakebin-1.0"
    local archive_path="${fixture_dir}/fakebin-1.0.tar.gz"

    if [[ -f "${archive_path}" ]]; then
        return
    fi
    if [[ ! -f "${source_dir}/fake.lua" ]]; then
        echo "ERROR: missing tracked mock LuaRocks source: ${source_dir}/fake.lua" >&2
        return 1
    fi

    tar -czf "${archive_path}" -C "${source_dir}" fake.lua
}

ensure_mock_luarocks_archive

echo "Cleaning up old synthetic home..."
rm -rf "${MOONSTONE_HOME}"

echo "Creating directory structure..."
mkdir -p "${MOONSTONE_CONFIG}/links"
mkdir -p "${MOONSTONE_DATA}/store/v0"
mkdir -p "${MOONSTONE_DATA}/index/v0"
mkdir -p "${MOONSTONE_DATA}/tmp"
mkdir -p "${MOONSTONE_CACHE}/downloads"
mkdir -p "${MOONSTONE_DATA}/v0/shims"
mkdir -p "${XDG_CONFIG_HOME}"
mkdir -p "${XDG_DATA_HOME}"
mkdir -p "${XDG_CACHE_HOME}"

echo "Writing config.toml..."
cat > "${MOONSTONE_CONFIG}/config.toml" << EOF
[moonstone]
default_runtime = "lua-5.4.7"

[paths]
store = "${MOONSTONE_DATA}/store/v0"
index = "${MOONSTONE_DATA}/index/v0"
cache = "${MOONSTONE_CACHE}"
downloads = "${MOONSTONE_CACHE}/downloads"
shims = "${MOONSTONE_DATA}/v0/shims"

EOF

echo "Preparation complete."
echo "MOONSTONE_HOME=${MOONSTONE_HOME}"
