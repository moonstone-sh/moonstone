#!/usr/bin/env bash
set -euo pipefail

# Contract: ordinary LuaRocks build.patches unified diffs are applied before
# materialization, contribute to the declarative recipe identity, and replay
# from the lock after both the artifact and projected environment are removed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8500))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-patch-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/patch-contract-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}/src" "${TEST_APP}"

cat > "${SOURCE_DIR}/src/greeting.lua" <<'EOF'
return "before patch"
EOF
tar -czf "${MOCK_DIR}/patch-contract-0.1.0.tar.gz" -C "${MOCK_DIR}" patch-contract-0.1.0

cat > "${MOCK_DIR}/patch-contract-0.1.0-1.rockspec" <<EOF
package = "patch-contract"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/patch-contract-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { patch_contract = "src/greeting.lua" },
   patches = {
      ["greeting.patch"] = [[
--- a/src/greeting.lua
+++ b/src/greeting.lua
@@ -1 +1 @@
-return "before patch"
+return "after patch"
]],
   },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"patch-contract":{"0.1.0-1":[{"arch":"rockspec"}]}}}
EOF

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >"${WORKDIR}/server.log" 2>&1 &
MOCK_PID=$!

export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${MOCK_PID}" 2>/dev/null; then
        echo "ERROR: mock LuaRocks server stopped before becoming ready" >&2
        cat "${WORKDIR}/server.log" >&2
        exit 1
    fi
    sleep 0.5
done
if ! curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null; then
    echo "ERROR: mock LuaRocks server did not become ready" >&2
    cat "${WORKDIR}/server.log" >&2
    exit 1
fi

cd "${TEST_APP}"

echo "━━━ resolve and materialize patched rock ━━━"
moon init . --name patch-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:patch-contract

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "patch-contract"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: patched artifact manifest was not committed to the store" >&2
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert patched source and projected module behavior ━━━"
grep -q '^recipe_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -Fq 'return "after patch"' "${ARTIFACT_DIR}/files/share/lua/5.4/patch_contract.lua"
moon exec -- lua -e 'print(require("patch_contract"))' | grep -q 'after patch'

echo "━━━ purge and replay the locked patched artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "patch-contract"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the patched artifact" >&2
    exit 1
fi
RESTORED_DIR="$(dirname "${RESTORED_MANIFEST}")"
grep -Fq 'return "after patch"' "${RESTORED_DIR}/files/share/lua/5.4/patch_contract.lua"
moon exec -- lua -e 'print(require("patch_contract"))' | grep -q 'after patch'

echo "━━━ ✓ LuaRocks ordinary patch materialization and replay contract passed ━━━"
