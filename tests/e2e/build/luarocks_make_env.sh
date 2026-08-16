#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks make env propagation
# - Mocks a LuaRocks server with a make package
# - Defines [build.env] in moonstone.toml
# - Verifies that the child process (make) sees the environment variables exactly as defined

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

# 1. Start mock server in background
RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-make"
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
WORKDIR="/tmp/moonstone-test-rocks-make"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init . --name "rocks-make-test"
moon interpreter set lua@5.4

# Append build.env block BEFORE adding the rock
cat <<EOF >> moonstone.toml

[build.env]
OPENSSL_DIR = "/tmp/moonstone-test-openssl"
CFLAGS = "-I/tmp/moonstone-test-openssl/include"
CPPFLAGS = "-I/tmp/moonstone-test-openssl/include"
LDFLAGS = "-L/tmp/moonstone-test-openssl/lib"
EOF

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
moon add "rocks:make-env-test"

# 3. Resolve and sync
moon sync

# 4. Verify env_test.lua
ENV_OUT=".moonstone/env/share/lua/5.4/env_test.lua"
if [[ ! -f "$ENV_OUT" ]]; then
    ENV_OUT=".moonstone/env/lib/lua/5.4/env_test.lua"
    if [[ ! -f "$ENV_OUT" ]]; then
        echo "ERROR: env_test.lua not found"
        exit 1
    fi
fi

cat "$ENV_OUT"

grep -q "OPENSSL_DIR = \"/tmp/moonstone-test-openssl\"" "$ENV_OUT" || { echo "OPENSSL_DIR mismatch"; exit 1; }
grep -q "CFLAGS = \"-I/tmp/moonstone-test-openssl/include\"" "$ENV_OUT" || { echo "CFLAGS mismatch"; exit 1; }
grep -q "CPPFLAGS = \"-I/tmp/moonstone-test-openssl/include\"" "$ENV_OUT" || { echo "CPPFLAGS mismatch"; exit 1; }
grep -q "LDFLAGS = \"-L/tmp/moonstone-test-openssl/lib\"" "$ENV_OUT" || { echo "LDFLAGS mismatch"; exit 1; }

echo "✅ build.env successfully propagated to LuaRocks make materializer!"
