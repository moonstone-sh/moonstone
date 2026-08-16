#!/usr/bin/env bash
set -euo pipefail

# Contract: a builtin LuaRocks C module becomes an ABI-bound Moonstone native
# provision, loads through the projected runtime, and rematerializes from the
# lock after the committed artifact and project environment are removed.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8200 ))
MOCK_DIR="/tmp/moonstone-rockspec-builtin-cmodule-contract"
SOURCE_DIR="${MOCK_DIR}/builtin-cmodule-0.1.0"
TEST_APP="${SANDBOX_DIR}/rockspec-builtin-cmodule-contract-app"

rm -rf "${MOCK_DIR}" "${TEST_APP}"
mkdir -p "${SOURCE_DIR}" "${TEST_APP}"

cat > "${SOURCE_DIR}/test_c.c" <<'EOF'
#include <lua.h>
#include <lauxlib.h>

static int hello(lua_State *state) {
    lua_pushstring(state, "hello from builtin c module");
    return 1;
}

int luaopen_builtin_cmodule(lua_State *state) {
    lua_newtable(state);
    lua_pushcfunction(state, hello);
    lua_setfield(state, -2, "hello");
    return 1;
}
EOF
tar -czf "${MOCK_DIR}/builtin-cmodule-0.1.0.tar.gz" -C "${MOCK_DIR}" builtin-cmodule-0.1.0

cat > "${MOCK_DIR}/builtin-cmodule-0.1.0-1.rockspec" <<EOF
package = "builtin-cmodule"
version = "0.1.0-1"
source = { url = "http://localhost:${RANDOM_PORT}/builtin-cmodule-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = { type = "builtin", modules = { builtin_cmodule = "test_c.c" } }
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"builtin-cmodule":{"0.1.0-1":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >/tmp/moonstone-rockspec-builtin-cmodule-contract-server.log 2>&1 &
MOCK_PID=$!
trap 'kill "${MOCK_PID}" 2>/dev/null || true' EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"

echo "━━━ resolve and materialize builtin C module ━━━"
moon init . --name rockspec-builtin-cmodule-contract --no-git
moon interpreter set lua@5.4
moon add rocks:builtin-cmodule

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "builtin-cmodule"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: builtin-cmodule artifact manifest was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert normalized native artifact interface ━━━"
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -q '^target = "native"$' "${ARTIFACT_MANIFEST}"
grep -q '^lua_abi = "5.4"$' "${ARTIFACT_MANIFEST}"
grep -q '^source_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^recipe_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^artifact_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "builtin_cmodule", path = "lib/lua/5.4/builtin_cmodule.so" }]' "${ARTIFACT_MANIFEST}"

echo "━━━ assert projected runtime ABI behavior ━━━"
moon exec -- lua -e 'local module = require("builtin_cmodule"); print(module.hello())' | grep -q 'hello from builtin c module'

echo "━━━ purge and replay the locked native artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "builtin-cmodule"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the builtin-cmodule artifact"
    exit 1
fi
grep -q '^lua_abi = "5.4"$' "${RESTORED_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "builtin_cmodule", path = "lib/lua/5.4/builtin_cmodule.so" }]' "${RESTORED_MANIFEST}"
moon exec -- lua -e 'local module = require("builtin_cmodule"); print(module.hello())' | grep -q 'hello from builtin c module'

echo "━━━ ✓ LuaRocks builtin C-module artifact and replay contract passed ━━━"
