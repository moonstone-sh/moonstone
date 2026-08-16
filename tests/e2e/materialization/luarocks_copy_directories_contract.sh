#!/usr/bin/env bash
set -euo pipefail

# Contract: LuaRocks build.copy_directories becomes an inspectable artifact
# closure under assets/, remains outside the runtime search path, and is
# reconstructed by a locked replay.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

RANDOM_PORT=$(((RANDOM % 1000) + 8400))
WORKDIR="$(mktemp -d /tmp/moonstone-rockspec-copy-directories-contract.XXXXXX)"
MOCK_DIR="${WORKDIR}/mock-rocks"
SOURCE_DIR="${MOCK_DIR}/copy-directories-0.1.0"
DEFAULT_DOCS_SOURCE_DIR="${MOCK_DIR}/default-docs-0.1.0"
TEST_APP="${WORKDIR}/app"

cleanup() {
    kill "${MOCK_PID:-}" 2>/dev/null || true
    wait "${MOCK_PID:-}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${SOURCE_DIR}/src" "${SOURCE_DIR}/doc/guides" "${SOURCE_DIR}/examples" "${TEST_APP}"
mkdir -p "${DEFAULT_DOCS_SOURCE_DIR}/src"

cat > "${SOURCE_DIR}/src/copy_directories.lua" <<'EOF'
return "copy directories contract"
EOF
cat > "${SOURCE_DIR}/doc/README.md" <<'EOF'
# Copy directories contract
EOF
cat > "${SOURCE_DIR}/doc/guides/replay.md" <<'EOF'
The artifact keeps this documentation outside its runtime paths.
EOF
cat > "${SOURCE_DIR}/examples/demo.lua" <<'EOF'
print("asset example")
EOF
tar -czf "${MOCK_DIR}/copy-directories-0.1.0.tar.gz" -C "${MOCK_DIR}" copy-directories-0.1.0

cat > "${DEFAULT_DOCS_SOURCE_DIR}/src/default_docs.lua" <<'EOF'
return "default documentation contract"
EOF
cat > "${DEFAULT_DOCS_SOURCE_DIR}/README.md" <<'EOF'
# Default documentation contract
EOF
cat > "${DEFAULT_DOCS_SOURCE_DIR}/LICENSE" <<'EOF'
contract fixture license
EOF
cat > "${DEFAULT_DOCS_SOURCE_DIR}/notes.txt" <<'EOF'
This file is intentionally not a default LuaRocks documentation asset.
EOF
tar -czf "${MOCK_DIR}/default-docs-0.1.0.tar.gz" -C "${MOCK_DIR}" default-docs-0.1.0

cat > "${MOCK_DIR}/copy-directories-0.1.0-1.rockspec" <<EOF
package = "copy-directories"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/copy-directories-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { copy_directories = "src/copy_directories.lua" },
   copy_directories = { "doc", "examples" },
}
EOF
cat > "${MOCK_DIR}/default-docs-0.1.0-1.rockspec" <<EOF
package = "default-docs"
version = "0.1.0-1"
source = { url = "http://127.0.0.1:${RANDOM_PORT}/default-docs-0.1.0.tar.gz" }
dependencies = { "lua >= 5.1" }
build = {
   type = "builtin",
   modules = { default_docs = "src/default_docs.lua" },
}
EOF
cat > "${MOCK_DIR}/manifest-5.4.json" <<'EOF'
{"repository":{"copy-directories":{"0.1.0-1":[{"arch":"rockspec"}]},"default-docs":{"0.1.0-1":[{"arch":"rockspec"}]}}}
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

echo "━━━ resolve and materialize copy_directories rock ━━━"
moon init . --name copy-directories-contract --no-git --no-sync
moon interpreter set lua@5.4 --no-sync
moon add rocks:copy-directories

STORE_DIR="${MOONSTONE_DATA}/store/v0"
ARTIFACT_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "copy-directories"$' {} \; | head -1)
if [[ -z "${ARTIFACT_MANIFEST}" || ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: copy-directories artifact manifest was not committed to the store"
    exit 1
fi
ARTIFACT_DIR="$(dirname "${ARTIFACT_MANIFEST}")"

echo "━━━ assert asset provisions and artifact closure ━━━"
grep -Fq 'asset = [{ name = "doc/README.md", path = "assets/doc/README.md" }, { name = "doc/guides/replay.md", path = "assets/doc/guides/replay.md" }, { name = "examples/demo.lua", path = "assets/examples/demo.lua" }]' "${ARTIFACT_MANIFEST}"
grep -Fq '# Copy directories contract' "${ARTIFACT_DIR}/files/assets/doc/README.md"
grep -Fq 'asset example' "${ARTIFACT_DIR}/files/assets/examples/demo.lua"

echo "━━━ assert Lua projection excludes copied assets ━━━"
moon exec -- lua -e 'print(require("copy_directories"))' | grep -q 'copy directories contract'
if moon exec -- lua -e 'assert(package.searchpath("demo", package.path) == nil)' >/dev/null 2>&1; then
    :
else
    echo "ERROR: copied asset unexpectedly became a Lua runtime module" >&2
    exit 1
fi

echo "━━━ purge and replay the locked asset closure ━━━"
rm -rf "${ARTIFACT_DIR}" .moonstone/env
moon sync --locked

RESTORED_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "copy-directories"$' {} \; | head -1)
if [[ -z "${RESTORED_MANIFEST}" || ! -f "${RESTORED_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the copy-directories artifact"
    exit 1
fi
RESTORED_DIR="$(dirname "${RESTORED_MANIFEST}")"
grep -Fq 'asset = [{ name = "doc/README.md", path = "assets/doc/README.md" }, { name = "doc/guides/replay.md", path = "assets/doc/guides/replay.md" }, { name = "examples/demo.lua", path = "assets/examples/demo.lua" }]' "${RESTORED_MANIFEST}"
grep -Fq 'The artifact keeps this documentation' "${RESTORED_DIR}/files/assets/doc/guides/replay.md"
grep -Fq 'asset example' "${RESTORED_DIR}/files/assets/examples/demo.lua"
moon exec -- lua -e 'print(require("copy_directories"))' | grep -q 'copy directories contract'

echo "━━━ assert default root documentation fallback and locked replay ━━━"
moon add rocks:default-docs

DEFAULT_DOCS_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "default-docs"$' {} \; | head -1)
if [[ -z "${DEFAULT_DOCS_MANIFEST}" || ! -f "${DEFAULT_DOCS_MANIFEST}" ]]; then
    echo "ERROR: default-docs artifact manifest was not committed to the store"
    exit 1
fi
DEFAULT_DOCS_ARTIFACT_DIR="$(dirname "${DEFAULT_DOCS_MANIFEST}")"
if ! grep -Fq 'asset = [{ name = "doc/LICENSE", path = "assets/doc/LICENSE" }, { name = "doc/README.md", path = "assets/doc/README.md" }]' "${DEFAULT_DOCS_MANIFEST}"; then
    echo "ERROR: default root documentation provisions were not recorded as expected" >&2
    cat "${DEFAULT_DOCS_MANIFEST}" >&2
    exit 1
fi
grep -Fq '# Default documentation contract' "${DEFAULT_DOCS_ARTIFACT_DIR}/files/assets/doc/README.md"
if [[ -e "${DEFAULT_DOCS_ARTIFACT_DIR}/files/assets/doc/notes.txt" ]]; then
    echo "ERROR: non-document root file unexpectedly became a LuaRocks default asset" >&2
    exit 1
fi

rm -rf "${DEFAULT_DOCS_ARTIFACT_DIR}" .moonstone/env
moon sync --locked
RESTORED_DEFAULT_DOCS_MANIFEST=$(find "${STORE_DIR}" -name manifest.toml -exec grep -l '^name = "default-docs"$' {} \; | head -1)
if [[ -z "${RESTORED_DEFAULT_DOCS_MANIFEST}" || ! -f "${RESTORED_DEFAULT_DOCS_MANIFEST}" ]]; then
    echo "ERROR: locked replay did not restore the default-docs artifact"
    exit 1
fi
RESTORED_DEFAULT_DOCS_DIR="$(dirname "${RESTORED_DEFAULT_DOCS_MANIFEST}")"
grep -Fq 'contract fixture license' "${RESTORED_DEFAULT_DOCS_DIR}/files/assets/doc/LICENSE"
moon exec -- lua -e 'print(require("default_docs"))' | grep -q 'default documentation contract'

echo "━━━ ✓ LuaRocks copy_directories artifact and replay contract passed ━━━"
