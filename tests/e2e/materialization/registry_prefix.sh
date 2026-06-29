#!/usr/bin/env bash
set -euo pipefail

# Test: Registry prefixing
# - Inits a project
# - Adds a package using explicit rocks: prefix
# - Verifies it's saved correctly in moonstone.toml
# - Adds a package using explicit synthetic registry prefix
# - Verifies it's saved correctly

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

# Determine project root relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

WORKDIR="/tmp/moonstone-test-prefix"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "━━━ moon init ━━━"
moon init --name prefix-test --lib --runtime lua@5.4.7

echo "━━━ add rocks:fakebin ━━━"
# We need to serve mock rocks first
MOCK_ROCKS_PORT=$(( ( RANDOM % 1000 ) + 8900 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-prefix"
rm -rf "${MOCK_DIR}"
mkdir -p "${MOCK_DIR}"
# Pre-install the Moonstone-managed Lua tools before launching the long-running mock server.
"${PROJECT_ROOT}/tests/run_lua_tool.sh" help >/dev/null
"${PROJECT_ROOT}/tests/run_lua_tool.sh" generate-mock-rocks "${MOCK_DIR}" "${MOCK_ROCKS_PORT}" &
ROCKS_PID=$!
trap "kill $ROCKS_PID 2>/dev/null || true" EXIT

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${MOCK_ROCKS_PORT}"

# Wait for server
sleep 1

moon add "rocks:fakebin"

echo "━━━ verify moonstone.toml ━━━"
cat moonstone.toml
grep '"fakebin" = "rocks:fakebin@^1.0-1"' moonstone.toml

echo "━━━ add synthetic:luassert ━━━"
moon add "synthetic:luassert@1.9.0"

echo "━━━ verify moonstone.toml ━━━"
cat moonstone.toml
grep '"luassert" = "synthetic:luassert@^1.9.0"' moonstone.toml

echo "━━━ moon remove rocks:fakebin ━━━"
moon remove "rocks:fakebin"
grep -v "fakebin" moonstone.toml

echo "━━━ ✓ Registry prefixing passed ━━━"
