#!/usr/bin/env bash
set -euo pipefail

# Contract: the pinned LuaSQL SQLite3 source rock is materialized using the
# host's explicitly declared SQLite development surface. The fixture verifies
# official release bytes before serving them locally, exercises the native Lua
# module, then proves the same artifact replays from moonstone.lock.

if [[ "${MOONSTONE_REAL_LUAROCKS:-0}" != "1" ]]; then
    echo "SKIP: set MOONSTONE_REAL_LUAROCKS=1 to run the pinned LuaSQL SQLite3 upstream contract"
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

for command in curl python3 zig; do
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

readonly PACKAGE="luasql-sqlite3"
readonly VERSION="2.8.0-1"
readonly SOURCE_ROCK_SHA256="803da6e49ee6e7bc3e6701d8b7453c3eb6b0b4d842ca61414c2da742cba47691"
readonly ROCKSPEC_SHA256="d4e29c78897bc5551f4111740792f9232846ac37af40ff1d89d2b61882d00cff"
readonly SOURCE_ROCK_B3="b3:e9b180f15e2b5738df47a32ad78ef905333e1114a17c726a0d3078cddf8bc342"

WORKDIR="/tmp/moonstone-real-luasql-sqlite3-contract"
MIRROR_DIR="${WORKDIR}/mirror"
TEST_APP="${WORKDIR}/app"
PORT=$(( ( RANDOM % 1000 ) + 9300 ))

rm -rf "${WORKDIR}"
mkdir -p "${MIRROR_DIR}" "${TEST_APP}"

cat > "${WORKDIR}/sqlite-probe.c" <<'C'
#include <sqlite3.h>
int main(void) { return sqlite3_libversion_number() == 0; }
C
case "$(uname -s)" in
    Darwin)
        require_cmd xcrun
        SQLITE_SDKROOT="$(xcrun --show-sdk-path)"
        SQLITE_INCDIR="${SQLITE_SDKROOT}/usr/include"
        SQLITE_LIBDIR="${SQLITE_SDKROOT}/usr/lib"
        SQLITE_PROBE_ARGS=(-isysroot "${SQLITE_SDKROOT}")
        ;;
    Linux|FreeBSD)
        require_cmd pkg-config
        SQLITE_INCDIR="$(pkg-config --variable=includedir sqlite3)"
        SQLITE_LIBDIR="$(pkg-config --variable=libdir sqlite3)"
        SQLITE_PROBE_ARGS=()
        ;;
    *)
        echo "SKIP: unsupported host for the LuaSQL SQLite3 SDK contract: $(uname -s)"
        exit 0
        ;;
esac

if [[ -z "${SQLITE_INCDIR}" || -z "${SQLITE_LIBDIR}" ]] ||
   [[ ! -f "${SQLITE_INCDIR}/sqlite3.h" ]] ||
   ! zig cc "${WORKDIR}/sqlite-probe.c" "${SQLITE_PROBE_ARGS[@]}" -I "${SQLITE_INCDIR}" -L "${SQLITE_LIBDIR}" -lsqlite3 -o "${WORKDIR}/sqlite-probe" >/dev/null 2>&1; then
    echo "SKIP: host toolchain does not provide the SQLite header and library declared by LuaSQL"
    exit 0
fi
export SQLITE_INCDIR SQLITE_LIBDIR

printf '━━━ fetch and verify pinned LuaSQL SQLite3 upstream release ━━━\n'
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-${VERSION}.src.rock" \
    "https://luarocks.org/${PACKAGE}-${VERSION}.src.rock"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-${VERSION}.rockspec" \
    "https://luarocks.org/${PACKAGE}-${VERSION}.rockspec"

test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-${VERSION}.src.rock")" = "${SOURCE_ROCK_SHA256}"
test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-${VERSION}.rockspec")" = "${ROCKSPEC_SHA256}"

cat > "${MIRROR_DIR}/manifest-5.4.json" <<EOF2
{"repository":{"${PACKAGE}":{"${VERSION}":[{"arch":"rockspec"}]}}}
EOF2

python3 -u -m http.server "${PORT}" --directory "${MIRROR_DIR}" >/tmp/moonstone-real-luasql-sqlite3-contract-server.log 2>&1 &
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
printf '━━━ report missing external SQLite paths before materialization ━━━\n'
moon init . --name real-luasql-sqlite3-contract --no-git
moon interpreter set lua@5.4
MISSING_PATHS_LOG="${WORKDIR}/missing-external-paths.log"
if env -u SQLITE_INCDIR -u SQLITE_LIBDIR moon add "rocks:${PACKAGE}@${VERSION}" >"${MISSING_PATHS_LOG}" 2>&1; then
    echo "ERROR: LuaSQL SQLite3 unexpectedly materialized without its declared external paths"
    exit 1
fi
grep -Fq 'Package luasql-sqlite3@2.8.0-1 requires external development files.' "${MISSING_PATHS_LOG}"
grep -Fq 'SQLITE_INCDIR — include directory (headers)' "${MISSING_PATHS_LOG}"
grep -Fq 'SQLITE_LIBDIR — library directory' "${MISSING_PATHS_LOG}"

MISSING_PATHS_JSON_LOG="${WORKDIR}/missing-external-paths.ndjson"
if env -u SQLITE_INCDIR -u SQLITE_LIBDIR moon sync --json >"${MISSING_PATHS_JSON_LOG}" 2>&1; then
    echo "ERROR: JSON sync unexpectedly materialized LuaSQL SQLite3 without its declared external paths"
    exit 1
fi
grep -Eq '"kind"[[:space:]]*:[[:space:]]*"external_dependency_paths"' "${MISSING_PATHS_JSON_LOG}"
grep -Eq '"package"[[:space:]]*:[[:space:]]*"luasql-sqlite3"' "${MISSING_PATHS_JSON_LOG}"
grep -Eq '"variable"[[:space:]]*:[[:space:]]*"SQLITE_INCDIR"' "${MISSING_PATHS_JSON_LOG}"
grep -Eq '"variable"[[:space:]]*:[[:space:]]*"SQLITE_LIBDIR"' "${MISSING_PATHS_JSON_LOG}"

printf '━━━ materialize pinned LuaSQL SQLite3 native module ━━━\n'
export SQLITE_INCDIR SQLITE_LIBDIR
moon sync

# Lock replay must use the exact mirror URLs rather than reconstructing a
# rockspec name from LuaRocks' display casing.
grep -Fq "source = \"http://localhost:${PORT}/${PACKAGE}-${VERSION}.src.rock\"" moonstone.lock
grep -Fq "rockspec = \"http://localhost:${PORT}/${PACKAGE}-${VERSION}.rockspec\"" moonstone.lock
grep -q '^rockspec_hash = "b3:' moonstone.lock

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -il '^name = "luasql-sqlite3"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: LuaSQL SQLite3 artifact was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

printf '━━━ assert SQLite linkage, native behavior, and copied assets ━━━\n'
grep -q '^resolver = "rocks"$' "${ARTIFACT_MANIFEST}"
grep -Fq "source_hash = \"${SOURCE_ROCK_B3}\"" "${ARTIFACT_MANIFEST}"
grep -Fq "source = \"http://localhost:${PORT}/${PACKAGE}-${VERSION}.src.rock\"" "${ARTIFACT_MANIFEST}"
grep -q '^source_kind = "luarocks_src_rock"$' "${ARTIFACT_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "luasql.sqlite3", path = "lib/lua/5.4/luasql/sqlite3.so" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'asset = [{ name = "doc/' "${ARTIFACT_MANIFEST}"

moon exec -- lua -e '
  local sql = assert(require("luasql.sqlite3"))
  local environment = assert(sql.sqlite3())
  local database = assert(environment:connect(":memory:"))
  assert(database:execute("create table sample (value integer)") == 0)
  assert(database:execute("insert into sample values (42)") == 1)
  local cursor = assert(database:execute("select value from sample"))
  local row = assert(cursor:fetch({}, "a"))
  assert(row.value == 42)
  assert(cursor:close())
  assert(database:close())
  assert(environment:close())
  print("luasql-sqlite3-native-ok")
' | grep -q 'luasql-sqlite3-native-ok'

printf '━━━ purge and replay the locked LuaSQL SQLite3 artifact ━━━\n'
rm -rf "${ARTIFACT_DIR}" .moonstone/env
: > /tmp/moonstone-real-luasql-sqlite3-contract-server.log
moon sync --locked

# A locked replay may use the URLs stored in moonstone.lock, but it must not
# re-enter ordinary LuaRocks discovery and reconstruct URLs from the display
# name (LuaSQL-SQLite3). That path is case-sensitive on this mirror.
REPLAY_REQUESTS=$(cat /tmp/moonstone-real-luasql-sqlite3-contract-server.log)
if grep -Fq 'LuaSQL-SQLite3' <<<"${REPLAY_REQUESTS}"; then
    echo "ERROR: locked replay performed display-cased LuaRocks discovery"
    printf '%s\n' "${REPLAY_REQUESTS}"
    exit 1
fi

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -il '^name = "luasql-sqlite3"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the LuaSQL SQLite3 artifact"
    exit 1
fi
grep -Fq "source_hash = \"${SOURCE_ROCK_B3}\"" "${RESTORED_MANIFEST}"
grep -Fq 'lua_cmodule = [{ name = "luasql.sqlite3", path = "lib/lua/5.4/luasql/sqlite3.so" }]' "${RESTORED_MANIFEST}"
moon exec -- lua -e '
  local sql = assert(require("luasql.sqlite3"))
  local environment = assert(sql.sqlite3())
  local database = assert(environment:connect(":memory:"))
  local cursor = assert(database:execute("select 42 as value"))
  local row = assert(cursor:fetch({}, "a"))
  assert(row.value == 42)
  assert(cursor:close())
  assert(database:close())
  assert(environment:close())
  print("luasql-sqlite3-replay-ok")
' | grep -q 'luasql-sqlite3-replay-ok'

printf '━━━ ✓ Pinned LuaSQL SQLite3 materialization, execution, and replay passed ━━━\n'
