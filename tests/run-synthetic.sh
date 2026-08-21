#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "━━━ Build Moonstone ━━━"
zig build

echo "━━━ Generate isolated synthetic fixtures ━━━"
tests/run_lua_tool.sh generate-sandbox --clean
tests/run_lua_tool.sh registry-builder --output-dir "${ROOT_DIR}/fixtures/sandbox"

echo "━━━ Run synthetic E2E suites ━━━"
MOONSTONE_REAL_LUAROCKS=0 bash tests/scripts/run_tests.sh --all

echo "━━━ ✓ Synthetic E2E verification passed ━━━"
