#!/usr/bin/env bash
set -euo pipefail

# Test: LuaRocks transitive dependency offline resolution — missing child
# - Mocks a LuaRocks server with parent -> child dependency
# - moon add rocks:parent once (online)
# - Verify both parent and child are committed to store
# - Delete only the child artifact from the store
# - Disable network, run moon sync --offline
# - Assert failure: child dependency exists in cached parent manifest, but child artifact is missing

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

echo "━━━ moon use lua@5.4 ━━━"
moon use lua@5.4

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

echo "━━━ delete child artifact from store ━━━"
CHILD_ART_DIR=$(find "${STORE_DIR}" -name "manifest.toml" -exec grep -l '^name = "child"$' {} \; | head -1 | xargs dirname)
rm -rf "${CHILD_ART_DIR}"

echo "━━━ moon sync --offline (should fail because child artifact is missing) ━━━"
# Break network by unsetting the URL
unset MOONSTONE_LUAROCKS_URL
export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:1"
INSTALL_OUTPUT="/tmp/moon-install-offline-missing-child.log"
if moon sync --offline >"${INSTALL_OUTPUT}" 2>&1; then
    echo "ERROR: moon sync --offline succeeded but should have failed"
    exit 1
fi

echo "━━━ Asserting diagnostic substrings in plain-text output ━━━"
grep -q "Cannot resolve rocks:child while offline" "${INSTALL_OUTPUT}"
grep -q "required by rocks:parent" "${INSTALL_OUTPUT}"
grep -q "local store manifest" "${INSTALL_OUTPUT}"
grep -q "No compatible artifact" "${INSTALL_OUTPUT}"

echo "━━━ Install output tail ━━━"
tail -n 8 "${INSTALL_OUTPUT}"

echo "━━━ moon sync --offline --json (should also fail with structured diagnostic) ━━━"
JSON_OUTPUT="/tmp/moon-install-offline-missing-child.json"
if moon sync --offline --json >"${JSON_OUTPUT}" 2>&1; then
    echo "ERROR: moon sync --offline --json succeeded but should have failed"
    exit 1
fi

echo "━━━ Asserting JSON diagnostic fields ━━━"
grep -q '"kind":"offline_transitive_missing"' "${JSON_OUTPUT}"
grep -q '"child_name":"child"' "${JSON_OUTPUT}"
grep -q '"child_constraint"' "${JSON_OUTPUT}"

echo "━━━ ✓ Negative test passed: offline install correctly fails with specific diagnostic when transitive child artifact is missing ━━━"
