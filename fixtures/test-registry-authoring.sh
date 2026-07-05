#!/usr/bin/env bash
set -euo pipefail

# End-to-End test: Registry Authoring and Resolution
#
# Asserts that the moonstone registry tooling can successfully create a local registry,
# push descriptors, build the compact index (index.sqlite.zst), and that a client 
# project can register and resolve from it successfully.

MOON_BIN="${MOON_BIN:-moon}"
TEST_ROOT="$(mktemp -d /tmp/moonstone-registry-test.XXXXXX)"
export MOONSTONE_HOME="$TEST_ROOT/home"
mkdir -p "$MOONSTONE_HOME"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

echo "=== test-registry-authoring ==="
echo "  test root: $TEST_ROOT"

REG_DIR="$TEST_ROOT/test_registry"

echo "1. Creating registry at $REG_DIR..."
$MOON_BIN registry create "$REG_DIR"

echo "2. Preparing fake package descriptor and blob..."
cat > "$TEST_ROOT/package.toml" << EOF
[package]
name = "testpkg"
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
EOF
# Create a valid empty tar.gz so materialization doesn't crash on invalid archive
tar -czf "$TEST_ROOT/blob.tar.gz" -T /dev/null

echo "3. Pushing to local registry..."
$MOON_BIN registry push "$REG_DIR" --descriptor "$TEST_ROOT/package.toml" --blob "$TEST_ROOT/blob.tar.gz"

if [ ! -f "$REG_DIR/index.sqlite.zst" ]; then
    echo "ERROR: Compact index (index.sqlite.zst) was not generated."
    exit 1
fi
echo "Compact index exists: $(ls -lh "$REG_DIR/index.sqlite.zst" | awk '{print $5}')"

echo "4. Purging package from registry..."
$MOON_BIN registry purge "$REG_DIR" --p-name testpkg --version 1.0.0

echo "5. Re-pushing package to registry for resolution..."
$MOON_BIN registry push "$REG_DIR" --descriptor "$TEST_ROOT/package.toml" --blob "$TEST_ROOT/blob.tar.gz"

echo "6. Testing client resolution..."
PROJ_DIR="$TEST_ROOT/project"
mkdir -p "$PROJ_DIR"
cd "$PROJ_DIR"

cat > moonstone.toml << EOF
[project]
name = "test_project"
version = "0.1.0"

[dependencies]
EOF

echo "Registering myreg..."
$MOON_BIN registry add myreg "file://$REG_DIR"

echo "Adding myreg:testpkg@1.0.0..."
$MOON_BIN add "myreg:testpkg@1.0.0"

if ! grep -q "testpkg" moonstone.toml; then
    echo "ERROR: testpkg not found in moonstone.toml after add!"
    exit 1
fi

echo "SUCCESS: Registry authoring and resolution workflow passed!"
