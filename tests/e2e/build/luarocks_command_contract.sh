#!/usr/bin/env bash
set -euo pipefail

# Contract: LuaRocks command rocks run their declared shell command bodies in
# Moonstone's projected build environment. Generated files enter the closure
# only through explicit install/copy declarations and survive locked replay.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

case "$(uname -s)" in
    Darwin|Linux|FreeBSD) ;;
    *)
        echo "SKIP: LuaRocks command backend fixture requires a POSIX sh host"
        exit 0
        ;;
esac

RANDOM_PORT=$(((RANDOM % 1000) + 8400))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-command-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/command-rock-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}" "${TEST_APP}"

tar -czf "${MOCK_DIR}/command-rock-0.1.0.tar.gz" -C "${MOCK_DIR}" command-rock-0.1.0

cat > "${MOCK_DIR}/command-rock-0.1.0-1.rockspec" <<'EOF'
package = "command-rock"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:__PORT__/command-rock-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "command",
   build_command = [[
mkdir -p generated-assets config &&
test -n "$PREFIX" &&
test -n "$LUA_INCDIR" &&
test -n "$LUA_LIBDIR" &&
test -x "$LUA_BINDIR/lua" &&
"$LUA_BINDIR/lua" -e 'assert(_VERSION == "Lua 5.4")' &&
printf 'command asset closure\n' > generated-assets/README.txt &&
printf 'generated_config = command\n' > config/generated.conf &&
printf 'build_lua_abi=%s\nbuild_runtime_lua=ok\nbuild_prefix=present\n' "$LUA_ABI" > build-environment.txt
]],
   install_command = [[
mkdir -p "$PREFIX/share/lua/$LUA_ABI" &&
printf 'return "hello from command rock"\n' > "$PREFIX/share/lua/$LUA_ABI/command_rock.lua" &&
printf '#!/bin/sh\necho command declared binary\n' > command-tool &&
chmod +x command-tool
]],
   copy_directories = { "generated-assets" },
   install = {
      bin = { ["command-tool"] = "command-tool" },
      conf = {
         ["runtime/generated.conf"] = "config/generated.conf",
         ["build/environment.txt"] = "build-environment.txt",
      },
   },
}
EOF
perl -pi -e "s/__PORT__/${RANDOM_PORT}/g" "${MOCK_DIR}/command-rock-0.1.0-1.rockspec"

cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"command-rock":{"0.1.0-1":[{"arch":"rockspec"}]}}}
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

echo "━━━ resolve and materialize command rock ━━━"
moon init . --name command-rock-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:command-rock

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "command-rock"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: command-rock artifact manifest was not committed to the store" >&2
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert command shell closure ━━━"
grep -Fq 'lua_module = [{ name = "command_rock", path = "share/lua/5.4/command_rock.lua" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'bin = [{ name = "command-tool", path = "bin/command-tool" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/generated-assets/README.txt"' "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/conf/runtime/generated.conf"' "${ARTIFACT_MANIFEST}"
grep -Fq 'path = "assets/conf/build/environment.txt"' "${ARTIFACT_MANIFEST}"
grep -Fq 'command asset closure' "${ARTIFACT_DIR}/files/assets/generated-assets/README.txt"
grep -Fq 'generated_config = command' "${ARTIFACT_DIR}/files/assets/conf/runtime/generated.conf"
grep -Fq 'build_lua_abi=5.4' "${ARTIFACT_DIR}/files/assets/conf/build/environment.txt"
grep -Fq 'build_runtime_lua=ok' "${ARTIFACT_DIR}/files/assets/conf/build/environment.txt"
grep -Fq 'build_prefix=present' "${ARTIFACT_DIR}/files/assets/conf/build/environment.txt"

echo "━━━ assert projected runtime behavior ━━━"
moon exec -- lua -e 'print(require("command_rock"))' | grep -q 'hello from command rock'
moon exec -- command-tool | grep -q 'command declared binary'

echo "━━━ purge and replay locked command rock ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "command-rock"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the command-rock artifact" >&2
    exit 1
fi
grep -Fq 'lua_module = [{ name = "command_rock", path = "share/lua/5.4/command_rock.lua" }]' "${RESTORED_MANIFEST}"
grep -Fq 'bin = [{ name = "command-tool", path = "bin/command-tool" }]' "${RESTORED_MANIFEST}"
grep -Fq 'command asset closure' "$(dirname "${RESTORED_MANIFEST}")/files/assets/generated-assets/README.txt"
grep -Fq 'generated_config = command' "$(dirname "${RESTORED_MANIFEST}")/files/assets/conf/runtime/generated.conf"
grep -Fq 'build_lua_abi=5.4' "$(dirname "${RESTORED_MANIFEST}")/files/assets/conf/build/environment.txt"
grep -Fq 'build_runtime_lua=ok' "$(dirname "${RESTORED_MANIFEST}")/files/assets/conf/build/environment.txt"
grep -Fq 'build_prefix=present' "$(dirname "${RESTORED_MANIFEST}")/files/assets/conf/build/environment.txt"
moon exec -- lua -e 'print(require("command_rock"))' | grep -q 'hello from command rock'
moon exec -- command-tool | grep -q 'command declared binary'

echo "━━━ ✓ LuaRocks command artifact and replay contract passed ━━━"
