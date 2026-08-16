#!/usr/bin/env bash
set -euo pipefail

# Contract: LuaRocks build.install.lua maps preserve LuaRocks module-path
# semantics, materialize as Moonstone lua_module provisions, and replay from
# the lock after the artifact and project environment are removed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8200))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-install-lua-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/install-lua-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}/src" "${TEST_APP}"

cat > "${SOURCE_DIR}/src/greeting.lua" <<'EOF'
return {
    message = "hello from mapped install.lua",
}
EOF
tar -czf "${MOCK_DIR}/install-lua-0.1.0.tar.gz" -C "${MOCK_DIR}" install-lua-0.1.0

cat > "${MOCK_DIR}/install-lua-0.1.0-1.rockspec" <<EOF
package = "install-lua"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/install-lua-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = {},
   install = {
      lua = {
         ["nested.greeting"] = "src/greeting.lua",
      },
   },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"install-lua":{"0.1.0-1":[{"arch":"rockspec"}]}}}
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

echo "━━━ resolve and materialize mapped install.lua rock ━━━"
moon init . --name install-lua-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:install-lua

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-lua"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: install-lua artifact manifest was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert normalized mapped Lua module provision ━━━"
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -q '^source_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^recipe_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^artifact_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_module = [{ name = "nested.greeting", path = "share/lua/5.4/nested/greeting.lua" }]' "${ARTIFACT_MANIFEST}"

echo "━━━ assert projected mapped module behavior ━━━"
moon exec -- lua -e 'local module = require("nested.greeting"); print(module.message)' | grep -q 'hello from mapped install.lua'

echo "━━━ purge and replay the locked mapped module artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "install-lua"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the install-lua artifact"
    exit 1
fi
grep -Fq 'lua_module = [{ name = "nested.greeting", path = "share/lua/5.4/nested/greeting.lua" }]' "${RESTORED_MANIFEST}"
moon exec -- lua -e 'local module = require("nested.greeting"); print(module.message)' | grep -q 'hello from mapped install.lua'

echo "━━━ ✓ LuaRocks mapped install.lua artifact and replay contract passed ━━━"
