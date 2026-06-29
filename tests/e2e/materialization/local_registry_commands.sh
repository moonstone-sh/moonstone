#!/usr/bin/env bash
set -euo pipefail

# Test: Local file registry command lifecycle
# - Creates a local registry root
# - Pushes a descriptor + blob
# - Regenerates the index
# - Purges by descriptor + blob

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-local-registry-commands"
REGISTRY="${WORKDIR}/local-registry"
DESCRIPTOR="${WORKDIR}/package.toml"
BLOB="${WORKDIR}/test-local-0.1.0-source.tar.gz"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

mkdir -p "${WORKDIR}/source"
cat > "${WORKDIR}/source/test.lua" <<'EOF'
return "local registry command test"
EOF
tar -czf "${BLOB}" -C "${WORKDIR}/source" .

cat > "${DESCRIPTOR}" <<'EOF'
[package]
name = "moonstone/test-local"
version = "0.1.0"
kind = "lib"

[[artifacts]]
id = "source"
kind = "source"
target = "source"
format = "tar.gz"
url = "placeholder.tar.gz"
hash = "b3:placeholder"

[artifacts.materialize]
type = "command"
command = "true"
EOF

echo "━━━ moon registry create ━━━"
moon registry create "${REGISTRY}" local
test -f "${REGISTRY}/registry.toml"
test -f "${REGISTRY}/index.toml"
test -d "${REGISTRY}/packages"
test -d "${REGISTRY}/blobs/b3"

echo "━━━ moon registry push ━━━"
moon registry push "${REGISTRY}" --descriptor "${DESCRIPTOR}" --blob "${BLOB}"
PACKAGE_DESCRIPTOR="${REGISTRY}/packages/moonstone/test-local/0.1.0/package.toml"
test -f "${PACKAGE_DESCRIPTOR}"
grep 'name = "moonstone/test-local"' "${PACKAGE_DESCRIPTOR}"
grep 'url = "blobs/b3/' "${PACKAGE_DESCRIPTOR}"
grep 'name = "moonstone/test-local"' "${REGISTRY}/index.toml"
grep 'descriptor = "packages/moonstone/test-local/0.1.0/package.toml"' "${REGISTRY}/index.toml"

echo "━━━ moon registry sync ━━━"
rm -f "${REGISTRY}/index.toml"
moon registry sync "${REGISTRY}" local
grep 'name = "moonstone/test-local"' "${REGISTRY}/index.toml"

echo "━━━ project registry add + resolve ━━━"
PROJECT="${WORKDIR}/consumer"
mkdir -p "${PROJECT}"
cd "${PROJECT}"
cat > moonstone.toml <<'EOF'
[package]
name = "registry-consumer"
version = "0.1.0"
kind = "lib"

[runtime]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.libs]
EOF
moon registry add local "file://${REGISTRY}"
grep 'local' moonstone.toml
moon add --no-sync 'local:moonstone/test-local@0.1.0'
grep 'moonstone/test-local' moonstone.toml
cd "${WORKDIR}"

echo "━━━ moon registry purge ━━━"
moon registry purge "${REGISTRY}" --descriptor "${PACKAGE_DESCRIPTOR}" --blob "${BLOB}"
test ! -e "${PACKAGE_DESCRIPTOR}"
if grep -q 'moonstone/test-local' "${REGISTRY}/index.toml"; then
    echo "purged package still appears in index.toml" >&2
    exit 1
fi

echo "━━━ ✓ Local registry commands passed ━━━"
