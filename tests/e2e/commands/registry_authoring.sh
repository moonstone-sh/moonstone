#!/usr/bin/env bash
set -euo pipefail

source "${PROJECT_ROOT}/tests/scripts/lib/assert.sh"

WORKDIR="/tmp/moonstone-contract-registry-authoring"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}/project"
mkdir -p "${WORKDIR}/registry"

REG_DIR="${WORKDIR}/registry"

echo "=== 1. Creating registry ==="
moon registry create "${REG_DIR}"

echo "=== 2. Pushing package to registry ==="
cat > "${WORKDIR}/package.toml" << EOF
[package]
name = "testorg/testpkg"
version = "1.0.0"
kind = "lib"

[[artifacts]]
kind = "compiled"
target = "native"
lua_abi = "lua54"
url = "fake_url"
hash = "b3:fakehash"
format = "tar.gz"
bytes = 100

[artifacts.materialize]
type = "archive"
EOF

tar -czf "${WORKDIR}/blob.tar.gz" -T /dev/null

moon registry push "${REG_DIR}" --descriptor "${WORKDIR}/package.toml" --blob "${WORKDIR}/blob.tar.gz"

if [ ! -f "${REG_DIR}/index.sqlite.zst" ]; then
    echo "✗ Compact index (index.sqlite.zst) was not generated."
    exit 1
fi
echo "✓ Compact index exists"

echo "=== 3. Purging package from registry ==="
moon registry purge "${REG_DIR}" --p-name testorg/testpkg --version 1.0.0

echo "=== 4. Re-pushing package to registry for resolution ==="
moon registry push "${REG_DIR}" --descriptor "${WORKDIR}/package.toml" --blob "${WORKDIR}/blob.tar.gz"

echo "=== 5. Testing client resolution ==="
cd "${WORKDIR}/project"

moon init . --name test-registry-authoring --no-git
moon interpreter set lua@5.4 --no-sync

moon registry add myreg "file://${REG_DIR}"
assert_file_contains "${WORKDIR}/project/moonstone.toml" '[registries."myreg"]'

# Add should successfully resolve our package.
# Depending on how the dummy empty tarball is handled, materialization might fail or succeed.
# But resolution will definitely occur.
moon add "myreg:testorg/testpkg@1.0.0"

assert_file_contains "${WORKDIR}/project/moonstone.toml" 'testorg/testpkg'

echo "✓ Registry authoring and resolution workflow passed!"
