#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks bin rock admission
# - Mocks a LuaRocks server
# - Adds a rock that provides a binary
# - Verifies the binary is installed and executable via moon exec

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

# 1. Start mock server in background
RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-bin"
rm -rf "${MOCK_DIR}"
mkdir -p "${MOCK_DIR}"

# Pre-install the Moonstone-managed Lua tools before launching the long-running mock server.
"${PROJECT_ROOT}/tests/run_lua_tool.sh" help >/dev/null
# 2. Mock luarocks upstream
"${PROJECT_ROOT}/tests/run_lua_tool.sh" generate-mock-rocks "${MOCK_DIR}" "${RANDOM_PORT}" &
MOCK_PID=$!
trap "kill $MOCK_PID 2>/dev/null || true" EXIT

# Give it a second to start
sleep 2

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"

cd "${SANDBOX_DIR}/my-app"
rm -rf .moonstone
rm -f moonstone.lock moonstone.toml

echo "━━━ moon init ━━━"
moon init . --name my-app --no-git

echo "━━━ add rocks:fakebin ━━━"
moon use lua@5.4
moon add rocks:fakebin
moon sync

echo "━━━ verify fakebin in list ━━━"
moon list | grep "fakebin"

echo "━━━ verify fakebin execution ━━━"
# The rock defines 'fake.lua' as a bin, which moon should shim as 'fake'
moon exec -- lua -e 'print("works")' | grep "works"
# The shim should be named 'fake.lua' or 'fake' depending on rockspec.
# Rockspec says bin = { "fake.lua" }. Moon usually preserves the filename.
moon exec -- fake.lua -e 'test' | grep "lua_args: -e test"

echo "━━━ ✓ LuaRocks bin rock admission passed ━━━"
