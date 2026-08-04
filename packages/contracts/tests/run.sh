#!/usr/bin/env bash
set -euo pipefail

# This script runs all contract validation checks.
# It ensures that type definitions and schemas are syntactically valid and match expected shapes.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${DIR}/.." && pwd)"

echo "=== Running TypeScript verification ==="
(
    cd "${ROOT_DIR}"
    bun run check
    bun run test
)
echo "TypeScript verification: PASS"
echo ""

echo "=== Running Go verification ==="
cd "${ROOT_DIR}"
go test ./...
echo "Go verification: PASS"
echo ""

echo "=== Running LuaCATS syntax verification ==="
# Note: Full execution of LuaCATS tests requires a lua runtime with json packages.
# We do a basic validation to ensure the schema types are syntactically valid Lua code.
luac_bin=$(which luac || true)
if [[ -n "${luac_bin}" ]]; then
    luac -p "${ROOT_DIR}/lua/ndjson.lua"
    luac -p "${ROOT_DIR}/lua/manifest.lua"
    luac -p "${ROOT_DIR}/lua/lock.lua"
    echo "LuaCATS syntax verification: PASS"
else
    echo "luac not found, skipping syntax check (but file is metadata-only comments)"
fi

echo "=== Running generated annotation verification ==="
(
    cd "${ROOT_DIR}"
    bun run check:lua
)
echo "Generated annotation verification: PASS"
echo ""

echo "All contract verification tests passed successfully!"
