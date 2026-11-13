#!/usr/bin/env bash
set -euo pipefail

# Contract: on ELF hosts a native Lua module takes the Lua C API from the
# process that loads it (Moonstone's lua/luajit, Neovim, LÖVE...) instead of
# carrying a private copy of the runtime.
#
# The module below ships its own compat definition of luaL_testudata, as
# compat-5.3 based rocks (luasystem, a busted dependency) do. Linking the
# runtime archive into the module made such rocks fail with duplicate symbols,
# and every other native module embedded a whole VM.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

case "$(uname -s)" in
    Linux|FreeBSD) ;;
    *)
        echo "SKIP: ELF host-symbol contract is not applicable to $(uname -s)"
        exit 0
        ;;
esac
if ! command -v nm >/dev/null 2>&1; then
    echo "SKIP: nm is required to inspect module symbols"
    exit 0
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8200))
WORKDIR="$(mktemp -d /tmp/moonstone-cmodule-host-symbols.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/host-symbols-0.1.0"
TEST_APP="${SANDBOX_DIR}/cmodule-host-symbols-contract-app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

rm -rf "${TEST_APP}"
mkdir -p "${SOURCE_DIR}" "${TEST_APP}"

cat > "${SOURCE_DIR}/host_symbols.c" <<'EOF'
#include <lua.h>
#include <lauxlib.h>

/* Compat definition with the runtime's own name and signature. */
void *luaL_testudata(lua_State *L, int index, const char *name) {
    (void)L; (void)index; (void)name;
    return NULL;
}

static int answer(lua_State *L) {
    lua_pushinteger(L, (lua_Integer)luaL_checkinteger(L, 1) + 41);
    return 1;
}

int luaopen_host_symbols(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, answer);
    lua_setfield(L, -2, "answer");
    return 1;
}
EOF
tar -czf "${MOCK_DIR}/host-symbols-0.1.0.tar.gz" -C "${MOCK_DIR}" host-symbols-0.1.0

cat > "${MOCK_DIR}/host-symbols-0.1.0-1.rockspec" <<EOF
package = "host-symbols"
version = "0.1.0-1"
source = { url = "http://localhost:${RANDOM_PORT}/host-symbols-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = { type = "builtin", modules = { host_symbols = "host_symbols.c" } }
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"host-symbols":{"0.1.0-1":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >"${WORKDIR}/server.log" 2>&1 &
MOCK_PID=$!

export MOONSTONE_LUAROCKS_URL="http://localhost:${RANDOM_PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"

echo "━━━ build a C module that ships a compat Lua API definition ━━━"
moon init . --name cmodule-host-symbols-contract --no-git
moon set lua@5.4
moon add rocks:host-symbols

MODULE="$(find -L .moonstone/env/lib -name 'host_symbols.so' | head -1)"
if [[ -z "${MODULE}" ]]; then
    echo "ERROR: host_symbols.so was not projected"
    exit 1
fi

echo "━━━ assert the module carries no copy of the runtime ━━━"
for symbol in lua_newstate lua_pcall lua_pushinteger luaL_checkinteger luaL_newstate; do
    if nm -D --defined-only "${MODULE}" | grep -Eq " T ${symbol}\$"; then
        echo "ERROR: ${MODULE} defines ${symbol}: the runtime was linked into the module"
        exit 1
    fi
done
nm -D --undefined-only "${MODULE}" | grep -Eq ' U lua_pushinteger$'

echo "━━━ assert the host process provides the C API ━━━"
moon exec -- lua -e 'assert(require("host_symbols").answer(1) == 42); print("ok")' | grep -qx 'ok'

echo "━━━ ✓ ELF native modules take the Lua C API from the host ━━━"
