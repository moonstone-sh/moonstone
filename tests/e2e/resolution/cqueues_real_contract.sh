#!/usr/bin/env bash
set -euo pipefail

# Contract: the pinned cqueues 20200726.54-0 LuaRocks release exercises the
# typed Make adapter with explicit Make targets, sorted variable maps,
# source.dir, source.md5, and declared OpenSSL host paths. The package must
# materialize and execute from a lock replay on one of its supported hosts.

if [[ "${MOONSTONE_REAL_LUAROCKS:-0}" != "1" ]]; then
    echo "SKIP: set MOONSTONE_REAL_LUAROCKS=1 to run the pinned cqueues upstream contract"
    exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "SKIP: cqueues 20200726.54-0 declares Linux, BSD, and Solaris only"
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

for command in cc curl make pkg-config python3; do
    require_cmd "${command}"
done

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

readonly PACKAGE="cqueues"
readonly VERSION="20200726.54-0"
readonly ROCKSPEC_SHA256="d78cba24427812a711d10a05b410b2afb6a9d4002d51dd2a4f4c55ba1a50d48c"
readonly SOURCE_SHA256="9e112edd246da5cfca264314b70325a0b63665cb87a00e45ee3ae4f194000d52"

OPENSSL_INCDIR="$(pkg-config --variable=includedir openssl)"
OPENSSL_LIBDIR="$(pkg-config --variable=libdir openssl)"
if [[ ! -f "${OPENSSL_INCDIR}/openssl/ssl.h" || ! -e "${OPENSSL_LIBDIR}/libssl.so" ]]; then
    echo "SKIP: OpenSSL development headers or shared library are unavailable"
    exit 0
fi

WORKDIR="/tmp/moonstone-real-cqueues-contract"
MIRROR_DIR="${WORKDIR}/mirror"
TEST_APP="${WORKDIR}/app"
PORT=$(( ( RANDOM % 1000 ) + 9600 ))

rm -rf "${WORKDIR}"
mkdir -p "${MIRROR_DIR}" "${TEST_APP}"

echo "━━━ fetch and verify pinned cqueues upstream release ━━━"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/${PACKAGE}-${VERSION}.upstream.rockspec" \
    "https://luarocks.org/${PACKAGE}-${VERSION}.rockspec"
curl --fail --location --silent --show-error \
    --output "${MIRROR_DIR}/cqueues-rel-20200726.tar.gz" \
    "https://github.com/wahern/cqueues/archive/rel-20200726.tar.gz"
test "$(sha256_file "${MIRROR_DIR}/${PACKAGE}-${VERSION}.upstream.rockspec")" = "${ROCKSPEC_SHA256}"
test "$(sha256_file "${MIRROR_DIR}/cqueues-rel-20200726.tar.gz")" = "${SOURCE_SHA256}"

# Keep the upstream build declaration byte-for-byte. Only replace the verified
# source endpoint, so Moonstone consumes deterministic local bytes rather than
# making an unverified second request during materialization.
MIRROR_PORT="${PORT}" MIRROR_DIR="${MIRROR_DIR}" python3 - <<'PY'
import os
from pathlib import Path

mirror = Path(os.environ["MIRROR_DIR"])
source = (mirror / "cqueues-20200726.54-0.upstream.rockspec").read_text()
needle = 'url = "https://github.com/wahern/cqueues/archive/rel-20200726.tar.gz";'
replacement = f'url = "http://localhost:{os.environ["MIRROR_PORT"]}/cqueues-rel-20200726.tar.gz";'
if needle not in source:
    raise SystemExit("ERROR: upstream cqueues source declaration changed")
(mirror / "cqueues-20200726.54-0.rockspec").write_text(source.replace(needle, replacement, 1))
PY

cat > "${MIRROR_DIR}/manifest-5.4.json" <<EOF
{"repository":{"${PACKAGE}":{"${VERSION}":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${PORT}" --directory "${MIRROR_DIR}" >/tmp/moonstone-real-cqueues-contract-server.log 2>&1 &
MIRROR_PID=$!
trap 'kill "${MIRROR_PID}" 2>/dev/null || true' EXIT

export MOONSTONE_LUAROCKS_URL="http://localhost:${PORT}"
export OPENSSL_INCDIR OPENSSL_LIBDIR
export CRYPTO_INCDIR="${OPENSSL_INCDIR}"
export CRYPTO_LIBDIR="${OPENSSL_LIBDIR}"
for _ in {1..60}; do
    if curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"

echo "━━━ materialize pinned cqueues Make backend ━━━"
moon init . --name real-cqueues-contract --no-git
cat >> moonstone.toml <<EOF

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"
priority = 10
EOF
moon interpreter set lua@5.4
moon add "rocks:${PACKAGE}@${VERSION}"

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "cqueues"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: cqueues artifact was not committed to the store" >&2
    exit 1
fi

assert_cqueues_contract() {
    local manifest_path="$1"

    grep -q '^resolver = "rocks"$' "${manifest_path}"
    grep -Fq "source = \"http://localhost:${PORT}/cqueues-rel-20200726.tar.gz\"" "${manifest_path}"
    grep -q '^source_hash = "b3:' "${manifest_path}"
    grep -q '^recipe_hash = "b3:' "${manifest_path}"
    grep -q '^lua_abi = "5.4"$' "${manifest_path}"
    moon exec -- lua -e '
      local cqueues = assert(require("cqueues"))
      assert(type(cqueues.new) == "function")
      assert(cqueues.new())
      print("cqueues-make-ok")
    ' | grep -q 'cqueues-make-ok'
}

echo "━━━ assert projected Make runtime behavior ━━━"
assert_cqueues_contract "${ARTIFACT_MANIFEST}"

echo "━━━ purge and replay locked cqueues artifact ━━━"
rm -rf "$(dirname "${ARTIFACT_MANIFEST}")" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "cqueues"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the cqueues artifact" >&2
    exit 1
fi
assert_cqueues_contract "${RESTORED_MANIFEST}"

echo "━━━ ✓ cqueues Make artifact and replay contract passed ━━━"
