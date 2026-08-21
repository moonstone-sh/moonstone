#!/usr/bin/env bash
set -euo pipefail

# E2E Test: Store Purge & Executable Lock Reconstruction Verification
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

TEST_APP="${SANDBOX_DIR}/purge-app"
rm -rf "$TEST_APP"
mkdir -p "$TEST_APP"
cd "$TEST_APP"

MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"

echo "=== 1. Initialize project ==="
cat <<EOF > moonstone.toml
[package]
name = "purge-app"
version = "1.0.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies.runtime]

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"
EOF

echo "=== 2. Add dependency inspect and sync ==="
"$MOON_BIN" add synthetic:inspect
"$MOON_BIN" sync

echo "=== 3. Verify lockfile_version = 3 header ==="
cat moonstone.lock
grep -q "lockfile_version = 3" moonstone.lock
LOCK_HASH_INITIAL=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)

STORE_DIR="$MOONSTONE_DATA/store"
if [ ! -d "$STORE_DIR" ]; then
  STORE_DIR="$MOONSTONE_HOME/store"
fi

echo "=== 4. Purge local CAS store artifacts ($STORE_DIR/b3) ==="
rm -rf "$STORE_DIR/b3/"*
rm -rf "$TEST_APP/.moonstone/env"

echo "=== 5. Run frozen replay (moon sync --locked) on purged store ==="
"$MOON_BIN" sync --locked

LOCK_HASH_REPLAY=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)

echo "=== 6. Verify lockfile immutability and CAS restoration ==="
if [ "$LOCK_HASH_INITIAL" != "$LOCK_HASH_REPLAY" ]; then
  echo "ERROR: Lockfile was mutated during frozen replay!"
  exit 1
fi

if [ -z "$(ls -A "$STORE_DIR")" ]; then
  echo "ERROR: CAS store was empty after reconstruction!"
  exit 1
fi

echo "=== 7. Validate project integrity with moon sync --check ==="
"$MOON_BIN" sync --check

echo "✅ Store Purge & Verified Host Rematerialization E2E test passed!"
