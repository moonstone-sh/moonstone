#!/usr/bin/env bash
set -euo pipefail

# Contract: a LuaRocks CMake rock installs its module and declared non-module
# outputs through standard CMake install rules. Moonstone promotes only those
# typed paths from CMake's isolated install staging root, then replays them
# from lock without committing CMake's generated build or install trees.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

if ! command -v cmake >/dev/null 2>&1; then
    echo "SKIP: LuaRocks CMake contract requires cmake"
    exit 0
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8500))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-cmake-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/cmake-rock-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}" "${TEST_APP}"

case "$(uname -s)" in
    Darwin) SHARED_LIBRARY="libcmake_probe.dylib" ;;
    Linux|FreeBSD) SHARED_LIBRARY="libcmake_probe.so" ;;
    *)
        echo "SKIP: CMake shared-library contract is not applicable to $(uname -s)"
        exit 0
        ;;
esac

cat > "${SOURCE_DIR}/cmake_rock.c" <<'EOF'
#include <lua.h>
#include <lauxlib.h>

static int greeting(lua_State *state) {
    lua_pushstring(state, "hello from cmake rock");
    return 1;
}

int luaopen_cmake_rock(lua_State *state) {
    lua_newtable(state);
    lua_pushcfunction(state, greeting);
    lua_setfield(state, -2, "greeting");
    return 1;
}
EOF

cat > "${SOURCE_DIR}/cmake_probe.c" <<'EOF'
int cmake_probe(void) {
    return 42;
}
EOF

cat > "${SOURCE_DIR}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(cmake_rock C)

add_library(cmake_rock MODULE cmake_rock.c)
target_include_directories(cmake_rock PRIVATE "${LUA_INCLUDE_DIR}")
set_target_properties(cmake_rock PROPERTIES PREFIX "" SUFFIX ".so")

add_library(cmake_probe SHARED cmake_probe.c)

if(APPLE)
    target_link_options(cmake_rock PRIVATE "-undefined" "dynamic_lookup")
endif()

install(TARGETS cmake_rock LIBRARY DESTINATION "lib/lua/${LUA_ABI}")
install(TARGETS cmake_probe
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin)

# These are generated at CMake configure time, installed into the isolated
# staging prefix, then promoted only because the rockspec declares their paths.
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/cmake-tool" "#!/bin/sh\necho cmake declared binary\n")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/README.txt" "generated CMake asset closure\n")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/generated.conf" "generated_config = cmake\n")
install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/cmake-tool" DESTINATION bin)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/README.txt" DESTINATION "share/cmake-rock/generated-assets")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/generated.conf" DESTINATION "etc/cmake-rock")
EOF

tar -czf "${MOCK_DIR}/cmake-rock-0.1.0.tar.gz" -C "${MOCK_DIR}" cmake-rock-0.1.0

cat > "${MOCK_DIR}/cmake-rock-0.1.0-1.rockspec" <<EOF
package = "cmake-rock"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/cmake-rock-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "cmake",
   copy_directories = { "share/cmake-rock/generated-assets" },
   install = {
      bin = { ["cmake-tool"] = "bin/cmake-tool" },
      lib = { ["native.cmakeprobe"] = "lib/${SHARED_LIBRARY}" },
      conf = { ["runtime/generated.conf"] = "etc/cmake-rock/generated.conf" },
   },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"cmake-rock":{"0.1.0-1":[{"arch":"rockspec"}]}}}
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
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"

echo "━━━ resolve and materialize CMake rock ━━━"
moon init . --name cmake-rock-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:cmake-rock

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "cmake-rock"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: cmake-rock artifact manifest was not committed to the store" >&2
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert normalized CMake artifact interface ━━━"
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -Eq '^target = "[^"]+"$' "${ARTIFACT_MANIFEST}"
grep -q '^lua_abi = "5.4"$' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "cmake_rock", path = "lib/lua/5.4/cmake_rock.so" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'bin = [{ name = "cmake-tool", path = "bin/cmake-tool" }]' "${ARTIFACT_MANIFEST}"
grep -Fq "native_lib = [{ name = \"native.cmakeprobe\", path = \"lib/native/native/cmakeprobe/${SHARED_LIBRARY}\", linkage = \"shared\" }]" "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/share/cmake-rock/generated-assets/README.txt"' "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/conf/runtime/generated.conf"' "${ARTIFACT_MANIFEST}"
[[ -f "${ARTIFACT_DIR}/files/lib/lua/5.4/cmake_rock.so" ]]
[[ -f "${ARTIFACT_DIR}/files/lib/native/native/cmakeprobe/${SHARED_LIBRARY}" ]]
[[ ! -e "${ARTIFACT_DIR}/files/.moonstone-cmake-install" ]]
grep -Fq 'generated CMake asset closure' "${ARTIFACT_DIR}/files/assets/share/cmake-rock/generated-assets/README.txt"
grep -Fq 'generated_config = cmake' "${ARTIFACT_DIR}/files/assets/conf/runtime/generated.conf"

echo "━━━ assert projected runtime ABI behavior ━━━"
moon exec -- lua -e 'local module = require("cmake_rock"); print(module.greeting())' | grep -q 'hello from cmake rock'
moon exec -- cmake-tool | grep -q 'cmake declared binary'
[[ -L ".moonstone/env/lib/native/${SHARED_LIBRARY}" ]]

echo "━━━ purge and replay locked CMake artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "cmake-rock"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the cmake-rock artifact" >&2
    exit 1
fi
grep -Fq 'lua_cmodule = [{ name = "cmake_rock", path = "lib/lua/5.4/cmake_rock.so" }]' "${RESTORED_MANIFEST}"
grep -Fq 'bin = [{ name = "cmake-tool", path = "bin/cmake-tool" }]' "${RESTORED_MANIFEST}"
grep -Fq "native_lib = [{ name = \"native.cmakeprobe\", path = \"lib/native/native/cmakeprobe/${SHARED_LIBRARY}\", linkage = \"shared\" }]" "${RESTORED_MANIFEST}"
grep -Fq 'path = "assets/share/cmake-rock/generated-assets/README.txt"' "${RESTORED_MANIFEST}"
grep -Fq 'path = "assets/conf/runtime/generated.conf"' "${RESTORED_MANIFEST}"
[[ -f "$(dirname "${RESTORED_MANIFEST}")/files/lib/lua/5.4/cmake_rock.so" ]]
[[ -f "$(dirname "${RESTORED_MANIFEST}")/files/lib/native/native/cmakeprobe/${SHARED_LIBRARY}" ]]
[[ ! -e "$(dirname "${RESTORED_MANIFEST}")/files/.moonstone-cmake-install" ]]
grep -Fq 'generated CMake asset closure' "$(dirname "${RESTORED_MANIFEST}")/files/assets/share/cmake-rock/generated-assets/README.txt"
grep -Fq 'generated_config = cmake' "$(dirname "${RESTORED_MANIFEST}")/files/assets/conf/runtime/generated.conf"
moon exec -- lua -e 'local module = require("cmake_rock"); print(module.greeting())' | grep -q 'hello from cmake rock'
moon exec -- cmake-tool | grep -q 'cmake declared binary'
[[ -L ".moonstone/env/lib/native/${SHARED_LIBRARY}" ]]

echo "━━━ ✓ LuaRocks CMake artifact and replay contract passed ━━━"
