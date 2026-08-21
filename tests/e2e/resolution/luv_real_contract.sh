#!/usr/bin/env bash
set -euo pipefail

# Contract: the pinned luv 1.51.0-1 source rock uses LuaRocks' CMake backend
# variables. Moonstone resolves those declarations into an isolated CMake
# install root, promotes only the declared native module, loads it inside the
# projected Lua environment, and replays the same closure from moonstone.lock.

if [[ "${MOONSTONE_REAL_LUAROCKS:-0}" != "1" ]]; then
    echo "SKIP: set MOONSTONE_REAL_LUAROCKS=1 to run the pinned luv upstream contract"
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

for command in cmake curl python3; do
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

readonly PACKAGE="luv"
readonly VERSION="1.51.0-1"
readonly SOURCE_ROCK_SHA256="b935a8a103f3aff806ed0104c9622ba9e79654cad1a75f3ad7b5637c14999a15"
readonly ROCKSPEC_SHA256="7325fff6cea604a3cae92d488e25a88a4017c040af9662452c2dcfe65c1300be"
readonly SOURCE_B3="b3:46e62061690159cd72f51fdf772254f43536e1e8aed96ba91c332fc74e42e717"

WORKDIR="/tmp/moonstone-real-luv-contract"
MIRROR_DIR="${WORKDIR}/mirror"
TEST_APP="${WORKDIR}/app"
PORT=$(( ( RANDOM % 1000 ) + 9600 ))

rm -rf "${WORKDIR}"
mkdir -p "${MIRROR_DIR}" "${TEST_APP}"

echo "━━━ fetch and verify pinned luv upstream release ━━━"
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

python3 -m http.server "${PORT}" --directory "${MIRROR_DIR}" >/tmp/moonstone-real-luv-contract-server.log 2>&1 &
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

echo "━━━ materialize pinned luv CMake module ━━━"
moon init . --name real-luv-contract --no-git
moon interpreter set lua@5.4
moon add "rocks:${PACKAGE}@${VERSION}"

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "luv"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: luv artifact was not committed to the store" >&2
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

dump_artifact_context() {
    local manifest_path="$1"
    local artifact_dir
    artifact_dir="$(dirname "${manifest_path}")"

    echo "--- luv artifact manifest: ${manifest_path} ---" >&2
    cat "${manifest_path}" >&2 || true
    echo "--- luv artifact files: ${artifact_dir}/files ---" >&2
    find "${artifact_dir}/files" -maxdepth 5 -print >&2 || true
}

require_manifest_line() {
    local manifest_path="$1"
    local expected="$2"
    local label="$3"

    if ! grep -Fqx "${expected}" "${manifest_path}"; then
        echo "ERROR: luv artifact ${label} was not recorded as expected" >&2
        echo "Expected: ${expected}" >&2
        dump_artifact_context "${manifest_path}"
        exit 1
    fi
}

require_artifact_file() {
    local manifest_path="$1"
    local file_path="$2"
    local label="$3"

    if [[ ! -f "${file_path}" ]]; then
        echo "ERROR: luv artifact ${label} is missing: ${file_path}" >&2
        dump_artifact_context "${manifest_path}"
        exit 1
    fi
}

require_absent_path() {
    local manifest_path="$1"
    local path="$2"
    local label="$3"

    if [[ -e "${path}" ]]; then
        echo "ERROR: luv artifact ${label} remains: ${path}" >&2
        dump_artifact_context "${manifest_path}"
        exit 1
    fi
}

assert_luv_contract() {
    local manifest_path="$1"
    local artifact_dir
    artifact_dir="$(dirname "${manifest_path}")"

    require_manifest_line "${manifest_path}" 'resolver = "rocks"' "resolver"
    require_manifest_line "${manifest_path}" "source_hash = \"${SOURCE_B3}\"" "source hash"
    require_manifest_line "${manifest_path}" "source = \"http://localhost:${PORT}/${PACKAGE}-${VERSION}.src.rock\"" "source URL"
    require_manifest_line "${manifest_path}" 'lua_cmodule = [{ name = "luv", path = "lib/lua/5.4/luv.so" }]' "native module interface"
    require_artifact_file "${manifest_path}" "${artifact_dir}/files/lib/lua/5.4/luv.so" "native module"
    require_absent_path "${manifest_path}" "${artifact_dir}/files/.moonstone-cmake-install" "CMake staging directory"
    if ! moon exec -- lua -e 'local uv = assert(require("luv")); assert(type(uv.version) == "function"); assert(uv.version() > 0); print(uv.version())' >/dev/null; then
        echo "ERROR: projected Lua runtime could not load luv" >&2
        dump_artifact_context "${manifest_path}"
        exit 1
    fi
}

echo "━━━ assert normalized CMake artifact and projected runtime ━━━"
assert_luv_contract "${ARTIFACT_MANIFEST}"

echo "━━━ purge and replay locked luv artifact ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "luv"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the luv artifact" >&2
    exit 1
fi
assert_luv_contract "${RESTORED_MANIFEST}"

echo "━━━ ✓ luv CMake artifact and replay contract passed ━━━"
