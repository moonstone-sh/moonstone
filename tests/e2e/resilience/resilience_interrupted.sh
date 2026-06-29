#!/usr/bin/env bash
set -euo pipefail

# Test: Interrupted Install Recovery
# - Corrupts an artifact in store
# - Verifies moon sync recovers

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ -z "${MOONSTONE_HOME:-}" ]]; then
    source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
fi

WORKDIR="/tmp/moonstone-test-interrupted"
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

moon init --name interrupted-test --kind script
moon use lua@5.4
moon add inspect --no-sync

echo "Initial install..."
moon sync

INSPECT_PATH=$(moon store path inspect 2>/dev/null || true)
if [ -z "$INSPECT_PATH" ]; then
    echo "FAIL: could not find inspect in store"
    exit 1
fi

# Corrupt a file in the store
CORRUPT_TARGET="${INSPECT_PATH}/lua/inspect.lua"
if [ ! -f "$CORRUPT_TARGET" ]; then
    CORRUPT_TARGET=$(find "$INSPECT_PATH" -name "inspect.lua" | head -n 1)
fi

echo "Corrupting: ${CORRUPT_TARGET}"
echo "CORRUPTED" > "$CORRUPT_TARGET"

# Delete the folder to force recovery
rm -rf "${INSPECT_PATH}"

echo "Re-installing to recover..."
moon sync --update

moon exec -- lua -e 'require("inspect"); print("Recovered!")' | grep "Recovered!"
