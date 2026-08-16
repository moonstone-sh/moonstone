#!/usr/bin/env bash
set -euo pipefail

# Contract: the pinned luaposix 36.3-1 command backend expands LuaRocks'
# declared build placeholders into Moonstone's projected runtime values, then
# runs the upstream shell commands unchanged. The resulting POSIX module must
# load and survive a lockfile replay.

if [[ "${MOONSTONE_REAL_LUAROCKS:-0}" != "1" ]]; then
    echo "SKIP: set MOONSTONE_REAL_LUAROCKS=1 to run the pinned luaposix upstream contract"
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

readonly PACKAGE="luaposix"
readonly VERSION="36.3-1"
readonly ROCKSPEC_SHA256="ebfb00b0e5abad78ddccf940a7f67915eb507f3ae4adfe9398ecf71596818a4b"
readonly SOURCE_SHA256="a03002b37bfd77281b81449d00e0c7886827cd072277051c0b8007962901bbab"
readonly SOURCE_B3="b3:5baff1f8ef1bfd124c3af336354511229213fa01275714d908a5e166af7af04e"

WORKDIR="/tmp/moonstone-real-luaposix-contract"
MIRROR_DIR="${WORKDIR}/mirror"
TEST_APP="${WORKDIR}/app"
PORT=$(( ( RANDOM % 1000 ) + 9800 ))

rm -rf "${WORKDIR}"
mkdir -p "${MIRROR_DIR}" "${TEST_APP}"

echo "━━━ fetch and verify pinned luaposix upstream release ━━━"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-${VERSION}.upstream.rockspec" \
    "https://luarocks.org/${PACKAGE}-${VERSION}.rockspec"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-36.3.zip" \
    "https://github.com/luaposix/luaposix/archive/v36.3.zip"
test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-${VERSION}.upstream.rockspec")" = "${ROCKSPEC_SHA256}"
test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-36.3.zip")" = "${SOURCE_SHA256}"

# Preserve the upstream build declaration byte-for-byte except for the source
# endpoint. The local endpoint prevents an unverified second network fetch;
# the verified bytes and original published rockspec remain the fixture's
# provenance contract.
MIRROR_PORT="${PORT}" MIRROR_DIR="${MIRROR_DIR}" python3 - <<'PY'
import os
from pathlib import Path

mirror = Path(os.environ["MIRROR_DIR"])
source = (mirror / "luaposix-36.3-1.upstream.rockspec").read_text()
needle = "url = 'http://github.com/luaposix/luaposix/archive/v' .. _MODREV .. '.zip',"
replacement = f"url = 'http://localhost:{os.environ['MIRROR_PORT']}/luaposix-36.3.zip',"
if needle not in source:
    raise SystemExit("ERROR: upstream luaposix source declaration changed")
(mirror / "luaposix-36.3-1.rockspec").write_text(source.replace(needle, replacement, 1))
PY

cat > "${MIRROR_DIR}/manifest-5.4.json" <<EOF
{"repository":{"${PACKAGE}":{"${VERSION}":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${PORT}" --directory "${MIRROR_DIR}" >/tmp/moonstone-real-luaposix-contract-server.log 2>&1 &
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

echo "━━━ materialize pinned luaposix command backend ━━━"
moon init . --name real-luaposix-contract --no-git
moon interpreter set lua@5.4
moon add "rocks:${PACKAGE}@${VERSION}"

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "luaposix"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: luaposix artifact was not committed to the store" >&2
    exit 1
fi

assert_luaposix_contract() {
    local manifest_path="$1"
    local artifact_dir
    artifact_dir="$(dirname "${manifest_path}")"

    grep -q '^resolver = "rocks"$' "${manifest_path}"
    grep -Fq "source_hash = \"${SOURCE_B3}\"" "${manifest_path}"
    grep -Fq "source = \"http://localhost:${PORT}/${PACKAGE}-36.3.zip\"" "${manifest_path}"
    [[ -f "${artifact_dir}/files/lib/lua/5.4/posix/_base.so" ]]
    moon exec -- lua -e 'local posix = assert(require("posix")); assert(type(posix.unistd.getpid()) == "number"); print(posix.unistd.getpid())' >/dev/null
}

echo "━━━ assert projected POSIX runtime behavior ━━━"
assert_luaposix_contract "${ARTIFACT_MANIFEST}"

echo "━━━ purge and replay locked luaposix artifact ━━━"
rm -rf "$(dirname "${ARTIFACT_MANIFEST}")" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "luaposix"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the luaposix artifact" >&2
    exit 1
fi
assert_luaposix_contract "${RESTORED_MANIFEST}"

echo "━━━ ✓ luaposix command artifact and replay contract passed ━━━"
