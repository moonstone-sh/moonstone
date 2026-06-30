#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks transitive dependency offline resolution
# - Mocks a LuaRocks server with parent -> child dependency
# - moon add rocks:parent once (online)
# - Verify both parent and child are committed to store
# - Disable network, run moon sync --offline
# - Assert solver resolves both parent and child from store

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8300 ))
MOCK_DIR="/tmp/moonstone-mock-rocks-transitive"
rm -rf "${MOCK_DIR}"
mkdir -p "${MOCK_DIR}"

"${PROJECT_ROOT}/tests/run_lua_tool.sh" generate-mock-rocks "${MOCK_DIR}" "${RANDOM_PORT}" &
MOCK_PID=$!
trap "kill $MOCK_PID 2>/dev/null || true" EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${SANDBOX_DIR}/my-app"
rm -rf .moonstone
rm -f moonstone.lock moonstone.toml

echo "━━━ moon init ━━━"
moon init . --name my-app --no-git

echo "━━━ moon interpreter set lua@5.4 ━━━"
moon interpreter set lua@5.4

echo "━━━ moon add rocks:parent (online) ━━━"
moon add rocks:parent

echo "━━━ verify parent in lock ━━━"
grep "parent" moonstone.lock

echo "━━━ verify child in lock ━━━"
grep "child" moonstone.lock

echo "━━━ verify store has parent and child artifacts ━━━"
STORE_DIR="${MOONSTONE_DATA}/store/v0"
find "${STORE_DIR}" -name "manifest.toml" | xargs grep -l '"parent"' | grep -q .
find "${STORE_DIR}" -name "manifest.toml" | xargs grep -l '"child"' | grep -q .

echo "━━━ moon sync --offline (should resolve from store) ━━━"
# Break network by unsetting the URL
unset MOONSTONE_LUAROCKS_URL
export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:1"
moon sync --offline

echo "━━━ verify parent module loads ━━━"
moon exec -- lua -e 'print(require("parent").greet())' | grep "from child"

echo "━━━ ✓ LuaRocks transitive offline resolution passed ━━━"
