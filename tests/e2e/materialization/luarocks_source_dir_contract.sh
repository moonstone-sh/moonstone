#!/usr/bin/env bash
set -euo pipefail

# Contract: source.dir selects a declared, traversal-safe package subdirectory
# after archive extraction. Build declarations resolve relative to that root and
# replay from the lock without changing source-archive provenance.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8700))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-source-dir.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/source-dir-rock-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}/nested" "${TEST_APP}"
cat > "${SOURCE_DIR}/nested/submodule.lua" <<'EOF'
return { greeting = function() return "source.dir works" end }
EOF
cat > "${SOURCE_DIR}/nested/subtool" <<'EOF'
#!/bin/sh
echo source-dir binary works
EOF
chmod +x "${SOURCE_DIR}/nested/subtool"
tar -czf "${MOCK_DIR}/source-dir-rock-0.1.0.tar.gz" -C "${MOCK_DIR}" source-dir-rock-0.1.0
cp "${MOCK_DIR}/source-dir-rock-0.1.0.tar.gz" "${MOCK_DIR}/source-download"
SOURCE_MD5=$(python3 - "${MOCK_DIR}/source-download" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.md5(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)

cat > "${MOCK_DIR}/source-dir-rock-0.1.0-1.rockspec" <<EOF
package = "source-dir-rock"
version = "0.1.0-1"
source = {
  url = "http://127.0.0.1:${RANDOM_PORT}/source-download",
  file = "source-dir-rock-0.1.0.tar.gz",
  md5 = "${SOURCE_MD5}",
  dir = "nested",
}
dependencies = { "lua >= 5.1" }
build = {
  type = "builtin",
  modules = { sourcedir = "submodule.lua" },
  install = { bin = { ["source-dir-tool"] = "subtool" } },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"source-dir-rock":{"0.1.0-1":[{"arch":"rockspec"}]}}}
EOF

(cd "${MOCK_DIR}" && python3 -m http.server "${RANDOM_PORT}" --bind 127.0.0.1) >"${WORKDIR}/server.log" 2>&1 &
MOCK_PID=$!
export MOONSTONE_LUAROCKS_URL="http://127.0.0.1:${RANDOM_PORT}"
for _ in {1..60}; do
    curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -fsS "${MOONSTONE_LUAROCKS_URL}/manifest-5.4.json" >/dev/null

cd "${TEST_APP}"
moon init . --name source-dir-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:source-dir-rock

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "source-dir-rock"$' {} \; | head -1)
[[ -n "${ARTIFACT_MANIFEST}" && -f "${ARTIFACT_MANIFEST}" ]]
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"
grep -Fq 'lua_module = [{ name = "sourcedir", path = "share/lua/5.4/sourcedir.lua" }]' "${ARTIFACT_MANIFEST}"
grep -Fq 'bin = [{ name = "source-dir-tool", path = "bin/source-dir-tool" }]' "${ARTIFACT_MANIFEST}"
moon exec -- lua -e 'print(require("sourcedir").greeting())' | grep -q 'source.dir works'
moon exec -- source-dir-tool | grep -q 'source-dir binary works'

rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked
moon exec -- lua -e 'print(require("sourcedir").greeting())' | grep -q 'source.dir works'
moon exec -- source-dir-tool | grep -q 'source-dir binary works'

echo "━━━ ✓ LuaRocks source.dir materialization and replay contract passed ━━━"
