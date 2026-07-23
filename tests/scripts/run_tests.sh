#!/usr/bin/env bash
set -uo pipefail

# This script runs synthetic scenario tests from the tests/e2e/ directory.

# Since this script is now in tests/scripts/, the project root is two levels up
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${PROJECT_ROOT}/tests/e2e"
MOON_BIN="${PROJECT_ROOT}/zig-out/bin/moon"
SANDBOX_DIR="${PROJECT_ROOT}/fixtures/sandbox"

SUITE=""
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--suite" ]] && [[ -n "${2:-}" ]]; then
        SUITE="$2"
    elif [[ "$1" != "--all" ]]; then
        echo "Usage: $0 [--suite <suite_name> | --all]"
        exit 1
    fi
fi

PASS=0
FAIL=0

run_test_file() {
    local test_file="$1"
    local suite_name="$2"
    local label=$(basename "${test_file}")
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  Running Test: [${suite_name}] ${label}"
    echo "═══════════════════════════════════════════════════════════════════"
    
    if (
        source "${PROJECT_ROOT}/tests/scripts/install_synthetic.sh"
        export PATH="${MOON_BIN%/*}:${PATH}"
        export SANDBOX_DIR
        export MOONSTONE_REAL_LUAROCKS="${MOONSTONE_REAL_LUAROCKS:-1}"
        bash "${test_file}"
    ); then
        echo "  ✓ ${label} passed"
        ((PASS+=1))
    else
        echo "  ✗ ${label} failed"
        ((FAIL+=1))
    fi
}

# 2. Iterate and run
if [[ -n "${SUITE}" ]]; then
    TARGET_DIR="${TESTS_DIR}/${SUITE}"
    if [[ ! -d "${TARGET_DIR}" ]]; then
        echo "Error: Suite '${SUITE}' not found at ${TARGET_DIR}"
        exit 1
    fi
    for f in "${TARGET_DIR}"/*.sh; do
        [[ -f "$f" ]] && run_test_file "$f" "${SUITE}"
    done
else
    # Run all suites
    for suite_dir in "${TESTS_DIR}"/*; do
        if [[ -d "${suite_dir}" ]]; then
            suite_name=$(basename "${suite_dir}")
            for f in "${suite_dir}"/*.sh; do
                [[ -f "$f" ]] && run_test_file "$f" "${suite_name}"
            done
        fi
    done
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Final Results: ${PASS} passed, ${FAIL} failed"
echo "═══════════════════════════════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 1
fi
