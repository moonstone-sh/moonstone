#!/usr/bin/env bash
set -uo pipefail

# This script runs all synthetic scenario tests in the fixtures/scenario-tests/ directory.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${PROJECT_ROOT}/fixtures/scenario-tests"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
SANDBOX_DIR="${PROJECT_ROOT}/fixtures/sandbox"

# 1. Prepare environment
source "${PROJECT_ROOT}/install_synthetic.sh"

export PATH="${MOON_BIN%/*}:${PATH}"
export SANDBOX_DIR
export MOONSTONE_REAL_LUAROCKS="${MOONSTONE_REAL_LUAROCKS:-1}"

PASS=0
FAIL=0

run_test_file() {
    local test_file="$1"
    local label=$(basename "${test_file}")
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Running Test: ${label}"
    echo "═══════════════════════════════════════════════════════════════════"
    
    if bash "${test_file}"; then
        echo "  ✓ ${label} passed"
        ((PASS+=1))
    else
        echo "  ✗ ${label} failed"
        ((FAIL+=1))
    fi
}

# 2. Iterate and run
for f in "${TESTS_DIR}"/*.sh; do
    if [[ -f "$f" ]]; then
        run_test_file "$f"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Final Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
