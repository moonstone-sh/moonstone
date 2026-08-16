#!/usr/bin/env bash
set -euo pipefail

# Contract: a rockspec's source.md5 applies to the bytes at source.url, not to
# the distinct .src.rock Moonstone prefers when LuaRocks publishes one. The
# selected source rock still provides the materialized package closure.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(( ( RANDOM % 1000 ) + 8200 ))
MOCK_DIR="/tmp/moonstone-rockspec-source-rock-md5-contract"
SOURCE_DIR="${MOCK_DIR}/source-md5-1.0"
SRC_ROCK_DIR="${MOCK_DIR}/source-rock"
TEST_APP="${SANDBOX_DIR}/rockspec-source-rock-md5-contract-app"

rm -rf "${MOCK_DIR}" "${TEST_APP}"
mkdir -p "${SOURCE_DIR}" "${SRC_ROCK_DIR}" "${TEST_APP}"

cat > "${SOURCE_DIR}/source_md5.lua" <<'EOF'
return { source = "src-rock" }
EOF
tar -czf "${MOCK_DIR}/source-md5-1.0.tar.gz" -C "${MOCK_DIR}" source-md5-1.0

if command -v md5sum >/dev/null 2>&1; then
    SOURCE_MD5="$(md5sum "${MOCK_DIR}/source-md5-1.0.tar.gz" | awk '{print $1}')"
else
    SOURCE_MD5="$(md5 -q "${MOCK_DIR}/source-md5-1.0.tar.gz")"
fi

cp "${MOCK_DIR}/source-md5-1.0.tar.gz" "${SRC_ROCK_DIR}/"
(
    cd "${SRC_ROCK_DIR}"
    zip -q "${MOCK_DIR}/source-md5-1.0-1.src.rock" source-md5-1.0.tar.gz
)

cat > "${MOCK_DIR}/source-md5-1.0-1.rockspec" <<EOF
package = "source-md5"
version = "1.0-1"
source = {
   url = "http://localhost:${RANDOM_PORT}/source-md5-1.0.tar.gz",
   md5 = "${SOURCE_MD5}",
}
dependencies = { "lua >= 5.1" }
build = { type = "builtin", modules = { source_md5 = "source_md5.lua" } }
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"source-md5":{"1.0-1":[{"arch":"rockspec"}]}}}
EOF

python3 -m http.server "${RANDOM_PORT}" --directory "${MOCK_DIR}" >/tmp/moonstone-rockspec-source-rock-md5-contract-server.log 2>&1 &
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

echo "━━━ prefer source rock without misapplying archive MD5 ━━━"
moon init . --name rockspec-source-rock-md5-contract --no-git
moon interpreter set lua@5.4
moon add rocks:source-md5

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "source-md5"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: source-md5 artifact was not committed to the store"
    exit 1
fi
grep -Fq "source = \"http://localhost:${RANDOM_PORT}/source-md5-1.0-1.src.rock\"" "${ARTIFACT_MANIFEST}"
grep -q '^source_kind = "luarocks_src_rock"$' "${ARTIFACT_MANIFEST}"
moon exec -- lua -e 'assert(require("source_md5").source == "src-rock"); print("source-rock-md5-ok")' | grep -q 'source-rock-md5-ok'

echo "━━━ ✓ LuaRocks source-rock MD5 contract passed ━━━"
