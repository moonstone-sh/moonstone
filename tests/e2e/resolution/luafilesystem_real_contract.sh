#!/usr/bin/env bash
set -euo pipefail

# Contract: the pinned LuaFileSystem 1.9.0-1 source rock materializes through
# Moonstone's normal LuaRocks path, exposes its native module in the projected
# Lua environment, and replays from moonstone.lock. The upstream download is
# verified before Moonstone sees a local mirror, so the test cannot silently
# certify replacement bytes for the same published version.

if [[ "${MOONSTONE_REAL_LUAROCKS:-0}" != "1" ]]; then
    echo "SKIP: set MOONSTONE_REAL_LUAROCKS=1 to run the pinned LuaFileSystem upstream contract"
    exit 0
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "SKIP: required command not found: $1"
        exit 0
    fi
}

for command in curl python3; do
    require_cmd "${command}"
done

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        require_cmd shasum
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

readonly PACKAGE="luafilesystem"
readonly VERSION="1.9.0-1"
readonly SOURCE_ROCK_SHA256="3de68d619f6ad95a27f4728814375447d921305194b7050dee6199057c31282f"
readonly ROCKSPEC_SHA256="32bbfb40a23a10063a8f332b874556019232e4a01e9bcd9c0cfb422118e2e1c9"
readonly SOURCE_ROCK_B3="b3:eb045fcb85b41313935a69e25e12a1a473dbc7c216debdb86ce57845d23b12c0"

WORKDIR="/tmp/moonstone-real-luafilesystem-contract"
MIRROR_DIR="${WORKDIR}/mirror"
TEST_APP="${WORKDIR}/app"
PORT=$(( ( RANDOM % 1000 ) + 9200 ))

rm -rf "${WORKDIR}"
mkdir -p "${MIRROR_DIR}" "${TEST_APP}"

echo "━━━ fetch and verify pinned LuaFileSystem upstream release ━━━"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-${VERSION}.src.rock" \
    "https://luarocks.org/${PACKAGE}-${VERSION}.src.rock"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-${VERSION}.rockspec" \
    "https://luarocks.org/${PACKAGE}-${VERSION}.rockspec"

test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-${VERSION}.src.rock")" = "${SOURCE_ROCK_SHA256}"
test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-${VERSION}.rockspec")" = "${ROCKSPEC_SHA256}"

cat > "${MIRROR_DIR}/manifest-5.4.json" <<EOF
{"repository":{"${PACKAGE}":{"${VERSION}":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${PORT}" --directory "${MIRROR_DIR}" >/tmp/moonstone-real-luafilesystem-contract-server.log 2>&1 &
MIRROR_PID=$!
trap 'kill "${MIRROR_PID}" 2>/dev/null || true' EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${PORT}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"

echo "━━━ materialize pinned LuaFileSystem native module ━━━"
moon init . --name real-luafilesystem-contract --no-git
moon interpreter set lua@5.4
moon add "rocks:${PACKAGE}@${VERSION}"

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "luafilesystem"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: LuaFileSystem artifact was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert the native artifact closure and projected behavior ━━━"
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -Fq "source_hash = \"${SOURCE_ROCK_B3}\"" "${ARTIFACT_MANIFEST}"
grep -Fq "source = \"http://localhost:${PORT}/${PACKAGE}-${VERSION}.src.rock\"" "${ARTIFACT_MANIFEST}"
grep -q '^source_kind = "luarocks_src_rock"$' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "lfs", path = "lib/lua/5.4/lfs.so" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'asset = [{ name = "docs/' "${ARTIFACT_MANIFEST}"

moon exec -- lua -e '
  local lfs = assert(require("lfs"))
  assert(lfs.mkdir("lfs-contract-dir"))
  assert(lfs.attributes("lfs-contract-dir", "mode") == "directory")
  assert(lfs.rmdir("lfs-contract-dir"))
  print("luafilesystem-native-ok")
' | grep -q 'luafilesystem-native-ok'

echo "━━━ purge and replay the locked LuaFileSystem artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "luafilesystem"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the LuaFileSystem artifact"
    exit 1
fi
grep -Fq "source_hash = \"${SOURCE_ROCK_B3}\"" "${RESTORED_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "lfs", path = "lib/lua/5.4/lfs.so" }]' "${RESTORED_MANIFEST}"
moon exec -- lua -e '
  local lfs = assert(require("lfs"))
  assert(lfs.mkdir("lfs-contract-dir-replay"))
  assert(lfs.attributes("lfs-contract-dir-replay", "mode") == "directory")
  assert(lfs.rmdir("lfs-contract-dir-replay"))
  print("luafilesystem-replay-ok")
' | grep -q 'luafilesystem-replay-ok'

echo "━━━ ✓ Pinned LuaFileSystem materialization, execution, and replay passed ━━━"
