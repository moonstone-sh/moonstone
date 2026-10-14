#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "━━━ Verify E2E runner cancellation ━━━"
bash tests/scripts/test_run_tests_cancellation.sh

echo "━━━ Check Moonstone formatting ━━━"
zig fmt --check --exclude src/core/assets/templates src/ build.zig

echo "━━━ Run Zig unit tests ━━━"
zig build test

echo "━━━ Run flavor-variant Lua spec ━━━"
for lua_bin in lua luajit; do
    if command -v "${lua_bin}" >/dev/null 2>&1; then
        "${lua_bin}" tests/lua/variants_spec.lua >/dev/null
    fi
done

echo "━━━ Verify sync cancellation against stalled registry responses ━━━"
zig build
python3 tests/scripts/test_sync_cancellation.py

echo "━━━ Verify public contracts ━━━"
bash packages/contracts/tests/run.sh

echo "━━━ ✓ Fast verification passed ━━━"
