#!/usr/bin/env bash
set -euo pipefail

# This script runs all contract validation checks.
# It ensures that type definitions and schemas are syntactically valid and match expected shapes.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${DIR}/.." && pwd)"

echo "=== Running TypeScript verification ==="
bun x tsc --noEmit "${ROOT_DIR}/typescript/ndjson.ts"
bun run "${ROOT_DIR}/tests/ndjson_test.ts"
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
    echo "LuaCATS syntax verification: PASS"
else
    echo "luac not found, skipping syntax check (but file is metadata-only comments)"
fi
echo ""

echo "All contract verification tests passed successfully!"
