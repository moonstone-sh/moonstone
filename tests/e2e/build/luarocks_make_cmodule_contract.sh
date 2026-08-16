#!/usr/bin/env bash
set -euo pipefail

# Contract: a LuaRocks make rock may declare the executable and native-library
# files it generates. Moonstone collects only those post-build declarations,
# alongside a conventional installed C module, then replays the full closure.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8200))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-make-cmodule-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/make-cmodule-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}" "${TEST_APP}"

case "$(uname -s)" in
    Darwin) SHARED_LIBRARY="libmakeprobe.dylib" ;;
    Linux|FreeBSD) SHARED_LIBRARY="libmakeprobe.so" ;;
    *)
        echo "SKIP: Make declared-output contract is not applicable to $(uname -s)"
        exit 0
        ;;
esac

cat > "${SOURCE_DIR}/make_cmodule.c" <<'EOF'
#include <lua.h>
#include <lauxlib.h>

static int greeting(lua_State *state) {
    lua_pushstring(state, "hello from make c module");
    return 1;
}

int luaopen_make_cmodule(lua_State *state) {
    lua_newtable(state);
    lua_pushcfunction(state, greeting);
    lua_setfield(state, -2, "greeting");
    return 1;
}
EOF

cat > "${SOURCE_DIR}/make_probe.c" <<'EOF'
int make_probe(void) {
    return 42;
}
EOF

cat > "${SOURCE_DIR}/Makefile" <<'EOF'
CC ?= cc
CFLAGS = -shared -fPIC -I$(LUA_INCDIR)

ifeq ($(shell uname),Darwin)
CFLAGS = -shared -fPIC -I$(LUA_INCDIR) -undefined dynamic_lookup
endif

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SHARED_LIBRARY = libmakeprobe.dylib
SHARED_FLAGS = -dynamiclib
else
SHARED_LIBRARY = libmakeprobe.so
SHARED_FLAGS = -shared -fPIC
endif

all: make_cmodule.so make-tool $(SHARED_LIBRARY) generated-assets/README.txt config/generated.conf

make_cmodule.so: make_cmodule.c
	$(CC) $(CFLAGS) -o $@ $<

make-tool:
	printf '#!/bin/sh\necho make declared binary\n' > $@
	chmod +x $@

$(SHARED_LIBRARY): make_probe.c
	$(CC) $(SHARED_FLAGS) -o $@ $<

generated-assets/README.txt:
	mkdir -p generated-assets
	printf 'generated asset closure\n' > $@

config/generated.conf:
	mkdir -p config
	printf 'generated_config = true\n' > $@

install: all
	mkdir -p "$(PREFIX)/lib/lua/$(LUA_ABI)"
	cp make_cmodule.so "$(PREFIX)/lib/lua/$(LUA_ABI)/make_cmodule.so"
EOF

tar -czf "${MOCK_DIR}/make-cmodule-0.1.0.tar.gz" -C "${MOCK_DIR}" make-cmodule-0.1.0

cat > "${MOCK_DIR}/make-cmodule-0.1.0-1.rockspec" <<EOF
package = "make-cmodule"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/make-cmodule-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "make",
   copy_directories = { "generated-assets" },
   install = {
      bin = { ["make-tool"] = "make-tool" },
      lib = { ["native.makeprobe"] = "${SHARED_LIBRARY}" },
      conf = { ["runtime/generated.conf"] = "config/generated.conf" },
   },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"make-cmodule":{"0.1.0-1":[{"arch":"rockspec"}]}}}
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

echo "━━━ resolve and materialize Make C module ━━━"
moon init . --name make-cmodule-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:make-cmodule

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "make-cmodule"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: make-cmodule artifact manifest was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert normalized Make artifact interface ━━━"
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -Eq '^target = "[^"]+"$' "${ARTIFACT_MANIFEST}"
grep -q '^lua_abi = "5.4"$' "${ARTIFACT_MANIFEST}"
grep -q '^source_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^recipe_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -q '^artifact_hash = "b3:' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "make_cmodule", path = "lib/lua/5.4/make_cmodule.so" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'bin = [{ name = "make-tool", path = "bin/make-tool" }]' "${ARTIFACT_MANIFEST}"
grep -Fq "native_lib = [{ name = \"native.makeprobe\", path = \"lib/native/native/makeprobe/${SHARED_LIBRARY}\", linkage = \"shared\" }]" "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/generated-assets/README.txt"' "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/conf/runtime/generated.conf"' "${ARTIFACT_MANIFEST}"
grep -Fq 'generated asset closure' "${ARTIFACT_DIR}/files/assets/generated-assets/README.txt"
grep -Fq 'generated_config = true' "${ARTIFACT_DIR}/files/assets/conf/runtime/generated.conf"

echo "━━━ assert projected runtime ABI behavior ━━━"
moon exec -- lua -e 'local module = require("make_cmodule"); print(module.greeting())' | grep -q 'hello from make c module'
moon exec -- make-tool | grep -q 'make declared binary'
[[ -L ".moonstone/env/lib/native/${SHARED_LIBRARY}" ]]

echo "━━━ purge and replay the locked Make artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "make-cmodule"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the make-cmodule artifact"
    exit 1
fi
grep -Fq 'lua_cmodule = [{ name = "make_cmodule", path = "lib/lua/5.4/make_cmodule.so" }]' "${RESTORED_MANIFEST}"
grep -Fq 'bin = [{ name = "make-tool", path = "bin/make-tool" }]' "${RESTORED_MANIFEST}"
grep -Fq "native_lib = [{ name = \"native.makeprobe\", path = \"lib/native/native/makeprobe/${SHARED_LIBRARY}\", linkage = \"shared\" }]" "${RESTORED_MANIFEST}"
grep -Fq 'path = "assets/generated-assets/README.txt"' "${RESTORED_MANIFEST}"
grep -Fq 'path = "assets/conf/runtime/generated.conf"' "${RESTORED_MANIFEST}"
grep -Fq 'generated asset closure' "$(dirname "${RESTORED_MANIFEST}")/files/assets/generated-assets/README.txt"
grep -Fq 'generated_config = true' "$(dirname "${RESTORED_MANIFEST}")/files/assets/conf/runtime/generated.conf"
moon exec -- lua -e 'local module = require("make_cmodule"); print(module.greeting())' | grep -q 'hello from make c module'
moon exec -- make-tool | grep -q 'make declared binary'
[[ -L ".moonstone/env/lib/native/${SHARED_LIBRARY}" ]]

echo "━━━ ✓ LuaRocks Make C-module artifact and replay contract passed ━━━"
