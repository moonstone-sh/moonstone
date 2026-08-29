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

echo "━━━ Verify public contracts ━━━"
bash packages/contracts/tests/run.sh

echo "━━━ ✓ Fast verification passed ━━━"
