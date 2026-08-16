#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks builtin C module compilation
# - Mocks a LuaRocks server
# - Adds a rock that uses build.type = "builtin"
# - Verifies it compiles and is executable via moon exec

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

# 1. Start mock server in background
RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8200 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-builtin"
rm -rf "${MOCK_DIR}"
mkdir -p "${MOCK_DIR}"

# Pre-install the Moonstone-managed Lua tools before launching the long-running mock server.
"${PROJECT_ROOT}/tests/run_lua_tool.sh" help >/dev/null

"${PROJECT_ROOT}/tests/run_lua_tool.sh" generate-mock-rocks "${MOCK_DIR}" "${RANDOM_PORT}" &
MOCK_PID=$!

# Ensure mock server is cleaned up
trap "kill $MOCK_PID 2>/dev/null || true" EXIT

# Wait for server to start
sleep 2

# 2. Setup project
WORKDIR="/tmp/moonstone-test-rocks-builtin"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init . --name "rocks-builtin-test"
moon interpreter set lua@5.4

# 3. Add and install rock using the mock server
export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"

echo "━━━ install builtin-cmodule ━━━"
moon add "rocks:builtin-cmodule"
moon sync

echo "━━━ verify cmodule exists ━━━"
test -f .moonstone/env/lib/lua/5.4/builtin_cmodule.so

echo "━━━ run cmodule test ━━━"
moon exec -- lua -e 'local m = require("builtin_cmodule"); print(m.hello())' | grep "hello from builtin c module"

echo "━━━ ✓ LuaRocks builtin C module test passed ━━━"
