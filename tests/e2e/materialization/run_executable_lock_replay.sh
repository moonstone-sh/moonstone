#!/usr/bin/env bash
set -euo pipefail

# Isolated E2E test for executable lockfile replay contracts.
TEST_TMP=$(mktemp -d /tmp/moonstone-e2e-replay-XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

export MOONSTONE_HOME="$TEST_TMP/home"
export MOONSTONE_DATA="$TEST_TMP/data"
export MOONSTONE_CACHE="$TEST_TMP/cache"
export MOONSTONE_CONFIG="$TEST_TMP/config"
export TMPDIR="$TEST_TMP/tmp"
mkdir -p "$MOONSTONE_HOME" "$MOONSTONE_DATA" "$MOONSTONE_CACHE" "$MOONSTONE_CONFIG" "$TMPDIR"

PROJECT_DIR="$TEST_TMP/project"
mkdir -p "$PROJECT_DIR"
ROOT_DIR="$(pwd)"
MOON_BIN="$ROOT_DIR/zig-out/bin/moon"

cd "$PROJECT_DIR"

echo "=== 01: Initialize Project & Lockfile v3 ==="
SANDBOX_DIR="${ROOT_DIR}/fixtures/sandbox"
cat <<EOF > moonstone.toml
[package]
name = "e2e-replay-demo"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"

[[registries]]
name = "synthetic"
resolver = "moonstone"
path = "${SANDBOX_DIR}/registry"

[[dependencies]]
name = "inspect"
constraint = "=3.1.3"
registry = "synthetic"
role = "runtime"
EOF

"$MOON_BIN" sync

echo "=== 02: Verify lockfile_version = 3 ==="
cat moonstone.lock
grep -q "lockfile_version = 3" moonstone.lock

echo "=== 03: Replay frozen lockfile ==="
LOCK_HASH_BEFORE=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)
"$MOON_BIN" sync --locked
LOCK_HASH_AFTER=$(shasum -a 256 moonstone.lock | cut -d' ' -f1)

if [ "$LOCK_HASH_BEFORE" != "$LOCK_HASH_AFTER" ]; then exit 1; fi

echo "=== 04: Check dry-run integrity ==="
"$MOON_BIN" sync --check

echo "✅ All executable lockfile replay contract assertions passed!"
